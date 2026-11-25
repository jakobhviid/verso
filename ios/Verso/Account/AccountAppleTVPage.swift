import Network
import SwiftUI

/// Set Up Apple TV (ROADMAP.md, "Verso on the Apple TV"): while this page is open, the iPhone can be found by Verso on an
/// Apple TV nearby, through Apple's DeviceDiscoveryUI. When the TV connects (the person approves it in the system's
/// own prompt), the iPhone makes the TV a key of its own, allowed to read only, and sends it with the server's
/// address. The person never sees the key; Forget Apple TVs deletes them all.
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
    private var listener: NWListener?

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

    private func serve(_ connection: NWConnection, client: ImmichClient) {
        connection.start(queue: .main)
        Task {
            do {
                let key = try await client.createAccountKey(name: Self.keyName, permissions: Self.permissions)
                let payload = try JSONEncoder().encode(["server": client.serverURL.absoluteString, "key": key.secret])
                connection.send(content: payload, contentContext: .finalMessage, isComplete: true,
                                completion: .contentProcessed { _ in connection.cancel() })
                state = .done
            } catch {
                connection.cancel()
                state = .failed(String(localized: "The Apple TV's key could not be made: \(error.localizedDescription)"))
            }
        }
    }

    func forget(client: ImmichClient) async {
        guard let keys = try? await client.accountKeys() else { return }
        for key in keys where key.name == Self.keyName {
            try? await client.deleteAccountKey(key.id)
        }
        state = .waiting
    }
}
