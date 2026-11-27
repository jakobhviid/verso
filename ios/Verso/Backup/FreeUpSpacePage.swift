// Free Up Space on the iPhone (ROADMAP.md, M10, "Free Up Space"; ARCHITECTURE.md, "Free Up Space"): photos older
// than the person keeps on the phone, safe in Immich, removed from the phone only after the person reviews them and
// iOS asks. Nothing deletes on its own: a reminder may say there is space to gain, never more.
// - FreeUpRow, the Backup page's row, with what is ready to free, opening FreeUpSpacePage: Keep on This iPhone
//   (Forever, the default, until the person chooses a period, which asks once what deleting means for iCloud Photos
//   and a Shared Library), what can be freed, Review and Free Up, and Always Keep with what it keeps.
// - FreeUpKeepPage, Always Keep: the favourites, as Photos has them, hidden photos where chosen, and the albums on this
//   iPhone the person picks.
// - FreeUpReviewPage: the photos, by month, all ticked, each checked with Immich as the page opens (BackupEngine's
//   safety checks) and those that must stay listed with why, under what Always Keep keeps; hidden photos as a group of
//   their own, a count until the account's PIN unlocks the session to check them in the Locked Folder (Face ID where
//   the PIN was typed in this run) and pictures only after Face ID; Delete asks a second time where some are only in
//   iCloud, checks again, and iOS asks; then what to do to get the space now. The session is locked again as the review
//   closes.
// - FreeUpCard: the Library's card when a gigabyte or more is ready to free, or, while Keep on This iPhone is Forever,
//   when the phone runs short of space.

import LocalAuthentication
import Photos
import SwiftUI
import UIKit

/// The Backup page's row for Free Up Space: what is ready to free, that the phone is short of space, or how long photos
/// stay on it.
struct FreeUpRow: View {
    private var center: BackupCenter { BackupCenter.shared }

    var body: some View {
        NavigationLink {
            FreeUpSpacePage()
        } label: {
            LabeledContent("Free Up Space") {
                Text(value ?? "")
                    .foregroundStyle(ready ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
        }
        .accessibilityIdentifier("Free Up Space")
    }

    private var ready: Bool { (center.snapshot.freeable?.count ?? 0) > 0 && center.settings.keepMonths != nil }

    private var value: String? {
        let settings = center.settings
        if let months = settings.keepMonths {
            if ready, let freeable = center.snapshot.freeable {
                return String(localized: "\(freeable.bytes.formatted(.byteCount(style: .file))) to Free")
            }
            return String(localized: "Keep \(FreeUpPeriod.name(months))")
        }
        if let offer = center.snapshot.spaceOffer, offer.count > 0 {
            return String(localized: "Short of Space")
        }
        return nil
    }
}

/// Free Up Space, from the Backup page's row, or the Library's card for a phone short of space.
struct FreeUpSpacePage: View {
    var body: some View {
        List {
            FreeUpSection()
        }
        .navigationTitle("Free Up Space")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Free Up Space's page: how long photos stay, what is ready to free, and what is always kept.
private struct FreeUpSection: View {
    /// A period chosen while what deleting means is not yet understood: asked first.
    @State private var asking: Int?

    private var center: BackupCenter { BackupCenter.shared }

    var body: some View {
        let settings = center.settings
        Section {
            Picker("Keep on This \(DeviceWords.model)", selection: Binding(get: { settings.keepMonths ?? 0 },
                                                             set: { choose($0 == 0 ? nil : $0) })) {
                Text("Forever").tag(0)
                ForEach(FreeUpRules.periods, id: \.self) { months in
                    Text(FreeUpPeriod.name(months)).tag(months)
                }
            }
            .pickerStyle(.menu)
            .confirmationDialog("Before Verso frees up space", isPresented: askingShown, titleVisibility: .visible,
                                presenting: asking) { months in
                Button("Keep \(FreeUpPeriod.name(months)) on This \(DeviceWords.model)") {
                    center.understandFreeUp()
                    center.setKeep(months: months)
                }
            } message: { _ in
                Text("Verso removes photos older than that from this \(DeviceWords.model) once each is safe in Immich, only after you review them and iOS asks. \(FreeUpKeep.sentence(settings)) With iCloud Photos, deleting a photo here deletes it from iCloud and every device signed in to it; in an iCloud Shared Library, it is deleted for everyone in it. Deleted photos stay in Recently Deleted for 30 days.")
            }
            if settings.keepMonths == nil, let offer = center.snapshot.spaceOffer, offer.count > 0 {
                Text("This \(DeviceWords.model) is short of space: \(offer.bytes.formatted(.byteCount(style: .file))) of photos and videos older than a year are safe in Immich. Choose how long to keep them here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let months = settings.keepMonths {
                if let freeable = center.snapshot.freeable, freeable.count > 0 {
                    NavigationLink {
                        FreeUpReviewPage(months: months)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Review and Free Up \(freeable.bytes.formatted(.byteCount(style: .file)))")
                                .foregroundStyle(.tint)
                            Text("\(BackupStatus.itemCount(freeable.count)) older than \(FreeUpPeriod.phrase(months)), safe in Immich")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("Review and Free Up")
                } else {
                    Text("Nothing older than \(FreeUpPeriod.phrase(months)) is ready to go")
                        .foregroundStyle(.secondary)
                }
            }
            NavigationLink {
                FreeUpKeepPage()
            } label: {
                LabeledContent("Always Keep", value: FreeUpKeep.summary(settings))
            }
            .accessibilityIdentifier("Always Keep")
        } footer: {
            Text("Verso never deletes on its own: you review what goes, and iOS asks before anything is deleted. Only photos safe in Immich go, to Recently Deleted, where they stay for 30 days.")
        }
    }

    private var askingShown: Binding<Bool> {
        Binding(get: { asking != nil }, set: { if !$0 { asking = nil } })
    }

    private func choose(_ months: Int?) {
        if months != nil && !center.freeUpUnderstood {
            asking = months
            return
        }
        center.setKeep(months: months)
    }
}

/// Always Keep: what Free Up Space leaves on the phone whatever its age.
struct FreeUpKeepPage: View {
    @State private var albums: [(id: String, title: String, count: Int)] = []

    private var center: BackupCenter { BackupCenter.shared }

    var body: some View {
        let settings = center.settings
        List {
            Section {
                Toggle("Favorites", isOn: Binding(get: { settings.keepFavorites }, set: { center.setKeepFavorites($0) }))
                Toggle("Hidden", isOn: Binding(get: { settings.keepHidden || !settings.hiddenPhotos },
                                               set: { center.setKeepHidden($0) }))
                    .disabled(!settings.hiddenPhotos)
            } footer: {
                Text(settings.hiddenPhotos
                     ? "Your favorites in Photos, and hidden photos where chosen, stay whatever their age. Hidden photos are in Immich's Locked Folder: freeing them asks for your Immich PIN."
                     : "Your favorites in Photos stay, whatever their age. Hidden photos stay too, as Hidden Photos is off in the options.")
            }
            Section {
                if albums.isEmpty {
                    Text("No albums on this \(DeviceWords.model)").foregroundStyle(.secondary)
                }
                ForEach(albums, id: \.id) { album in
                    chosenRow(album.title, detail: album.count.formatted(), chosen: settings.keepAlbums.contains(album.id)) {
                        center.setKeepAlbums(toggled(settings.keepAlbums, album.id))
                    }
                }
            } header: {
                Text("Albums")
            } footer: {
                Text("Photos in the albums you tick stay, whatever their age.")
            }
        }
        .navigationTitle("Always Keep")
        .navigationBarTitleDisplayMode(.inline)
        .task { albums = BackupLibrary.albums() }
    }

    private func chosenRow(_ title: String, detail: String?, chosen: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if let detail { Text(detail).foregroundStyle(.secondary) }
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .opacity(chosen ? 1 : 0)
                    .accessibilityHidden(!chosen)
            }
        }
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private func toggled(_ list: [String], _ id: String) -> [String] {
        list.contains(id) ? list.filter { $0 != id } : list + [id]
    }
}

/// The review: the photos to remove, by month, all ticked, each checked with Immich as the page opens.
struct FreeUpReviewPage: View {
    let months: Int
    @State private var candidates: [FreeUpCandidate] = []
    @State private var loaded = false
    @State private var checked = 0
    @State private var checking = false
    /// Why a photo stays, by its local identifier: what the safety checks found.
    @State private var staying: [String: String] = [:]
    @State private var unticked = Set<String>()
    /// The photos stored only in iCloud: deleting them deletes them from iCloud.
    @State private var onlyInCloud = Set<String>()
    @State private var askingCloud = false
    @State private var deleting = false
    @State private var outcome: BackupCenter.FreeUpOutcome?
    /// What Always Keep kept when the photos were last read and checked: changed from the review, they are read again.
    @State private var loadedFor: String?
    /// Hidden photos, checked once the account's PIN unlocked the session, and shown only after Face ID.
    @State private var hiddenChecked = false
    @State private var checkingHidden = false
    @State private var hiddenRevealed = false
    @State private var askingPIN = false
    @State private var pin = ""
    @State private var pinError: String?
    /// The review unlocked the session, and locks it again as it closes.
    @State private var unlockedHere = false
    @Environment(\.isPresented) private var isPresented
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var center: BackupCenter { BackupCenter.shared }

    /// What goes: every photo that passed its checks and is ticked; a hidden one once checked with the PIN.
    private var going: [FreeUpCandidate] {
        candidates.filter { candidate in
            let identifier = candidate.photo.localID
            guard staying[identifier] == nil, !unticked.contains(identifier) else { return false }
            return !candidate.photo.hidden || hiddenChecked
        }
    }

    private var hiddenCandidates: [FreeUpCandidate] { candidates.filter(\.photo.hidden) }

    var body: some View {
        let going = going
        let bytes = going.reduce(0) { $0 + $1.size }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                summary(count: going.count, bytes: bytes)
                    .padding(.horizontal)
                if !hiddenCandidates.isEmpty {
                    hiddenGroup
                        .padding(.horizontal)
                }
                ForEach(months(of: candidates.filter { staying[$0.photo.localID] == nil && !$0.photo.hidden }), id: \.month) { group in
                    Section {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 4), spacing: 2) {
                            ForEach(group.photos, id: \.photo.localID) { candidate in
                                tile(candidate)
                            }
                        }
                    } header: {
                        monthHeader(group)
                    }
                }
                if !staying.isEmpty {
                    stayingList
                        .padding(.horizontal)
                }
            }
            .padding(.bottom, 100)
        }
        .overlay {
            if loaded && candidates.isEmpty {
                ContentUnavailableView("Nothing to free", systemImage: "checkmark.circle",
                                       description: Text("Nothing older than \(FreeUpPeriod.phrase(months)) is safe in Immich and free to go."))
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !candidates.isEmpty {
                Button(role: .destructive) {
                    if going.contains(where: { onlyInCloud.contains($0.photo.localID) }) { askingCloud = true }
                    else { Task { await delete() } }
                } label: {
                    Text(deleting ? "Checking once more…"
                         : "Delete \(BackupStatus.itemCount(going.count)) from This \(DeviceWords.model) · \(bytes.formatted(.byteCount(style: .file)))")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .controlSize(.large)
                .disabled(checking || checkingHidden || deleting || going.isEmpty || loadedFor != keepKey)
                .padding(.horizontal)
                .padding(.bottom, 8)
                .accessibilityIdentifier("Delete from This iPhone")
            }
        }
        .navigationTitle("Free Up Space")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Some are only in iCloud", isPresented: $askingCloud, titleVisibility: .visible) {
            Button("Delete from This \(DeviceWords.model) and iCloud", role: .destructive) { Task { await delete() } }
        } message: {
            let count = going.filter { onlyInCloud.contains($0.photo.localID) }.count
            Text("\(BackupStatus.itemCount(count)) of these are stored only in iCloud, a sign iCloud Photos is on: deleting them deletes them from iCloud and every device signed in to it, and for everyone in a Shared Library. Each is safe in Immich.")
        }
        .sheet(item: Binding(get: { outcome.flatMap(FreeUpDone.init) }, set: { if $0 == nil { finish() } })) { done in
            FreeUpDoneSheet(done: done) { finish() }
        }
        .alert("Nothing was deleted", isPresented: Binding(get: { if case .failed = outcome { true } else { false } },
                                                           set: { if !$0 { outcome = nil } })) {
            Button("OK") { outcome = nil }
        } message: {
            if case .failed(let message) = outcome { Text(message) }
        }
        .sheet(isPresented: $askingPIN) { pinSheet }
        .task(id: keepKey) { await load() }
        // The session unlocked for the hidden photos is locked again once the review is left.
        .onChange(of: isPresented) { _, shown in if !shown { relock() } }
    }

    private var keepKey: String {
        "\(center.settings.keepFavorites)|\(center.settings.keepAlbums.joined(separator: ","))"
    }

    // MARK: Loading and checking

    /// The photos read and checked, once for what Always Keep keeps: again only after it changed. A check cut short (the
    /// page covered by Always Keep) runs again when the page shows.
    private func load() async {
        let key = keepKey
        guard loadedFor != key else { return }
        candidates = await center.freeUpCandidates()
        unticked.formIntersection(candidates.map(\.photo.localID))
        staying = [:]
        onlyInCloud = []
        checked = 0
        hiddenChecked = false
        hiddenRevealed = false
        loaded = true
        // Hidden photos are checked once the account's PIN unlocks the session (checkHidden).
        let shown = candidates.filter { !$0.photo.hidden }
        guard !shown.isEmpty else {
            loadedFor = key
            return
        }
        checking = true
        defer { checking = false }
        let found = await center.freeUpVerify(shown, readBorrowed: true) { done in
            Task { @MainActor in checked = done }
        }
        guard !Task.isCancelled else { return }
        staying = found
        onlyInCloud = await Self.onlyInCloud(shown.map(\.photo.localID).filter { found[$0] == nil })
        guard !Task.isCancelled else { return }
        loadedFor = key
    }

    /// Which are stored only in iCloud, eight asked at a time: their first bytes, without the network.
    private static func onlyInCloud(_ passing: [String]) async -> Set<String> {
        await withTaskGroup(of: (String, Bool).self) { group in
            var cloud = Set<String>()
            var running = 0
            for identifier in passing {
                if running == 8, let (done, onPhone) = await group.next() {
                    running -= 1
                    if !onPhone { cloud.insert(done) }
                }
                group.addTask { (identifier, await BackupLibrary.isOnPhone(identifier)) }
                running += 1
            }
            for await (done, onPhone) in group where !onPhone { cloud.insert(done) }
            return cloud
        }
    }

    // MARK: Hidden photos

    /// The account's PIN unlocks the session, so Immich answers for the photos in its Locked Folder; then each hidden
    /// photo is checked as the others were.
    private func unlockHidden(_ code: String, typed: Bool = true) async {
        guard let client = center.accountClient else { return }
        let key = center.lockedFolderKey, epoch = LockedFolderFaceID.epoch
        pinError = nil
        checkingHidden = true
        defer { checkingHidden = false }
        do {
            let status = try await CollectionsLockedFolderPage.uncached(client) { client in
                try await client.exploreUnlock(code, setup: false)
                return try await client.exploreAuth()
            }
            guard status.isElevated else { throw ImmichError.http(403, String(localized: "Immich did not unlock this session.")) }
            // A PIN typed is kept behind Face ID, as the Locked Folder keeps it.
            if typed, let key { try? LockedFolderFaceID.save(code, for: key, since: epoch) }
            unlockedHere = true
            askingPIN = false
            pin = ""
        } catch {
            // A PIN Immich turns down is not kept for Face ID.
            if LockedFolderFaceID.rejectsPIN(error), let key { LockedFolderFaceID.forget(key) }
            pinError = error.localizedDescription
            askingPIN = true
            return
        }
        let hidden = hiddenCandidates
        let found = await center.freeUpVerify(hidden, readBorrowed: true) { _ in }
        staying.merge(found) { first, _ in first }
        onlyInCloud.formUnion(await Self.onlyInCloud(hidden.map(\.photo.localID).filter { found[$0] == nil }))
        hiddenChecked = true
    }

    /// Face ID, where the Locked Folder's PIN is kept behind it, as the Locked Folder offers it.
    private var faceIDName: String? {
        LockedFolderFaceID.canUnlock(center.lockedFolderKey) ? LockedFolderFaceID.biometryName : nil
    }

    private func checkWithFaceID() async {
        guard let key = center.lockedFolderKey, case .pin(let code) = await LockedFolderFaceID.pin(for: key) else { return }
        await unlockHidden(code, typed: false)
    }

    private func reveal() async {
        if await Self.deviceOwner(String(localized: "Show the hidden photos")) { hiddenRevealed = true }
    }

    private static func deviceOwner(_ reason: String) async -> Bool {
        (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true
    }

    private func relock() {
        guard unlockedHere, let client = center.accountClient else { return }
        unlockedHere = false
        CollectionsLockedFolderPage.relock(client)
    }

    /// The hidden photos as one group: a count and their size, checked with the PIN, their pictures after Face ID.
    private var hiddenGroup: some View {
        let hidden = hiddenCandidates
        let passing = hidden.filter { staying[$0.photo.localID] == nil }
        let identifiers = passing.map(\.photo.localID)
        let goingHere = passing.filter { !unticked.contains($0.photo.localID) }
        let canUnlock = center.accountClient?.exploreSupportsLockedFolder ?? false
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("Hidden", systemImage: "lock.fill")
                    .font(.headline)
                Spacer()
                if hiddenChecked && !passing.isEmpty {
                    Button(identifiers.allSatisfy(unticked.contains) ? "Free All" : "Keep All") {
                        if identifiers.allSatisfy(unticked.contains) { unticked.subtract(identifiers) } else { unticked.formUnion(identifiers) }
                    }
                    .buttonStyle(.bordered)
                }
            }
            if !hiddenChecked {
                Text("\(BackupStatus.itemCount(hidden.count)) · \(hidden.reduce(0) { $0 + $1.size }.formatted(.byteCount(style: .file))), safe in Immich's Locked Folder.")
                    .foregroundStyle(.secondary)
                if checkingHidden {
                    ProgressView("Checking each with Immich")
                        .font(.footnote)
                } else if canUnlock {
                    Text("They stay unless you check them with your Immich PIN.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        if let faceIDName {
                            Button("Use \(faceIDName)") { Task { await checkWithFaceID() } }
                                .buttonStyle(.bordered)
                        }
                        Button("Enter PIN") { askingPIN = true }
                            .buttonStyle(.bordered)
                    }
                    .accessibilityIdentifier("Check Hidden Photos")
                } else {
                    Text("They stay on this \(DeviceWords.model): checking them in the Locked Folder needs your Immich PIN, which a sign-in with an API key cannot use.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("\(goingHere.count.formatted()) of \(passing.count.formatted()) · \(goingHere.reduce(0) { $0 + $1.size }.formatted(.byteCount(style: .file)))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if hiddenRevealed {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 4), spacing: 2) {
                        ForEach(passing, id: \.photo.localID) { candidate in tile(candidate) }
                    }
                } else if !passing.isEmpty {
                    Button("Show", systemImage: "eye") { Task { await reveal() } }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
    }

    private var pinSheet: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Immich PIN", text: $pin)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("Immich PIN")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("The six-digit PIN of your Immich Locked Folder. Verso unlocks it to check the hidden photos with Immich, and locks it again as you leave.")
                        if let pinError { Text(pinError).foregroundStyle(.red) }
                    }
                }
            }
            .navigationTitle("Hidden Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { askingPIN = false; pin = "" }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Unlock") { Task { await unlockHidden(pin) } }
                        .disabled(pin.range(of: "^[0-9]{6}$", options: .regularExpression) == nil || checkingHidden)
                }
            }
        }
        .presentationDetents([.medium])
    }

    /// Checked once more right before iOS asks, without reading again what the review read; what fails stays.
    private func delete() async {
        deleting = true
        defer { deleting = false }
        let chosen = going
        let found = await center.freeUpVerify(chosen, readBorrowed: false) { _ in }
        staying.merge(found) { first, _ in first }
        let safe = chosen.filter { found[$0.photo.localID] == nil }
        guard !safe.isEmpty else { return }
        let result = await center.freeUp(safe)
        if result != .declined { outcome = result }
    }

    private func finish() {
        outcome = nil
        relock()
        dismiss()
    }

    // MARK: Parts of the page

    private func summary(count: Int, bytes: Int64) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(BackupStatus.itemCount(count)) · \(bytes.formatted(.byteCount(style: .file)))")
                .font(.title2.bold())
            Text("Older than \(FreeUpPeriod.phrase(months)) and safe in Immich. Untick any to keep it on this \(DeviceWords.model).")
                .foregroundStyle(.secondary)
            NavigationLink {
                FreeUpKeepPage()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "heart")
                        .foregroundStyle(.secondary)
                    Text(FreeUpKeep.sentence(center.settings))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text("Change")
                        .foregroundStyle(.tint)
                }
                .font(.subheadline)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("Change Always Keep")
            if checking {
                ProgressView(value: Double(checked), total: Double(max(candidates.count, 1))) {
                    Text("Checking each with Immich: \(checked.formatted()) of \(candidates.count.formatted())")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 12)
    }

    private struct MonthGroup {
        let month: String
        let title: String
        let photos: [FreeUpCandidate]
    }

    private func months(of photos: [FreeUpCandidate]) -> [MonthGroup] {
        var groups: [String: [FreeUpCandidate]] = [:]
        var titles: [String: String] = [:]
        for photo in photos {
            let date = photo.photo.created ?? photo.photo.added ?? Date()
            let month = FreeUpRules.month(of: date)
            groups[month, default: []].append(photo)
            titles[month] = date.formatted(.dateTime.month(.wide).year())
        }
        return groups.keys.sorted(by: >).map { MonthGroup(month: $0, title: titles[$0] ?? $0, photos: groups[$0] ?? []) }
    }

    private func monthHeader(_ group: MonthGroup) -> some View {
        let ids = group.photos.map(\.photo.localID)
        let allKept = ids.allSatisfy(unticked.contains)
        let goingHere = group.photos.filter { !unticked.contains($0.photo.localID) }
        return HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(group.title).font(.headline)
                Text("\(goingHere.count.formatted()) of \(group.photos.count.formatted()) · \(goingHere.reduce(0) { $0 + $1.size }.formatted(.byteCount(style: .file)))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(allKept ? "Free All" : "Keep All") {
                if allKept { unticked.subtract(ids) } else { unticked.formUnion(ids) }
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func tile(_ candidate: FreeUpCandidate) -> some View {
        let identifier = candidate.photo.localID
        let ticked = !unticked.contains(identifier)
        return Button {
            if ticked { unticked.insert(identifier) } else { unticked.remove(identifier) }
        } label: {
            // A square, the photo filling it, as Photos' grid has them.
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { FreeUpThumbnail(identifier: identifier) }
                .clipped()
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: ticked ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, ticked ? Color.accentColor : .clear)
                        .shadow(color: .black.opacity(0.5), radius: 1.5)
                        .padding(5)
                }
                .overlay(alignment: .topLeading) {
                    if onlyInCloud.contains(identifier) {
                        Image(systemName: "icloud")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.5), radius: 1.5)
                            .padding(5)
                    }
                }
                .opacity(ticked ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(ticked ? "Goes" : "Stays")
    }

    private var stayingList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Staying on This \(DeviceWords.model)").font(.headline)
            Text("Each of these failed a check with Immich, so it stays. Verso looks again next time.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ForEach(candidates.filter { staying[$0.photo.localID] != nil }, id: \.photo.localID) { candidate in
                HStack(spacing: 12) {
                    FreeUpThumbnail(identifier: candidate.photo.localID, concealed: candidate.photo.hidden && !hiddenRevealed)
                        .frame(width: 48, height: 48)
                        .clipShape(.rect(cornerRadius: 6))
                    Text(staying[candidate.photo.localID] ?? "")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// What Always Keep keeps, in words: "Favorites, Hidden, 2 Albums" on its row, and a sentence for the review and the
/// question before the first period.
enum FreeUpKeep {
    static func summary(_ settings: BackupSettings) -> String {
        var parts: [String] = []
        if settings.keepFavorites { parts.append(String(localized: "Favorites")) }
        if keepsHidden(settings) { parts.append(String(localized: "Hidden")) }
        let albums = settings.keepAlbums.count
        if albums > 0 { parts.append(albums == 1 ? String(localized: "1 Album") : String(localized: "\(albums) Albums")) }
        return parts.isEmpty ? String(localized: "Nothing") : parts.joined(separator: ", ")
    }

    static func sentence(_ settings: BackupSettings) -> String {
        var kept: [String] = []
        if settings.keepFavorites { kept.append(String(localized: "favorites")) }
        if keepsHidden(settings) { kept.append(String(localized: "hidden photos")) }
        let albums = settings.keepAlbums.count
        if albums == 1 { kept.append(String(localized: "photos in 1 album")) }
        if albums > 1 { kept.append(String(localized: "photos in \(albums) albums")) }
        guard !kept.isEmpty else { return String(localized: "Favorites go too.") }
        let list = ListFormatter.localizedString(byJoining: kept)
        let capitalised = list.prefix(1).uppercased() + list.dropFirst()
        return settings.keepFavorites ? String(localized: "\(capitalised) stay.") : String(localized: "\(capitalised) stay; favorites go too.")
    }

    /// Hidden photos stay where Always Keep keeps them, or where they are not backed up at all.
    static func keepsHidden(_ settings: BackupSettings) -> Bool {
        settings.keepHidden || !settings.hiddenPhotos
    }
}

/// The Library's card for Free Up Space, above the tab bar where the invitation to back up shows (BackupInvitationCard):
/// what is ready to free, with Review, which opens the review itself; or, while Keep on This iPhone is Forever, that
/// the phone runs short of space, with Free Up Space, which opens its page to choose a period. Either, and
/// Not Now, puts the card aside (FreeUpRules.cardShown, spaceCardShown).
struct FreeUpCard: View {
    enum Kind { case ready, shortOfSpace }
    let kind: Kind

    private var center: BackupCenter { BackupCenter.shared }

    /// The card the Library shows now, if any.
    @MainActor static var shown: Kind? {
        let center = BackupCenter.shared
        if center.freeUpCardShown { return .ready }
        if center.spaceCardShown { return .shortOfSpace }
        return nil
    }

    var body: some View {
        let snapshot = center.snapshot
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: kind == .ready ? "internaldrive" : "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(kind == .ready ? Color.accentColor : .orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title(snapshot))
                    .font(.headline)
                Text(detail(snapshot))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Not Now") { putAside() }
                        .buttonStyle(.glass)
                    Button(kind == .ready ? "Review" : "Free Up Space") { open() }
                        .buttonStyle(.glassProminent)
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityIdentifier(kind == .ready ? "Free Up Card" : "Short of Space Card")
    }

    private func title(_ snapshot: BackupSnapshot) -> String {
        switch kind {
        case .ready:
            String(localized: "\((snapshot.freeable?.bytes ?? 0).formatted(.byteCount(style: .file))) Ready to Free Up")
        case .shortOfSpace:
            String(localized: "\(DeviceWords.model) Storage Almost Full")
        }
    }

    private func detail(_ snapshot: BackupSnapshot) -> String {
        switch kind {
        case .ready:
            let count = BackupStatus.itemCount(snapshot.freeable?.count ?? 0)
            return String(localized: "\(count) older than \(FreeUpPeriod.phrase(center.settings.keepMonths ?? 0)), safe in Immich.")
        case .shortOfSpace:
            let size = (snapshot.spaceOffer?.bytes ?? 0).formatted(.byteCount(style: .file))
            return String(localized: "\(size) of photos and videos older than a year are safe in Immich. Keep fewer on this \(DeviceWords.model) to make room.")
        }
    }

    private func putAside() {
        switch kind {
        case .ready: center.putAsideFreeUpCard()
        case .shortOfSpace: center.putAsideSpaceCard()
        }
    }

    private func open() {
        putAside()
        switch kind {
        case .ready: center.showFreeUp()
        case .shortOfSpace:
            center.freeUpPageRequested = true
            center.showPage()
        }
    }
}

/// What a delete came to, for the sheet after it.
private struct FreeUpDone: Identifiable {
    let count: Int
    let bytes: Int64
    let rawLeft: Int
    var id: Int { count }

    init?(_ outcome: BackupCenter.FreeUpOutcome) {
        guard case .deleted(let count, let bytes, let rawLeft) = outcome else { return nil }
        self.count = count
        self.bytes = bytes
        self.rawLeft = rawLeft
    }
}

/// After a delete: where the photos are, and how to get the space now.
private struct FreeUpDoneSheet: View {
    let done: FreeUpDone
    let close: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
                Text("Moved \(BackupStatus.itemCount(done.count)) to Recently Deleted")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text("Photos keeps them there for 30 days, and Verso keeps checking Immich for them until then. To get the \(done.bytes.formatted(.byteCount(style: .file))) now, empty Recently Deleted in Photos.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if done.rawLeft > 0 {
                    Text("\(BackupStatus.itemCount(done.rawLeft)) in ProRAW took too long for iOS to delete here: delete them in Photos.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Button("Open Photos") {
                    if let url = URL(string: "photos-redirect://") { openURL(url) }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
            .padding(24)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: close)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// A photo's thumbnail from Photos, for the review; a lock in its place where it is `concealed`, a hidden photo not
/// shown yet.
struct FreeUpThumbnail: View {
    let identifier: String
    var concealed = false
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if concealed {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Hidden")
            } else if let image {
                Image(uiImage: image).resizable().scaledToFill()
            }
        }
        .clipped()
        .task(id: concealed ? "" : identifier) {
            guard !concealed else { return }
            image = await Self.load(identifier)
        }
    }

    private static func load(_ identifier: String) async -> UIImage? {
        guard let asset = BackupLibrary.asset(identifier) else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        let answer = ThumbnailAnswer()
        return await withCheckedContinuation { continuation in
            answer.continuation = continuation
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 240, height: 240), contentMode: .aspectFill,
                                                  options: options) { image, info in
                // The opportunistic first, degraded image is kept only if no better one follows.
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !degraded { answer.give(image) }
            }
        }
    }
}

/// A thumbnail's answer, given once.
private final class ThumbnailAnswer: @unchecked Sendable {
    private let lock = NSLock()
    var continuation: CheckedContinuation<UIImage?, Never>?
    private var answered = false

    func give(_ image: UIImage?) {
        lock.lock()
        guard !answered else { lock.unlock(); return }
        answered = true
        let continuation = self.continuation
        lock.unlock()
        continuation?.resume(returning: image)
    }
}
