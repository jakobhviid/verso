import Network
import SwiftUI

/// Set Up Apple TV (ROADMAP.md, "Verso on the Apple TV"): while Verso is open and signed in, the iPhone can be found by
/// Verso on an Apple TV nearby, through Apple's DeviceDiscoveryUI, and a tap on the notification iOS shows for the TV's
/// request opens Verso, already listening (AppleTVSetup.shared, which the window starts). The TV that connects says its
/// name, and Verso opens this page wherever it was and asks here whether
/// to set it up: only on Allow does the iPhone make the TV a key of its own, allowed to read only, named after the TV,
/// and send it with the server's address. The person never sees the key. The TVs set up are listed by their names, each
/// with Forget, which deletes its key and so signs it out, and Forget All where there are several; each asks first.
struct AccountAppleTVPage: View {
    let services: AccountServices
    private let setup = AppleTVSetup.shared
    @State private var forgetting: AppleTVSetup.TV?
    @State private var forgettingAll = false

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
                Text("The Apple TV gets a key of its own that may only view your library: never change, delete or share it, and never open the Locked Folder.")
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
        .alert(setup.asking.map { String(localized: "Set Up \u{201C}\($0)\u{201D}?") } ?? "", isPresented: Binding(
            get: { setup.asking != nil }, set: { if !$0 { setup.answer(false) } })) {
            Button("Allow") { setup.answer(true) }
            Button("Don't Allow", role: .cancel) { setup.answer(false) }
        } message: {
            Text("This Apple TV gets a key of its own that may only view your library.")
        }
        .onAppear {
            setup.pagesOnScreen += 1
            setup.start(client: services.client)
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

    private(set) var state = State.waiting
    /// The TVs set up, by their keys, once read.
    private(set) var tvs: [TV] = []
    private(set) var listed = false
    /// The TVs whose keys are being deleted.
    private(set) var removing: Set<String> = []
    /// What went wrong reading or forgetting them.
    private(set) var error: String?
    /// The TV waiting for the person's answer, by the name it gave.
    private(set) var asking: String?
    private var listener: NWListener?
    private var waiting: (connection: NWConnection, name: String, client: ImmichClient)?
    /// The signed-in account's client, which a TV's key is made through.
    private var client: ImmichClient?

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

    func start(client: ImmichClient) {
        self.client = client
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
    }

    /// A TV connected: it says its name first, and the person is asked about it by that name, on the Apple TV page,
    /// which opens in front where none is on screen. A second TV while one waits is turned away, and so is any on
    /// Immich's demo, where Verso makes no keys, as it is everyone's.
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
                self.asking = name
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
