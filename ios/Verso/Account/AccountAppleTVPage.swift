import Network
import SwiftUI

/// Set Up Apple TV (ROADMAP.md, "Verso on the Apple TV"): while this page is open, the iPhone can be found by Verso on an
/// Apple TV nearby, through Apple's DeviceDiscoveryUI. The TV that connects says its name, and Verso asks here whether
/// to set it up: only on Allow does the iPhone make the TV a key of its own, allowed to read only, named after the TV,
/// and send it with the server's address. The person never sees the key; Forget Apple TVs deletes them all.
struct AccountAppleTVPage: View {
    let services: AccountServices
    @State private var setup = AppleTVSetup()

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
                Button("Forget Apple TVs", role: .destructive) { Task { await setup.forget(client: services.client) } }
            } footer: {
                Text("Signs out every Apple TV this account has set up. Each can be set up again.")
            }
        }
        .navigationTitle("Apple TV")
        .alert(setup.asking.map { String(localized: "Set Up \u{201C}\($0)\u{201D}?") } ?? "", isPresented: Binding(
            get: { setup.asking != nil }, set: { if !$0 { setup.answer(false) } })) {
            Button("Allow") { setup.answer(true) }
            Button("Don't Allow", role: .cancel) { setup.answer(false) }
        } message: {
            Text("This Apple TV gets a key of its own that may only view your library.")
        }
        .onAppear { setup.start(client: services.client) }
        .onDisappear { setup.stop() }
    }
}

/// The iPhone's side of setting up an Apple TV: an application service the TV finds, and one key per TV.
@MainActor @Observable
final class AppleTVSetup {
    enum State: Equatable { case waiting, done, failed(String) }

    /// The service the TV browses for (both Info.plists' `NSApplicationServices`).
    nonisolated static let service = "verso-tv-setup"
    /// The name of the TVs' keys in Immich, which Forget Apple TVs looks for.
    nonisolated static let keyName = "Verso on Apple TV"
    /// What a TV's key may do: view, nothing else (Immich's permissions).
    nonisolated static let permissions = ["asset.read", "asset.view", "asset.download", "album.read", "person.read",
                                          "memory.read", "map.read", "partner.read", "tag.read", "stack.read",
                                          "user.read", "server.about"]

    private(set) var state = State.waiting
    /// The TV waiting for the person's answer, by the name it gave.
    private(set) var asking: String?
    private var listener: NWListener?
    private var waiting: (connection: NWConnection, name: String, client: ImmichClient)?

    func start(client: ImmichClient) {
        guard listener == nil else { return }
        do {
            let listener = try NWListener(service: NWListener.Service(applicationService: Self.service), using: .applicationService)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.serve(connection, client: client) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            state = .failed(String(localized: "The Apple TV cannot find this iPhone: \(error.localizedDescription)"))
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    /// A TV connected: it says its name first, and the person is asked about it by that name. A second TV while one
    /// waits is turned away.
    private func serve(_ connection: NWConnection, client: ImmichClient) {
        guard waiting == nil else { return connection.cancel() }
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            Task { @MainActor in
                guard let self else { return connection.cancel() }
                let fields = data.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
                let name = fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Apple TV")
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

    func forget(client: ImmichClient) async {
        guard let keys = try? await client.accountKeys() else { return }
        for key in keys where key.name == Self.keyName || key.name.hasPrefix(Self.keyName + " (") {
            try? await client.deleteAccountKey(key.id)
        }
        state = .waiting
    }
}
