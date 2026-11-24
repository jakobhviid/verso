// The work behind two of the photo menu's quick actions on iOS (PhotoActionsMenu), for a grid's photos and the
// viewer's: Copy, which puts the originals on the pasteboard, each in its own format, as Photos copies a photo; and
// Save to Photos, which saves the originals into the phone's photo library, a Live Photo as both its parts
// (`PHAssetCreationRequest` with `.photo` and `.pairedVideo`) and a video as a video, dated and placed as Immich has
// them, so a date or place changed in Immich comes along. Saving asks only to add photos (add-only access,
// NSPhotoLibraryAddUsageDescription), never to read the library; a photo backing up's store knows came from this phone
// and is still on it is not saved a second time (BackupCenter.photosOnPhone). The originals download into a folder of
// their own, which goes once they are on the pasteboard or in the library. Photos on their way to Immich are copied
// from the phone (PhoneImages.export).

import CoreLocation
import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
enum PhotoActionWork {
    /// What Save to Photos did.
    struct Saved {
        var saved = 0
        /// Photos already on this phone, from backing up's store or on their way from it.
        var alreadyOnPhone = 0

        /// "Saved to Photos", "Saved 3 Items to Photos", "Already on This iPhone", or both together.
        @MainActor var words: String {
            let device = UIDevice.current.localizedModel
            switch (saved, alreadyOnPhone) {
            case (0, 0): return String(localized: "Nothing to Save")
            case (0, _): return String(localized: "Already on This \(device)")
            case (1, 0): return String(localized: "Saved to Photos")
            case (_, 0): return String(localized: "Saved \(saved) Items to Photos")
            default: return String(localized: "Saved \(saved) to Photos, \(alreadyOnPhone) Already on This \(device)")
            }
        }
    }

    enum Failure: LocalizedError {
        case notAllowed

        var errorDescription: String? {
            String(localized: "Verso may not add to your photos. Allow it in Settings, Privacy & Security, Photos.")
        }
    }

    // MARK: Copy

    /// The originals on the pasteboard, Immich's and the phone's, each in the format its file has.
    static func copy(_ ids: [String], phone: [String], client: ImmichClient?) async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var files: [URL] = []
        for localID in phone {
            try Task.checkCancellation()
            files.append(try await PhoneImages.export(localID, into: try subfolder(of: folder)))
        }
        if let client {
            for id in ids {
                try Task.checkCancellation()
                let file = try await client.macIntegrationOriginal(id)
                defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
                let kept = try subfolder(of: folder).appendingPathComponent(file.lastPathComponent)
                try FileManager.default.moveItem(at: file, to: kept)
                files.append(kept)
            }
        }
        var items: [[String: Any]] = []
        for file in files {
            let data = try await Task.detached { try Data(contentsOf: file) }.value
            let type = UTType(filenameExtension: file.pathExtension) ?? .data
            items.append([type.identifier: data])
        }
        try Task.checkCancellation()
        UIPasteboard.general.setItems(items)
    }

    // MARK: Save to Photos

    /// Saves Immich's photos into the phone's photo library, leaving out those already on the phone; `phone` counts the
    /// photos on their way from it, which are on it already.
    static func saveToPhotos(_ ids: [String], phone: Int, session: LibrarySession) async throws -> Saved {
        var saved = Saved(alreadyOnPhone: phone)
        guard !ids.isEmpty else { return saved }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw Failure.notAllowed }
        let onPhone = await BackupCenter.shared.photosOnPhone(ids)
        let client = session.client
        for id in ids {
            try Task.checkCancellation()
            if onPhone[id] != nil {
                saved.alreadyOnPhone += 1
                continue
            }
            let asset = try await client.asset(id)
            let original = try await client.macIntegrationOriginal(id)
            defer { try? FileManager.default.removeItem(at: original.deletingLastPathComponent()) }
            var pairedVideo: URL?
            if asset.type == .image, let videoID = asset.livePhotoVideoId {
                pairedVideo = try await client.macIntegrationOriginal(videoID)
            }
            defer { if let pairedVideo { try? FileManager.default.removeItem(at: pairedVideo.deletingLastPathComponent()) } }
            try await save(PhotoToSave(asset: asset, file: original, pairedVideo: pairedVideo))
            saved.saved += 1
        }
        return saved
    }

    /// What one creation request takes, as plain values for PhotoKit's queue.
    private struct PhotoToSave: Sendable {
        let file: URL
        let pairedVideo: URL?
        let isVideo: Bool
        let name: String
        let created: Date?
        let latitude: Double?
        let longitude: Double?

        init(asset: AssetResponse, file: URL, pairedVideo: URL?) {
            self.file = file
            self.pairedVideo = pairedVideo
            isVideo = asset.type == .video
            name = (asset.originalFileName as NSString).lastPathComponent
            created = ImmichDate.parse(asset.exifInfo?.dateTimeOriginal ?? asset.fileCreatedAt)
            latitude = asset.exifInfo?.latitude
            longitude = asset.exifInfo?.longitude
        }
    }

    private nonisolated static func save(_ photo: PhotoToSave) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            if !photo.name.isEmpty { options.originalFilename = photo.name }
            request.addResource(with: photo.isVideo ? .video : .photo, fileURL: photo.file, options: options)
            if let pairedVideo = photo.pairedVideo {
                request.addResource(with: .pairedVideo, fileURL: pairedVideo, options: nil)
            }
            if let created = photo.created { request.creationDate = created }
            if let latitude = photo.latitude, let longitude = photo.longitude {
                request.location = CLLocation(latitude: latitude, longitude: longitude)
            }
        }
    }

    // MARK: Files

    private static func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("VersoCopy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A folder of its own for each file, so two of one name never meet.
    private static func subfolder(of folder: URL) throws -> URL {
        let item = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        return item
    }
}
