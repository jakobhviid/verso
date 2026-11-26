// The Backup page on iOS (SPEC.md, "Backing the iPhone up"; DESIGN.md, "The Backup page"), where everything about
// backing up happens: every way to it (the Library's card and line, the account's row, a notification, a Live
// Activity) opens this one page (BackupCenter.showPage). Each section has one subject, what needs the person first:
// - The top says what goes on, with one bar for the whole library split by what each photo is waiting for, as iPhone
//   Storage splits the device, and the one action the moment needs. A stop the person must put right is said there,
//   with what can be done (the answers to most of the library gone included), and so is an error that has lasted.
//   What Verso waits for (Wi-Fi, a connection, Immich, free space) is said calmly under the title (BackupStatus).
// - On This iPhone: the bar's parts as rows, each with its colour, its count, and its photos a tap away: In Immich, To
//   Upload, Needs a Look, In Another Form, Missing from Immich, Left Out (a page of its own: In Immich's Trash,
//   Deleted in Immich, those the person chose not to send, and screenshots), To Check.
// - On Its Way, the newest photos going; Free Up Space, a row opening its page (FreeUpSpacePage), where the Library's
//   card for a phone short of space leads; Checked with Immich, what Verso sent and when it last checked.
// - Uploading and Included, the options, which come under the top until the first run's Start, since what is
//   included changes what goes; Turn Off Backup at the foot.
// A list of iOS's own; only the title's symbol moves, while work goes on.

import Photos
import SwiftUI
import UIKit

struct BackupPage: View {
    let services: AccountServices
    @State private var confirmingMostGone: BackupMostGoneAnswer?
    @State private var confirmingOff = false
    #if DEBUG
    @State private var confirmingReset = false
    #endif
    /// On Its Way's newest photos, and the one open from the phone.
    @State private var waiting: [BackupWaitingPhoto] = []
    @State private var openedWaiting: OpenedAsset?
    @Namespace private var zoomNamespace
    @Environment(\.openURL) private var openURL

    private var center: BackupCenter { BackupCenter.shared }

    var body: some View {
        let snapshot = center.snapshot
        let tally = snapshot.tally
        List {
            Section {
                BackupHead(snapshot: snapshot, settings: center.settings, personRunActive: center.personRunActive) { action in
                    act(action)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))
            }
            // Until Start, what is included is chosen before the photos that go are looked through.
            if !snapshot.firstRunStarted && Self.offersOptions(snapshot.phase) {
                options
            }
            if Self.followsLibrary(snapshot.phase) {
                photos(tally, snapshot: snapshot)
            }
            if !waiting.isEmpty {
                BackupOnItsWaySection(photos: waiting, zoomNamespace: zoomNamespace) { photo in
                    openedWaiting = OpenedAsset(id: photo.localID)
                }
            }
            if center.settings.isOn && snapshot.firstRunStarted && Self.followsLibrary(snapshot.phase) {
                Section {
                    FreeUpRow()
                }
                checked(snapshot)
            }
            if snapshot.firstRunStarted && Self.offersOptions(snapshot.phase) {
                options
            }
            if center.settings.isOn {
                Section {
                    Button("Turn Off Backup", role: .destructive) { confirmingOff = true }
                }
            }
            #if DEBUG
            if !Self.forPictures {
            Section {
                Button("Reset Backup", role: .destructive) { confirmingReset = true }
            } footer: {
                Text("Verso Dev only: forgets everything backing up knows on this \(DeviceWords.model) and switches it off, to walk the first run again from the Library's card. Nothing in Immich changes.")
            }
            }
            #endif
        }
        .navigationTitle("Backup")
        .navigationBarTitleDisplayMode(.inline)
        // Free Up Space's review, asked for by the Library's card and line, or its reminder.
        .navigationDestination(isPresented: Binding(get: { center.reviewRequested }, set: { center.reviewRequested = $0 })) {
            if let months = center.settings.keepMonths { FreeUpReviewPage(months: months) }
        }
        // Free Up Space's page, asked for by the Library's card for a phone short of space.
        .navigationDestination(isPresented: Binding(get: { center.freeUpPageRequested }, set: { center.freeUpPageRequested = $0 })) {
            FreeUpSpacePage()
        }
        .task { await center.refresh() }
        .task(id: center.snapshot) {
            let fresh = await BackupOnItsWaySection.load()
            if fresh != waiting { waiting = fresh }
        }
        .fullScreenCover(item: $openedWaiting) { opened in
            PhoneViewer(session: nil, photos: waiting, startID: opened.id)
                .navigationTransition(.zoom(sourceID: opened.id, in: zoomNamespace))
        }
        .refreshable { await center.refresh() }
        // Back from Settings, where the person may have given Verso all of their photos.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            center.libraryAccessMayHaveChanged()
        }
        .confirmationDialog(mostGoneTitle, isPresented: mostGoneAsked, titleVisibility: .visible,
                            presenting: confirmingMostGone) { answer in
            Button(answer == .deleted ? "Let Them Go" : "Send Them Again", role: answer == .deleted ? .destructive : nil) {
                center.answerMostGone(answer)
            }
        } message: { answer in
            Text(answer == .deleted
                 ? "Verso counts them as deleted in Immich and never sends them again on its own."
                 : "Verso uploads them to your server again.")
        }
        .confirmationDialog("Turn off backup?", isPresented: $confirmingOff, titleVisibility: .visible) {
            Button("Turn Off Backup", role: .destructive) { Task { await center.setOn(false) } }
        } message: {
            Text("Backing up stops. Nothing is deleted, on this \(DeviceWords.model) or in Immich, and turning it on again goes on from where it stopped.")
        }
        #if DEBUG
        .confirmationDialog("Reset backup?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset Backup", role: .destructive) { Task { await center.resetForWalk() } }
        } message: {
            Text("Verso forgets every fingerprint and the first run, and the Library's card comes back. Nothing in Immich changes.")
        }
        #endif
    }

    #if DEBUG
    /// Verso Dev taking the App Store's and the website's pictures (`-screenshots YES`): its own rows stay out, so the
    /// page is the release's.
    private static let forPictures = UserDefaults.standard.bool(forKey: "screenshots")
    #endif

    /// The phases with options to set: all but those with no account to back up to.
    private static func offersOptions(_ phase: BackupSnapshot.Phase) -> Bool {
        phase != .signedOut && phase != .publicDemo
    }

    /// The phases with a library to account for, past what is read and checked.
    private static func followsLibrary(_ phase: BackupSnapshot.Phase) -> Bool {
        switch phase {
        case .off, .noAccess, .signedOut, .publicDemo: false
        default: true
        }
    }

    private func act(_ action: BackupHead.Action) {
        switch action {
        case .turnOn: Task { await center.setOn(true) }
        case .openSettings: if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        case .start: center.startFirstRun()
        case .backUpNow: center.backUpNow()
        case .checkAgain: center.answerMostGone(.checkAgain)
        case .sendAgain: confirmingMostGone = .sendAgain
        case .letGo: confirmingMostGone = .deleted
        }
    }

    // MARK: Checked with Immich

    /// What Verso did, for trust: what it sent, and the last check with Immich, with Check Again.
    private func checked(_ snapshot: BackupSnapshot) -> some View {
        Section {
            LabeledContent("Sent by Verso", value: BackupStatus.itemCount(snapshot.sentByVerso))
            #if DEBUG
            // Verso Dev: iCloud originals known through Immich's own app's metadata, rather than downloaded.
            if !Self.forPictures {
                LabeledContent("Known by iCloud Identifier", value: snapshot.borrowedFingerprints.formatted())
            }
            #endif
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last Checked with Immich")
                    Text(snapshot.lastChecked.map { $0.formatted(.relative(presentation: .named)) } ?? String(localized: "Not yet"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Check Again") { center.checkNow() }
                    .buttonStyle(.bordered)
            }
        } header: {
            Text("Checked with Immich")
        } footer: {
            Text("Verso checks each week that what it sent is still in Immich.")
        }
    }

    // MARK: Options

    /// When photos go, and which go.
    @ViewBuilder
    private var options: some View {
        let settings = center.settings
        Section {
            Toggle("Use Cellular for Photos", isOn: binding(BackupSettings.Key.cellularPhotos, settings.cellularPhotos))
            Toggle("Use Cellular for Videos", isOn: binding(BackupSettings.Key.cellularVideos, settings.cellularVideos))
            Toggle("Only While Charging", isOn: binding(BackupSettings.Key.onlyWhileCharging, settings.onlyWhileCharging))
        } header: {
            Text("Uploading")
        } footer: {
            Text("Low Data Mode is always respected. Only While Charging is for backing up on its own; Back Up Now goes at once.")
        }
        Section {
            Toggle("Screenshots", isOn: binding(BackupSettings.Key.screenshots, settings.screenshots))
            Toggle("Hidden Photos", isOn: binding(BackupSettings.Key.hiddenPhotos, settings.hiddenPhotos))
        } header: {
            Text("Included")
        } footer: {
            Text("Hidden photos go to Immich's Locked Folder, never your timeline. iOS shows them to Verso only while Use Face ID is off for Photos' hidden album: Settings, Apps, Photos. Shared Albums and photos synced from a computer are never backed up.")
        }
    }

    private func binding(_ key: String, _ value: Bool) -> Binding<Bool> {
        Binding(get: { value }, set: { center.set(key, $0) })
    }

    // MARK: Most of the library gone

    private var mostGoneTitle: String {
        confirmingMostGone == .deleted ? "Let the photos gone from Immich go?" : "Send the photos gone from Immich again?"
    }

    private var mostGoneAsked: Binding<Bool> {
        Binding(get: { confirmingMostGone != nil }, set: { if !$0 { confirmingMostGone = nil } })
    }

    // MARK: On this iPhone

    /// The bar's parts as rows, in its order and colours, each opening its photos: In Immich, To Upload, what needs the
    /// person (Needs a Look, In Another Form, Missing from Immich), Left Out, and To Check.
    private func photos(_ tally: BackupTally, snapshot: BackupSnapshot) -> some View {
        let toCheck = tally.total - tally.checked
        let leftOut = BackupLeftOutPage.count(tally, snapshot: snapshot)
        return Section {
            BackupGroupRow(title: String(localized: "In Immich"), value: tally.alreadyInImmich.formatted(), color: BackupBar.inImmich)
            if tally.toUpload > 0 {
                NavigationLink {
                    BackupPhotosPage(services: services, kind: .toUpload)
                } label: {
                    BackupGroupRow(title: String(localized: "To Upload"), value: BackupStatus.toGo(tally.toUpload, bytes: tally.toUploadBytes),
                                  color: BackupBar.toUpload)
                }
            }
            BackupGroupLink(services: services, kind: .needsLook, count: tally.needsLook, color: BackupBar.needsYou)
            BackupGroupLink(services: services, kind: .anotherForm, count: tally.anotherForm, color: BackupBar.needsYou)
            BackupGroupLink(services: services, kind: .missing, count: tally.missingFromImmich, color: BackupBar.needsYou)
            if leftOut > 0 {
                NavigationLink {
                    BackupLeftOutPage(services: services)
                } label: {
                    BackupGroupRow(title: String(localized: "Left Out"), value: leftOut.formatted(), color: BackupBar.leftOut)
                }
            }
            BackupGroupLink(services: services, kind: .toCheck, count: toCheck, color: BackupBar.toCheck)
        } header: {
            Text("On This \(DeviceWords.model) · \(BackupStatus.itemCount(tally.total))")
        } footer: {
            if !snapshot.firstRunStarted {
                Text("Look through what goes before you say Start. Don't Send keeps a photo on this \(DeviceWords.model) alone, as one you deleted in Immich long ago and kept here: once Immich's trash is emptied, nothing tells it from a new photo.")
            } else if tally.anotherForm > 0 {
                Text("\(tally.anotherForm.formatted()) look like they are in Immich already, in another form: taken at the same second under the same name, with other bytes, such as an export or an edit sent alone. They go only if you send them.")
            } else if tally.missingFromImmich > 0 {
                Text("Photos Verso backed up that are no longer in Immich. Verso never sends one again without your yes.")
            }
        }
    }
}

/// A part of the library as a row: the bar's colour, its name and its count.
private struct BackupGroupRow: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        LabeledContent {
            Text(value)
                .monospacedDigit()
        } label: {
            Label {
                Text(title)
            } icon: {
                Circle().fill(color).frame(width: 10, height: 10)
            }
        }
    }
}

/// A group's row, opening its photos; none where it has none.
private struct BackupGroupLink: View {
    let services: AccountServices
    let kind: BackupPhotosPage.Kind
    let count: Int
    var color: Color?

    var body: some View {
        if count > 0 {
            NavigationLink {
                BackupPhotosPage(services: services, kind: kind)
            } label: {
                if let color {
                    BackupGroupRow(title: kind.title, value: count.formatted(), color: color)
                } else {
                    LabeledContent(kind.title, value: count.formatted())
                }
            }
        }
    }
}

/// Left Out: what Verso leaves out on purpose, each group opening its photos, and the screenshots left out while
/// Screenshots is off.
private struct BackupLeftOutPage: View {
    let services: AccountServices

    private var center: BackupCenter { BackupCenter.shared }

    /// How many are left out, the screenshots included.
    static func count(_ tally: BackupTally, snapshot: BackupSnapshot) -> Int {
        tally.inImmichTrash + tally.deletedInImmich + tally.skipped + snapshot.screenshotsLeftOut
    }

    var body: some View {
        let snapshot = center.snapshot
        let tally = snapshot.tally
        List {
            Section {
                BackupGroupLink(services: services, kind: .trash, count: tally.inImmichTrash)
                BackupGroupLink(services: services, kind: .deleted, count: tally.deletedInImmich)
                BackupGroupLink(services: services, kind: .skipped, count: tally.skipped)
                if snapshot.screenshotsLeftOut > 0 {
                    LabeledContent("Screenshots", value: snapshot.screenshotsLeftOut.formatted())
                }
            } footer: {
                Text("Verso leaves these out on purpose: deleted in Immich, or kept off it by you. Nothing here is uploaded unless you say so. Screenshots go once Screenshots is on, under Included.")
            }
        }
        .overlay {
            if Self.count(tally, snapshot: snapshot) == 0 {
                ContentUnavailableView("None", systemImage: "checkmark.circle")
            }
        }
        .navigationTitle("Left Out")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The page's top: a symbol, what goes on and one line on it, an error that has lasted; the bar for the whole library;
/// and the one action the moment needs (Turn On Backup, Start, Back Up Now, Try Now), with a word under it where it
/// helps, or, with most of the library gone from Immich, the three answers.
private struct BackupHead: View {
    enum Action { case turnOn, openSettings, start, backUpNow, checkAgain, sendAgain, letGo }

    let snapshot: BackupSnapshot
    let settings: BackupSettings
    let personRunActive: Bool
    let act: (Action) -> Void

    var body: some View {
        let words = Self.words(snapshot, settings: settings)
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Image(systemName: words.symbol)
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(words.tint)
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: words.working)
                    .accessibilityHidden(true)
                Text(words.headline)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                if let line = words.line {
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if let error = snapshot.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            if Self.showsBar(snapshot.phase), snapshot.tally.total > 0 {
                BackupBar(tally: snapshot.tally)
            }
            if let action = action {
                Button {
                    act(action.kind)
                } label: {
                    Text(action.title)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(action.disabled)
                if let note = action.note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            if snapshot.phase == .stopped(.mostGone) {
                Button {
                    act(.checkAgain)
                } label: {
                    Text("Check Again").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                HStack(spacing: 12) {
                    Button { act(.sendAgain) } label: { Text("Send Them Again").frame(maxWidth: .infinity) }
                    Button(role: .destructive) { act(.letGo) } label: { Text("Let Them Go").frame(maxWidth: .infinity) }
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
        }
    }

    private static func showsBar(_ phase: BackupSnapshot.Phase) -> Bool {
        switch phase {
        case .off, .noAccess, .signedOut, .publicDemo, .reading: false
        default: true
        }
    }

    private var action: (kind: Action, title: String, disabled: Bool, note: String?)? {
        let tally = snapshot.tally
        switch snapshot.phase {
        case .off:
            return (.turnOn, String(localized: "Turn On Backup"), false,
                    String(localized: "Verso asks for all of your photos, and for notifications to say when it needs you."))
        case .noAccess:
            return (.openSettings, String(localized: "Open Settings"), false, nil)
        case .reading, .checking:
            return (.start, String(localized: "Start"), tally.checked == 0,
                    String(localized: "You can start now: photos already in Immich are never sent, and the check goes on."))
        case .waitingForStart:
            return (.start, String(localized: "Start"), tally.checked == 0, String(localized: "Nothing is uploaded until you say Start."))
        case .backingUp, .upToDate:
            return (.backUpNow, String(localized: "Back Up Now"), personRunActive, nil)
        case .stopped(.unreachable), .stopped(.full), .stopped(.notAllowed):
            return (.backUpNow, String(localized: "Try Now"), personRunActive, nil)
        case .stopped, .signedOut, .publicDemo:
            return nil
        }
    }

    struct Words {
        var symbol: String
        var tint: Color
        var headline: String
        var line: String?
        var working = false
    }

    static func words(_ snapshot: BackupSnapshot, settings: BackupSettings) -> Words {
        let tally = snapshot.tally
        let waiting = BackupStatus.waiting(snapshot, settings: settings)
        switch snapshot.phase {
        case .off:
            return Words(symbol: "icloud.and.arrow.up", tint: .accentColor, headline: String(localized: "Back Up This \(DeviceWords.model)"),
                         line: String(localized: "Send the photos and videos on this \(DeviceWords.model) to Immich, each once. Nothing goes until you have seen what is already there and said Start."))
        case .noAccess:
            return Words(symbol: "photo.badge.exclamationmark", tint: .orange, headline: String(localized: "Verso needs all of your photos"),
                         line: String(localized: "Backing up needs access to all of your photos, so that none is missed. Choose Full Access for Verso under Photos in Settings."))
        case .signedOut:
            return Words(symbol: "icloud", tint: .secondary, headline: String(localized: "Sign in to back up"))
        case .publicDemo:
            return Words(symbol: "hand.raised", tint: .secondary, headline: String(localized: "Not for Immich's demo"),
                         line: String(localized: "This is Immich's public demo server, where anyone can see what is sent, so Verso does not back up to it. Sign in to your own server to back up."))
        case .reading(let count):
            return Words(symbol: "photo.stack", tint: .accentColor, headline: String(localized: "Reading your library"),
                         line: String(localized: "\(count.formatted()) items so far"), working: true)
        case .checking:
            return Words(symbol: "icloud.and.arrow.up", tint: .accentColor, headline: String(localized: "Checking with Immich"),
                         line: waiting ?? String(localized: "\(tally.checked.formatted()) of \(tally.total.formatted()) checked"),
                         working: waiting == nil)
        case .waitingForStart:
            var line = String(localized: "\(BackupStatus.toGo(tally.toUpload, bytes: tally.toUploadBytes)) to upload")
            if let retry = BackupStatus.retry(snapshot) { line += " · " + retry }
            return Words(symbol: "icloud.and.arrow.up", tint: .accentColor, headline: String(localized: "Ready to back up"),
                         line: line)
        case .backingUp:
            if let waiting = waiting ?? BackupStatus.retry(snapshot) {
                return Words(symbol: "icloud", tint: .secondary, headline: String(localized: "Backing up"), line: waiting)
            }
            let toCheck = tally.total - tally.checked
            if snapshot.going == 0 && toCheck > 0 {
                return Words(symbol: "icloud.and.arrow.up", tint: .accentColor, headline: String(localized: "Backing up"),
                             line: toCheck == 1 ? String(localized: "1 still to check")
                                 : String(localized: "\(toCheck.formatted()) still to check"),
                             working: true)
            }
            return Words(symbol: "icloud.and.arrow.up", tint: .accentColor, headline: String(localized: "Backing up"),
                         line: snapshot.going > 0 ? String(localized: "\(BackupStatus.toGo(snapshot.going, bytes: tally.toUploadBytes)) to go") : nil,
                         working: true)
        case .upToDate:
            let line = tally.needsLook > 0 ? BackupStatus.needLook(tally.needsLook)
                : String(localized: "\(tally.alreadyInImmich.formatted()) of \(tally.total.formatted()) in Immich")
            return Words(symbol: "checkmark.icloud", tint: .green, headline: String(localized: "Backed up"), line: line)
        case .stopped(.unreachable):
            let again = snapshot.pausedUntil.map { String(localized: "at \($0.formatted(date: .omitted, time: .shortened))") }
                ?? String(localized: "soon")
            return Words(symbol: "icloud", tint: .secondary, headline: String(localized: "Waiting for Immich"),
                         line: String(localized: "Uploads failed several times in a row, so Verso waits rather than reading photo after photo for nothing. It tries again \(again), and when the connection changes."))
        case .stopped(.unauthorized):
            return Words(symbol: "exclamationmark.icloud", tint: .orange, headline: String(localized: "Sign in again"),
                         line: String(localized: "Your Immich server no longer accepts this sign-in. Sign out and in again in your account; backing up goes on from where it stopped."))
        case .stopped(.notAllowed):
            let reason = snapshot.stopReason ?? String(localized: "no reason given")
            return Words(symbol: "exclamationmark.icloud", tint: .orange, headline: String(localized: "Immich doesn't let Verso upload"),
                         line: String(localized: "Your Immich server refused: \(reason). An API key needs permission to upload as well as to read your library, and a proxy in front of Immich may refuse too. Sign in again with a key that has it, or try again once it is put right; backing up goes on from where it stopped."))
        case .stopped(.full):
            return Words(symbol: "exclamationmark.icloud", tint: .orange, headline: String(localized: "Your server is full"),
                         line: String(localized: "Backing up stopped. Verso tries again each day; free space on the server, or raise your quota."))
        case .stopped(.mostGone):
            let line = snapshot.mostGone.map { mostGone in
                String(localized: "\(mostGone.gone.formatted()) of the \(mostGone.of.formatted()) photos Verso backed up are gone from Immich at once. That looks like a problem with the server, such as another server or account, or its storage offline, rather than deletions. Nothing changes until you answer.")
            }
            return Words(symbol: "exclamationmark.icloud", tint: .orange, headline: String(localized: "Most of your backup is gone from Immich"),
                         line: line)
        }
    }
}

/// One bar for the whole library, split by what each photo is waiting for, as iPhone Storage splits the device: In Immich
/// (green), To upload (the accent), Needs a look (orange: the person's call, also photos in another form or missing from
/// Immich), Left out (on purpose: in Immich's trash, deleted in Immich, or kept off it by the person) and To check
/// (grey). The page's On This iPhone has its parts as rows, in the same colours, so the bar needs no legend.
struct BackupBar: View {
    static let inImmich = Color.green
    static let toUpload = Color.accentColor
    static let needsYou = Color.orange
    static let leftOut = Color(.systemGray)
    static let toCheck = Color(.systemGray4)

    let tally: BackupTally

    private struct Part: Identifiable {
        var id: Int
        var count: Int
        var color: Color
    }

    private var parts: [Part] {
        let needsYou = tally.needsLook + tally.anotherForm + tally.missingFromImmich
        let leftAsIs = tally.skipped + tally.deletedInImmich + tally.inImmichTrash
        return [
            Part(id: 0, count: tally.alreadyInImmich, color: Self.inImmich),
            Part(id: 1, count: tally.toUpload, color: Self.toUpload),
            Part(id: 2, count: needsYou, color: Self.needsYou),
            Part(id: 3, count: leftAsIs, color: Self.leftOut),
            Part(id: 4, count: tally.total - tally.checked, color: Self.toCheck),
        ]
    }

    var body: some View {
        GeometryReader { geometry in
            let filled = parts.filter { $0.count > 0 }
            let gaps = CGFloat(max(0, filled.count - 1)) * 2
            HStack(spacing: 2) {
                ForEach(filled) { part in
                    Rectangle()
                        .fill(part.color)
                        .frame(width: max(3, (geometry.size.width - gaps) * CGFloat(part.count) / CGFloat(max(tally.total, 1))))
                }
            }
            .frame(width: geometry.size.width, alignment: .leading)
        }
        .frame(height: 10)
        .clipShape(.capsule)
        .accessibilityHidden(true)
    }
}

/// A list of photos in one of the page's groups, each with its thumbnail from Photos, its date and its reason, and the
/// group's actions on one photo (a swipe) or all.
struct BackupPhotosPage: View {
    enum Kind {
        case toUpload, toCheck, anotherForm, needsLook, missing, trash, deleted, skipped

        var title: String {
            switch self {
            case .toUpload: "To Upload"
            case .toCheck: "To Check"
            case .anotherForm: "In Immich in Another Form"
            case .needsLook: "Needs a Look"
            case .missing: "Missing from Immich"
            case .trash: "In Immich's Trash"
            case .deleted: "Deleted in Immich"
            case .skipped: "You Chose Not to Send"
            }
        }

        var states: [BackupPhotoState] {
            switch self {
            case .toUpload: [.toUpload]
            case .toCheck: [.unchecked]
            case .anotherForm: [.anotherForm]
            case .needsLook: [.needsLook]
            case .missing: [.missingFromImmich]
            case .trash: [.inImmichTrash]
            case .deleted: [.deletedInImmich]
            case .skipped: [.skipped]
            }
        }

        var explanation: String {
            switch self {
            case .toCheck: "Not checked with Immich yet. Each says what it waits for, and Verso goes on with it by itself. Don't Send keeps one on this \(DeviceWords.model) alone."
            case .toUpload: "What goes once you say Start, or next while backing up runs. Don't Send keeps a photo on this \(DeviceWords.model) alone, as after one you deleted in Immich long ago and kept here; it waits under You Chose Not to Send, where you can still send it."
            case .anotherForm: "Immich has a photo taken at the same second under the same name, with other bytes. Send one to upload it as well, or skip it."
            case .needsLook: "Verso tried these by itself for a while and needs you: each says why. Retry tries again now; Don't Send leaves it on the phone alone, which you can change under You Chose Not to Send."
            case .missing: "Verso backed these up and they are gone from Immich without being deleted there, as after a server restored from an older backup."
            case .trash: "Deleted in Immich, and still in its trash for up to 30 days. Restore one in Immich to have it back; Verso doesn't upload them again, which would undo the deletion."
            case .deleted: "These were deleted in Immich. Verso never sends them again on its own."
            case .skipped: "You chose not to send these. Send one to upload it."
            }
        }
    }

    let services: AccountServices
    let kind: Kind
    @State private var identifiers: [String] = []
    @State private var loaded = false
    /// Select chooses several photos for one action, in the bar at the foot.
    @State private var selection = Set<String>()
    @State private var editMode: EditMode = .inactive

    private var center: BackupCenter { BackupCenter.shared }

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(identifiers, id: \.self) { identifier in
                    BackupPhotoRowView(services: services, identifier: identifier, kind: kind)
                        .swipeActions(edge: .trailing) { actions(for: [identifier]) }
                        .contextMenu { actions(for: [identifier]) }
                }
            } footer: {
                Text(kind.explanation)
            }
        }
        .overlay {
            if loaded && identifiers.isEmpty {
                ContentUnavailableView("None", systemImage: "checkmark.circle")
            }
        }
        .environment(\.editMode, $editMode)
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !identifiers.isEmpty && kind != .trash {
                ToolbarItem(placement: .primaryAction) {
                    Button(editMode.isEditing ? "Done" : "Select") {
                        editMode = editMode.isEditing ? .inactive : .active
                        selection = []
                    }
                }
                if !editMode.isEditing {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            actions(for: identifiers, all: true)
                        } label: {
                            Label("All", systemImage: "ellipsis")
                        }
                    }
                } else if !selection.isEmpty {
                    ToolbarItemGroup(placement: .bottomBar) {
                        actions(for: Array(selection))
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
        }
        .task(id: center.snapshot.tally) { await load() }
    }

    private func load() async {
        identifiers = await center.identifiers(in: kind.states, limit: 500)
        // Those an action moved to another group leave the selection with the list.
        selection.formIntersection(identifiers)
        loaded = true
    }

    @ViewBuilder
    private func actions(for chosen: [String], all: Bool = false) -> some View {
        switch kind {
        case .toUpload, .toCheck:
            Button(all ? "Don't Send Any" : "Don't Send", systemImage: "xmark.circle") { center.decide(chosen, .skip) }
        case .anotherForm, .skipped:
            Button(all ? "Send All" : "Send", systemImage: "arrow.up.circle") { center.decide(chosen, .send) }
            if kind == .anotherForm {
                Button(all ? "Skip All" : "Skip", systemImage: "xmark.circle") { center.decide(chosen, .skip) }
            }
        case .needsLook:
            Button(all ? "Retry All" : "Retry", systemImage: "arrow.clockwise") { center.retry(chosen) }
            Button(all ? "Don't Send Any" : "Don't Send", systemImage: "xmark.circle") { center.decide(chosen, .skip) }
        case .missing:
            Button(all ? "Send All Again" : "Send Again", systemImage: "arrow.up.circle") { center.decide(chosen, .sendAgain) }
            Button(all ? "Let All Go" : "Let Go", systemImage: "trash", role: .destructive) { center.decide(chosen, .letGo) }
        case .deleted:
            Button(all ? "Send All Again" : "Send Again", systemImage: "arrow.up.circle") { center.decide(chosen, .sendAgain) }
        case .trash:
            // Uploading a photo in Immich's trash would only meet it there: it comes back by a restore in Immich.
            EmptyView()
        }
    }
}

/// One photo in a list: its thumbnail from Photos, when it was taken, and why it is there; for one in another form, the
/// one Immich has beside it. A hidden photo shows a lock in place of its picture.
private struct BackupPhotoRowView: View {
    let services: AccountServices
    let identifier: String
    let kind: BackupPhotosPage.Kind
    @State private var hidden = false
    @State private var thumbnail: UIImage?
    @State private var immichThumbnail: CGImage?
    @State private var taken: Date?
    @State private var reason: String?

    var body: some View {
        HStack(spacing: 12) {
            picture(thumbnail.map { Image(uiImage: $0) })
            if kind == .anotherForm {
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                picture(immichThumbnail.map { Image(decorative: $0, scale: 1) })
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(taken?.formatted(date: .abbreviated, time: .shortened) ?? "No date")
                if let reason {
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if kind == .anotherForm {
                    Text("On this \(DeviceWords.model), and in Immich")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: identifier) { await load() }
    }

    private func picture(_ image: Image?) -> some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image { image.resizable().scaledToFill() }
            if hidden {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Hidden")
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(.rect(cornerRadius: 6))
    }

    private func load() async {
        let center = BackupCenter.shared
        switch kind {
        case .needsLook: reason = await center.reason(identifier)
        case .toCheck, .toUpload: reason = await center.waitingReason(identifier)
        default: reason = nil
        }
        guard let asset = BackupLibrary.asset(identifier) else { return }
        taken = asset.creationDate
        hidden = asset.isHidden
        guard !hidden else { return }
        thumbnail = await Self.thumbnail(asset)
        if kind == .anotherForm, let assetID = await center.anotherFormAsset(identifier) {
            immichThumbnail = await services.pipeline.thumbnail(assetID, size: .thumbnail)
        }
    }

    private static func thumbnail(_ asset: PHAsset) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 168, height: 168), contentMode: .aspectFill,
                                                  options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}
