import Network
import SwiftUI

/// Set Up Apple TV (ROADMAP.md, "Verso on the Apple TV"): while Verso is open and signed in, the iPhone can be found by
/// Verso on an Apple TV nearby, through Apple's DeviceDiscoveryUI, and a tap on the notification iOS shows for the TV's
/// request opens Verso, already listening (AppleTVSetup.shared, which the window starts). The TV that connects says its
/// name, and Verso opens this page wherever it was and asks here whether
/// to set it up: only on Allow does the iPhone make the TV a key of its own, allowed to read only, named after the TV,
/// and send it with the server's address. The person never sees the key. The TVs set up are listed by their names, each
/// with Forget, which deletes its key and so signs it out, and Forget All where there are several; each asks first.
///
/// A TV with the Locked Folder on in its Settings asks the same way each time it opens the folder: here the person
/// allows it, with Face ID where the PIN is kept behind it (LockedFolderFaceID) or with the PIN typed, and the iPhone
/// makes the TV a session of its own for an hour, unlocks it with the PIN, and sends the session's token alone; the TV
/// never learns the PIN, and ends the session as it leaves the folder. The TVs with the folder open are listed, each
/// with Lock, which ends its session.
struct AccountAppleTVPage: View {
    let services: AccountServices
    private let setup = AppleTVSetup.shared
    @State private var forgetting: AppleTVSetup.TV?
    @State private var forgettingAll = false
    @State private var pin = ""

    var body: some View {
        Form {
            Section {
                Label("On the Apple TV, open Verso and choose Set Up with iPhone, then this iPhone.", systemImage: "appletv")
                switch setup.state {
                case .waiting:
                    Label("Waiting for the Apple TV…", systemImage: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.secondary)
                case .done:
                    Label("The Apple TV is set up.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed(let reason):
                    Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            } footer: {
                Text("The Apple TV gets a key of its own that may only view your library: never change, delete or share it. The Locked Folder opens there only from this iPhone, each time.")
            }
            Section {
                if !setup.listed {
                    ProgressView()
                } else if setup.tvs.isEmpty {
                    Text("None yet").foregroundStyle(.secondary)
                }
                ForEach(setup.tvs) { tv in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: tv.name)
                            if let since = tv.since {
                                Text("Set up \(since.formatted(date: .long, time: .omitted))")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if setup.removing.contains(tv.id) {
                            ProgressView()
                        } else {
                            Button("Forget", role: .destructive) { forgetting = tv }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                if setup.tvs.count > 1 {
                    Button("Forget All", role: .destructive) { forgettingAll = true }
                }
                if let error = setup.error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            } header: {
                Text("Set Up")
            } footer: {
                Text("Forgetting an Apple TV signs it out: its key is deleted in Immich. It can be set up again.")
            }
            if !setup.openFolders.isEmpty {
                Section {
                    ForEach(setup.openFolders) { tv in
                        HStack {
                            Text(verbatim: tv.name)
                            Spacer()
                            if setup.removing.contains(tv.id) {
                                ProgressView()
                            } else {
                                Button("Lock") { Task { await setup.lock(tv, client: services.client) } }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                } header: {
                    Text("Locked Folder Open")
                } footer: {
                    Text("Each locks as the Apple TV leaves the Locked Folder, and within the hour by itself. Lock reaches the Apple TV within a minute.")
                }
            }
        }
        .animation(.default, value: setup.tvs.map(\.id))
        .navigationTitle("Apple TV")
        .confirmationDialog(forgetting.map { String(localized: "Forget \u{201C}\($0.name)\u{201D}?") } ?? "",
                            isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
                            titleVisibility: .visible, presenting: forgetting) { tv in
            Button("Forget", role: .destructive) { Task { await setup.forget([tv], client: services.client) } }
        } message: { _ in
            Text("It is signed out, and can be set up again.")
        }
        .confirmationDialog("Forget all Apple TVs?", isPresented: $forgettingAll, titleVisibility: .visible) {
            Button("Forget All", role: .destructive) { Task { await setup.forget(setup.tvs, client: services.client) } }
        } message: {
            Text("Each is signed out, and can be set up again.")
        }
        .refreshable { await setup.list(client: services.client) }
        .alert(setup.askingLockedFolder.map { String(localized: "Show the Locked Folder on \u{201C}\($0)\u{201D}?") } ?? "",
               isPresented: Binding(get: { setup.askingLockedFolder != nil },
                                    set: { if !$0 { setup.answerLockedFolder(false, typed: nil); pin = "" } })) {
            if !setup.lockedFolderKept {
                SecureField("Locked Folder PIN", text: $pin)
                    .keyboardType(.numberPad)
            }
            Button("Allow") {
                let typed = setup.lockedFolderKept ? nil : pin
                pin = ""
                setup.answerLockedFolder(true, typed: typed)
            }
            Button("Don't Allow", role: .cancel) { pin = ""; setup.answerLockedFolder(false, typed: nil) }
        } message: {
            Text(setup.lockedFolderKept
                 ? "Face ID unlocks it there for this visit. It locks as the Apple TV leaves it."
                 : "Your PIN unlocks it there for this visit, and the Apple TV never learns it. It locks as the Apple TV leaves it.")
        }
        .alert(setup.asking.map { String(localized: "Set Up \u{201C}\($0)\u{201D}?") } ?? "", isPresented: Binding(
            get: { setup.asking != nil }, set: { if !$0 { setup.answer(false) } })) {
            Button("Allow") { setup.answer(true) }
            Button("Don't Allow", role: .cancel) { setup.answer(false) }
        } message: {
            Text("This Apple TV gets a key of its own that may only view your library.")
        }
        .onAppear {
            setup.pagesOnScreen += 1
            setup.start(services: services)
        }
        .onDisappear { setup.pagesOnScreen -= 1 }
        .task { await setup.list(client: services.client) }
    }
}

/// The iPhone's side of setting up an Apple TV: an application service the TV finds, and one key per TV.
@MainActor @Observable
final class AppleTVSetup {
    enum State: Equatable { case waiting, done, failed(String) }

    /// An Apple TV set up from this account: its key in Immich, named after it.
    struct TV: Identifiable, Equatable {
        let id: String
        let name: String
        let since: Date?
    }

    /// The service the TV browses for (both Info.plists' `NSApplicationServices`).
    nonisolated static let service = "verso-tv-setup"
    /// The name of the TVs' keys in Immich, by which the page lists them.
    nonisolated static let keyName = "Verso on Apple TV"
    /// What a TV's key may do: view, nothing else (Immich's permissions).
    nonisolated static let permissions = ["asset.read", "asset.view", "asset.download", "album.read", "person.read",
                                          "memory.read", "map.read", "partner.read", "tag.read", "stack.read",
                                          "user.read", "userPreference.read", "server.about"]

    /// How long a session made for a TV's Locked Folder lasts at most; the TV ends it sooner, as it leaves the folder.
    nonisolated static let lockedFolderDuration = 60 * 60

    private(set) var state = State.waiting
    /// The TVs set up, by their keys, once read.
    private(set) var tvs: [TV] = []
    /// The TVs with the Locked Folder open, by the sessions made for them.
    private(set) var openFolders: [TV] = []
    private(set) var listed = false
    /// The TVs whose keys are being deleted.
    private(set) var removing: Set<String> = []
    /// What went wrong reading or forgetting them.
    private(set) var error: String?
    /// The TV waiting for the person's answer, by the name it gave.
    private(set) var asking: String?
    /// The TV asking to show the Locked Folder, by the name it gave.
    private(set) var askingLockedFolder: String?
    /// The PIN is kept behind Face ID for the account, so allowing the TV's Locked Folder asks for Face ID, not the PIN.
    private(set) var lockedFolderKept = false
    private var listener: NWListener?
    private var waiting: (connection: NWConnection, name: String, client: ImmichClient)?
    /// The signed-in account's client, which a TV's key is made through.
    private var client: ImmichClient?
    /// The account the Locked Folder's PIN is kept for behind Face ID.
    private var lockedFolderKey: String?

    /// The app's one listener, which the window starts while signed in and starts again as the app comes back to the
    /// front, as iOS stops a listener in the background: a tap on the notification for a TV's request must find it.
    static let shared = AppleTVSetup()
    /// The Apple TV page opens over the window in front when a TV asks while no Apple TV page is on screen.
    var pageShown = false
    @ObservationIgnored private(set) weak var pageWindow: AnyObject?
    /// The window in front, which the app tells (VersoApp), as this knows no UIKit.
    @ObservationIgnored var frontWindow: () -> AnyObject? = { nil }
    /// How many Apple TV pages are on screen: the account sheet's, or the one a TV's request opened.
    @ObservationIgnored var pagesOnScreen = 0

    func start(services: AccountServices) {
        client = services.client
        lockedFolderKey = LockedFolderFaceID.key(services)
        guard listener == nil else { return }
        do {
            let listener = try NWListener(service: NWListener.Service(applicationService: Self.service), using: .applicationService)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.serve(connection) }
            }
            // Gone in the background, or failed: the next start makes another.
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                switch state {
                case .failed, .cancelled:
                    Task { @MainActor in if let self, self.listener === listener { self.listener = nil } }
                default: break
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            state = .failed(String(localized: "The Apple TV cannot find this iPhone: \(error.localizedDescription)"))
        }
    }

    /// Signed out: no TV can be set up until signed in again.
    func stop() {
        listener?.cancel()
        listener = nil
        client = nil
        lockedFolderKey = nil
    }

    /// A TV connected: it says its name first, and what it asks for (`purpose`: to be set up, or `lockedFolder`, with
    /// the server it is signed in to), and the person is asked about it by that name, on the Apple TV page, which opens
    /// in front where none is on screen. A second TV while one waits is turned away, and so is any on Immich's demo,
    /// where Verso makes no keys, as it is everyone's. The Locked Folder is turned down, with the reason, for a TV of
    /// another server and for an iPhone signed in with an API key, which cannot unlock a session.
    private func serve(_ connection: NWConnection) {
        guard waiting == nil, let client else { return connection.cancel() }
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            Task { @MainActor in
                guard let self else { return connection.cancel() }
                let fields = data.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
                let name = fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Apple TV")
                if self.pagesOnScreen == 0 {
                    self.pageWindow = self.frontWindow()
                    self.pageShown = true
                }
                if BackupCenter.isPublicDemo(client.serverURL) {
                    self.send(["refused": "true"], over: connection)
                    self.state = .failed(String(localized: "Immich's demo server is everyone's, so Verso sets up no Apple TV on it. Sign in to your own server to set one up."))
                    return
                }
                self.waiting = (connection, name, client)
                guard fields["purpose"] == "lockedFolder" else {
                    self.asking = name
                    return
                }
                if !client.exploreSupportsLockedFolder {
                    self.refuse(String(localized: "Sign in on this iPhone with email and password, or with single sign-on, to open the Locked Folder on the Apple TV."))
                } else if fields["server"].flatMap(URL.init(string:)).map(Self.sameServer(client.serverURL)) != true {
                    self.refuse(String(localized: "This iPhone is signed in to another server than the Apple TV."))
                } else {
                    self.lockedFolderKept = LockedFolderFaceID.canUnlock(self.lockedFolderKey)
                    self.askingLockedFolder = name
                }
            }
        }
    }

    /// The person's answer: Allow makes the key and sends it; Don't Allow tells the TV and closes.
    func answer(_ allowed: Bool) {
        guard let (connection, name, client) = waiting else { return }
        waiting = nil
        asking = nil
        guard allowed else {
            send(["refused": "true"], over: connection)
            return
        }
        Task {
            do {
                let key = try await client.createAccountKey(name: "\(Self.keyName) (\(name))", permissions: Self.permissions)
                send(["server": client.serverURL.absoluteString, "key": key.secret], over: connection)
                state = .done
                await list(client: client)
            } catch {
                connection.cancel()
                state = .failed(String(localized: "The Apple TV's key could not be made: \(error.localizedDescription)"))
            }
        }
    }

    /// The Locked Folder for the TV waiting: Face ID gives the kept PIN, or the PIN is typed; the iPhone makes the TV a
    /// session of its own, unlocks it with the PIN through the TV's token, and sends that token alone. A PIN typed and
    /// taken is kept behind Face ID, as the Locked Folder keeps it here.
    func answerLockedFolder(_ allowed: Bool, typed: String?) {
        guard let (connection, name, client) = waiting, askingLockedFolder != nil else { return }
        askingLockedFolder = nil
        guard allowed else { return refuse(nil) }
        waiting = nil
        let key = lockedFolderKey, epoch = LockedFolderFaceID.epoch
        Task {
            var code = typed.flatMap { $0.isEmpty ? nil : $0 }
            // The one face this asks for: the PIN gives the TV access. Taking it away again asks for none.
            if code == nil, let key,
               case .pin(let kept) = await LockedFolderFaceID.pin(for: key, reason: String(localized: "Show the Locked Folder on \u{201C}\(name)\u{201D}")) {
                code = kept
            }
            guard let code else {
                send(["refused": "true"], over: connection)
                state = .failed(String(localized: "The Locked Folder was not opened on \u{201C}\(name)\u{201D}: Face ID or the PIN is needed each time."))
                return
            }
            do {
                let device = try await client.createAccountDevice(type: "\(Self.keyName) (\(name))", os: "tvOS",
                                                                  duration: Self.lockedFolderDuration)
                let tv = ImmichClient(serverURL: client.serverURL, apiURL: client.apiURL, credential: .accessToken(device.token))
                do {
                    try await tv.exploreUnlock(code, setup: false)
                } catch {
                    try? await tv.endOwnSession()
                    if LockedFolderFaceID.rejectsPIN(error), typed == nil, let key { LockedFolderFaceID.forget(key) }
                    throw error
                }
                if typed != nil, let key { try? LockedFolderFaceID.save(code, for: key, since: epoch) }
                send(["token": device.token], over: connection)
                state = .waiting
                await list(client: client)
            } catch {
                send(["refused": "true"], over: connection)
                state = .failed(String(localized: "The Locked Folder could not be opened on \u{201C}\(name)\u{201D}: \(error.localizedDescription)"))
            }
        }
    }

    /// Turns the waiting TV down, telling it why where there is a reason, which the page says too.
    private func refuse(_ reason: String?) {
        guard let (connection, _, _) = waiting else { return }
        waiting = nil
        var fields = ["refused": "true"]
        if let reason {
            fields["reason"] = reason
            state = .failed(reason)
        }
        send(fields, over: connection)
    }

    /// The same server, however its address ends.
    nonisolated private static func sameServer(_ ours: URL) -> (URL) -> Bool {
        { theirs in
            let trimmed = { (url: URL) in url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() }
            return trimmed(ours) == trimmed(theirs)
        }
    }

    /// Ends a TV's Locked Folder session; the TV shows the folder locked at its next request.
    func lock(_ tv: TV, client: ImmichClient) async {
        error = nil
        removing.insert(tv.id)
        do {
            try await client.deleteAccountDevice(tv.id)
            openFolders.removeAll { $0.id == tv.id }
        } catch ImmichError.http(let status, _) where status == 400 || status == 404 {
            // Ended already, by the TV leaving the folder or by the server at the hour: Immich answers 400 for it.
            openFolders.removeAll { $0.id == tv.id }
        } catch {
            self.error = String(localized: "The Locked Folder on \u{201C}\(tv.name)\u{201D} could not be locked: \(error.localizedDescription)")
        }
        removing.remove(tv.id)
    }

    private func send(_ fields: [String: String], over connection: NWConnection) {
        guard let payload = try? JSONEncoder().encode(fields) else { return connection.cancel() }
        connection.send(content: payload, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    /// The TVs' keys, by the name they were made with, the newest first.
    func list(client: ImmichClient) async {
        do {
            let keys = try await client.accountKeys()
            tvs = keys.compactMap { key in
                let name: String
                if key.name == Self.keyName {
                    name = String(localized: "Apple TV")
                } else if key.name.hasPrefix(Self.keyName + " ("), key.name.hasSuffix(")") {
                    name = String(key.name.dropFirst(Self.keyName.count + 2).dropLast())
                } else {
                    return nil
                }
                return TV(id: key.id, name: name, since: key.createdAt.flatMap(ImmichDate.parse))
            }
            .sorted { ($0.since ?? .distantPast) > ($1.since ?? .distantPast) }
            error = nil
        } catch {
            self.error = String(localized: "The Apple TVs could not be read: \(error.localizedDescription)")
        }
        listed = true
        // The sessions made for the TVs' Locked Folder, still open; an API key's sign-in may not list sessions.
        let devices = (try? await client.accountDevices()) ?? []
        openFolders = devices.compactMap { device in
            guard device.deviceType.hasPrefix(Self.keyName + " ("), device.deviceType.hasSuffix(")") else { return nil }
            return TV(id: device.id, name: String(device.deviceType.dropFirst(Self.keyName.count + 2).dropLast()),
                      since: ImmichDate.parse(device.updatedAt))
        }
    }

    /// Deletes the TVs' keys, which signs them out; each row goes once its key is gone.
    func forget(_ chosen: [TV], client: ImmichClient) async {
        error = nil
        removing.formUnion(chosen.map(\.id))
        for tv in chosen {
            do {
                try await client.deleteAccountKey(tv.id)
                tvs.removeAll { $0.id == tv.id }
            } catch {
                self.error = String(localized: "\u{201C}\(tv.name)\u{201D} could not be forgotten: \(error.localizedDescription)")
            }
            removing.remove(tv.id)
        }
        state = .waiting
    }
}
