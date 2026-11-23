// What iOS adds around the shared UploadQueue (mac/Verso/Verso/App/UploadQueue.swift), one for each queue: photos
// chosen in the photo picker, or dropped on an iPad from another app, written out as files for it, with their original
// names and data, and removed once the queue is done with them; a notification when an import ends while Verso is in the background, asked for at the
// first import; and the time to finish in the background, with the system's own progress where Verso's Info.plist
// allows it (BGContinuedProcessingTask).

import BackgroundTasks
import Observation
import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import UserNotifications

@MainActor @Observable
final class ImportCoordinator {
    /// Photos from the picker being written out for the queue: how many are ready of how many.
    struct Preparing: Equatable {
        var done: Int
        var total: Int
    }

    /// While photos from the picker are written out, before the queue has them.
    private(set) var preparing: Preparing?

    /// Whether another import can start: not while picked photos are written out, nor while the queue looks through
    /// the folders it was given.
    var canStart: Bool { preparing == nil && queue?.discovering != true }

    @ObservationIgnored private weak var queue: UploadQueue?
    @ObservationIgnored private var preparation: Task<Void, Never>?
    /// The folders made for picked photos that the queue was given, each removed once none of its files is in the
    /// queue's list.
    @ObservationIgnored private var handedOver: [URL] = []
    @ObservationIgnored private var sweeping: Task<Void, Never>?
    @ObservationIgnored private var wasRunning = false
    @ObservationIgnored private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    @ObservationIgnored private var continuedTask: BGContinuedProcessingTask?

    private static var coordinators: [ObjectIdentifier: ImportCoordinator] = [:]
    private static var sweptAtLaunch = false

    /// The coordinator of `queue`, made the first time it is asked for.
    static func of(_ queue: UploadQueue) -> ImportCoordinator {
        let key = ObjectIdentifier(queue)
        if let existing = coordinators[key], existing.queue === queue { return existing }
        if !sweptAtLaunch {
            // What an earlier run left, if it ended before it could clean up: nothing of this run is there yet.
            sweptAtLaunch = true
            try? FileManager.default.removeItem(at: ImportStaging.root)
        }
        coordinators = coordinators.filter { $0.value.queue != nil }
        let coordinator = ImportCoordinator(queue: queue)
        coordinators[key] = coordinator
        return coordinator
    }

    private init(queue: UploadQueue) {
        self.queue = queue
        observeQueue()
    }

    // MARK: Starting an import

    /// Photos and videos chosen in the photo picker: each written out with its original name and data (a Live
    /// Photo as its photo and its video, which Immich pairs), then imported as files are.
    func importPhotos(_ items: [PhotosPickerItem], albumID: String?) {
        importStaged(items.count, albumID: albumID) { await ImportStaging.stage(items[$0]) }
    }

    /// Photos, videos and files dropped on the iPad from another app (Photos, Files): each written out as its own
    /// file, a Live Photo as its photo and its video, then imported as the picker's are.
    func importDropped(_ providers: [NSItemProvider], albumID: String?) {
        let dropped = DroppedItems(providers: providers)
        importStaged(providers.count, albumID: albumID) { await ImportStaging.stage(dropped.providers[$0]) }
    }

    /// The items of a drop, read a few at a time off the main actor; an item provider may be read from any thread.
    private struct DroppedItems: @unchecked Sendable {
        let providers: [NSItemProvider]
    }

    /// Writes out `count` items for the queue, a few at a time (`stage` gives an item's files, none when it could not
    /// be read), then hands them over, the folders made for them swept once the queue is done with them.
    private func importStaged(_ count: Int, albumID: String?, stage: @escaping @Sendable (Int) async -> [URL]) {
        guard let queue, count > 0, preparation == nil else { return }
        Self.askForNotificationsOnce()
        preparing = Preparing(done: 0, total: count)
        // Shown from now, as the queue shows an import from its start.
        queue.showsBanner = true
        preparation = Task {
            var files: [URL] = []
            var directories: [URL] = []
            var unreadable = 0
            await withTaskGroup(of: [URL].self) { group in
                var next = 0
                // A few at a time: each may wait for its original to come down from iCloud.
                while next < min(3, count) {
                    let index = next
                    group.addTask { await stage(index) }
                    next += 1
                }
                for await staged in group {
                    if staged.isEmpty { unreadable += 1 }
                    files += staged
                    directories += Set(staged.map { $0.deletingLastPathComponent() })
                    preparing?.done += 1
                    // An import that ended meanwhile went into the notifications; this one stays shown.
                    if !queue.showsBanner { queue.showsBanner = true }
                    if Task.isCancelled { group.cancelAll(); continue }
                    if next < count {
                        let index = next
                        group.addTask { await stage(index) }
                        next += 1
                    }
                }
            }
            preparing = nil
            // The queue takes no files while it looks through folders it was given.
            while queue.discovering && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
            }
            preparation = nil
            if Task.isCancelled {
                for directory in directories { try? FileManager.default.removeItem(at: directory) }
                if !queue.isRunning && queue.items.isEmpty && queue.lastError == nil { queue.showsBanner = false }
                return
            }
            handedOver += directories
            if files.isEmpty {
                queue.lastError = unreadable == 1
                    ? "The chosen photo could not be read."
                    : "The chosen photos could not be read."
            } else {
                queue.enqueue(files, albumID: albumID)
            }
            sweepWhenDone()
        }
    }

    /// Files and folders chosen in Files. The queue holds their security-scoped access while it reads them, and
    /// lets it go when the import is closed.
    func importFiles(_ urls: [URL], albumID: String?) {
        guard let queue, !urls.isEmpty else { return }
        Self.askForNotificationsOnce()
        queue.enqueue(urls, albumID: albumID)
    }

    /// Stop writing out picked photos; what was written goes.
    func cancelPreparing() {
        preparation?.cancel()
    }

    // MARK: The files written for the queue

    /// Every 5 seconds while any are kept: a folder goes once the queue is not looking for files and none of the
    /// folder's files is in its list, which it keeps until the import is closed or the next one starts, so Retry
    /// still finds them.
    private func sweepWhenDone() {
        guard sweeping == nil else { return }
        sweeping = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                self.sweep()
                if self.handedOver.isEmpty {
                    self.sweeping = nil
                    return
                }
            }
        }
    }

    private func sweep() {
        guard let queue else {
            for directory in handedOver { try? FileManager.default.removeItem(at: directory) }
            handedOver = []
            return
        }
        guard !queue.discovering else { return }
        let inUse = Set(queue.items.map { $0.url.deletingLastPathComponent().lastPathComponent })
        handedOver.removeAll { directory in
            guard !inUse.contains(directory.lastPathComponent) else { return false }
            try? FileManager.default.removeItem(at: directory)
            return true
        }
    }

    // MARK: Following the queue

    /// The queue's start and end, followed whatever is on screen: the time to finish in the background, its progress
    /// for the system, and a notification at its end while Verso is in the background.
    private func observeQueue() {
        guard let queue else { return }
        let state = withObservationTracking {
            (running: queue.isRunning, completed: queue.completed, total: queue.items.count)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeQueue() }
        }
        if state.running && !wasRunning {
            beginBackgroundTime()
        }
        if state.running {
            reportProgress(completed: state.completed, total: state.total)
        }
        if !state.running && wasRunning {
            ended(queue)
        }
        wasRunning = state.running
    }

    private func ended(_ queue: UploadQueue) {
        let outcome = queue.outcome
        if UIApplication.shared.applicationState == .background {
            Self.notify(outcome)
        }
        if let continuedTask {
            continuedTask.updateTitle(outcome.title, subtitle: outcome.detail ?? "")
            continuedTask.setTaskCompleted(success: !outcome.needsLook)
            self.continuedTask = nil
        }
        endBackgroundTime()
    }

    /// Time to go on after Verso goes into the background: the half minute or so iOS gives any app, and, where the
    /// Info.plist permits its identifier, a continued processing task the system shows with its own progress and lets
    /// the person stop.
    private func beginBackgroundTime() {
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Import") { [weak self] in
                MainActor.assumeIsolated { self?.endBackgroundTime() }
            }
        }
        submitContinuedTask()
    }

    private func endBackgroundTime() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// The identifiers the app's Info.plist permits are `<bundle identifier>.import.*`; without them, nothing is asked
    /// of the system.
    private func submitContinuedTask() {
        guard continuedTask == nil, let bundle = Bundle.main.bundleIdentifier else { return }
        let identifier = "\(bundle).import.\(UUID().uuidString)"
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        guard permitted.contains(where: { $0 == identifier || ($0.hasSuffix("*") && identifier.hasPrefix(String($0.dropLast()))) })
        else { return }
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self?.continuedTaskStarted(task)
            }
        }
        guard registered else { return }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: "Importing to Immich",
                                                       subtitle: "Starting")
        request.strategy = .fail
        try? BGTaskScheduler.shared.submit(request)
    }

    private func continuedTaskStarted(_ task: BGContinuedProcessingTask) {
        guard let queue, queue.isRunning else {
            task.setTaskCompleted(success: true)
            return
        }
        continuedTask = task
        // Stopped from the system's progress, or out of time: the import is cancelled, and Retry takes it up again.
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                self?.queue?.cancelAll()
                self?.continuedTask = nil
            }
        }
        reportProgress(completed: queue.completed, total: queue.items.count)
    }

    private func reportProgress(completed: Int, total: Int) {
        guard let continuedTask else { return }
        continuedTask.progress.totalUnitCount = Int64(max(total, 1))
        continuedTask.progress.completedUnitCount = Int64(completed)
        continuedTask.updateTitle("Importing to Immich", subtitle: total == 0 ? "Looking for files" : "\(completed) of \(total)")
    }

    // MARK: Notifications

    /// Asked once, as the first import starts: the system asks only while the person has not answered.
    private static func askForNotificationsOnce() {
        Task { await ImportNotifications.askOnce() }
    }

    /// What the import came to, as the account's notifications keep it.
    private static func notify(_ outcome: VersoNotification) {
        let title = outcome.title
        let detail = outcome.detail
        Task { await ImportNotifications.post(title: title, body: detail) }
    }
}

/// The system's notifications about imports, asked for and posted away from the main actor.
enum ImportNotifications {
    static func askOnce() async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    static func post(title: String, body: String?) async {
        let content = UNMutableNotificationContent()
        content.title = title
        if let body { content.body = body }
        content.sound = .default
        let request = UNNotificationRequest(identifier: "import-ended", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// Picked photos as files for the queue: each in a folder of its own under the app's temporary folder, so two of one
/// name never meet and the queue sends each under its original name.
enum ImportStaging {
    static let root = FileManager.default.temporaryDirectory.appendingPathComponent("Verso Imports", isDirectory: true)

    /// A dropped item's files, or none when it could not be read: a Live Photo's photo and video, else the first
    /// photo or video it offers, in its own format, copied before the system takes its copy away.
    static func stage(_ provider: NSItemProvider) async -> [URL] {
        if provider.canLoadObject(ofClass: PHLivePhoto.self) {
            let livePhoto: PHLivePhoto? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: PHLivePhoto.self) { object, _ in
                    continuation.resume(returning: object as? PHLivePhoto)
                }
            }
            if let livePhoto, let files = try? await livePhotoFiles(livePhoto), !files.isEmpty { return files }
        }
        guard let type = provider.registeredContentTypes.first(where: { $0.conforms(to: .image) || $0.conforms(to: .movie) })
        else { return [] }
        let fallback = type.conforms(to: .movie) ? "Video.mov" : "Photo.heic"
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { file, _, _ in
                guard let file, let kept = try? keep(file, fallback: fallback) else {
                    continuation.resume(returning: [])
                    return
                }
                continuation.resume(returning: [kept])
            }
        }
    }

    /// Whether a drop holds anything to import: a photo or a video, and none of the app's own drags of its photos,
    /// which are in Immich already.
    static func canImport(_ providers: [NSItemProvider]) -> Bool {
        !providers.isEmpty && providers.allSatisfy { provider in
            !provider.hasItemConformingToTypeIdentifier(UTType.immichOriginalDrag.identifier)
        } && providers.contains { provider in
            provider.registeredContentTypes.contains { $0.conforms(to: .image) || $0.conforms(to: .movie) }
        }
    }

    /// A file the system lends for a moment, copied into a folder of its own under its own name.
    static func keep(_ file: URL, fallback: String) throws -> URL {
        let folder = try makeFolder()
        let kept = folder.appendingPathComponent(fileName(file.lastPathComponent, fallback: fallback))
        do {
            try FileManager.default.copyItem(at: file, to: kept)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return kept
    }

    /// The item's files, or none when it could not be read.
    static func stage(_ item: PhotosPickerItem) async -> [URL] {
        var files: [URL] = []
        if item.supportedContentTypes.contains(where: { $0.conforms(to: .livePhoto) }) {
            files = (try? await livePhoto(item)) ?? []
        }
        if files.isEmpty, let picked = try? await item.loadTransferable(type: ImportPickedFile.self) {
            files = [picked.url]
        }
        if let asset = libraryAsset(item.itemIdentifier) {
            files = files.map { originalName($0, in: asset) }
            if let date = asset.creationDate {
                // Immich reads a photo's date from inside it; a file without one takes the date the library has.
                for file in files {
                    try? FileManager.default.setAttributes([.creationDate: date, .modificationDate: date],
                                                           ofItemAtPath: file.path)
                }
            }
        }
        return files
    }

    /// The file under the name the library keeps for it, when the library has one of the same kind.
    private static func originalName(_ file: URL, in asset: PHAsset) -> URL {
        let kind = file.pathExtension.lowercased()
        guard let original = PHAssetResource.assetResources(for: asset)
            .first(where: { ($0.originalFilename as NSString).pathExtension.lowercased() == kind })?.originalFilename,
              original != file.lastPathComponent else { return file }
        let renamed = file.deletingLastPathComponent().appendingPathComponent(fileName(original, fallback: file.lastPathComponent))
        do {
            try FileManager.default.moveItem(at: file, to: renamed)
            return renamed
        } catch {
            return file
        }
    }

    /// A folder of its own for one picked item.
    static func makeFolder() throws -> URL {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A name that is safe as a file's, keeping what it can of the original.
    static func fileName(_ original: String, fallback: String) -> String {
        let cleaned = original.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? fallback : cleaned
    }

    /// A Live Photo's original photo and video, as the library keeps them.
    private static func livePhoto(_ item: PhotosPickerItem) async throws -> [URL] {
        guard let livePhoto = try await item.loadTransferable(type: PHLivePhoto.self) else { return [] }
        return try await livePhotoFiles(livePhoto)
    }

    private static func livePhotoFiles(_ livePhoto: PHLivePhoto) async throws -> [URL] {
        let resources = PHAssetResource.assetResources(for: livePhoto)
            .filter { $0.type == .photo || $0.type == .pairedVideo }
        guard resources.contains(where: { $0.type == .photo }) else { return [] }
        let folder = try makeFolder()
        var files: [URL] = []
        do {
            for resource in resources {
                let fallback = resource.type == .photo ? "Live Photo.heic" : "Live Photo.mov"
                let file = folder.appendingPathComponent(fileName(resource.originalFilename, fallback: fallback))
                let options = PHAssetResourceRequestOptions()
                options.isNetworkAccessAllowed = true
                try await PHAssetResourceManager.default().writeData(for: resource, toFile: file, options: options)
                files.append(file)
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return files
    }

    /// The photo as the library has it, with its date and original names: only where the person has given Verso
    /// access to the library, which the picker itself does not need, so Verso never asks for it.
    private static func libraryAsset(_ identifier: String?) -> PHAsset? {
        guard let identifier else { return nil }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }
        return PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
    }
}

/// A photo or video from the picker as the file the library keeps (with the picker's `.current` encoding, its
/// original format: HEIC stays HEIC), copied into a folder of its own before the picker removes its copy.
struct ImportPickedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            try ImportPickedFile(url: keep(received.file, fallback: "Video.mov"))
        }
        FileRepresentation(importedContentType: .image) { received in
            try ImportPickedFile(url: keep(received.file, fallback: "Photo.heic"))
        }
    }

    private static func keep(_ file: URL, fallback: String) throws -> URL {
        try ImportStaging.keep(file, fallback: fallback)
    }
}
