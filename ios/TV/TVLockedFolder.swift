import DeviceDiscoveryUI
import Network
import SwiftUI
import UIKit

// The Locked Folder on the Apple TV (ROADMAP.md, "Verso on the Apple TV"), in Collections once Settings shows it. The
// TV's own key never opens it: Immich opens the folder only to a session unlocked with the PIN. So each visit asks the
// iPhone (Unlock with iPhone, DeviceDiscoveryUI's picker, as Set Up with iPhone): Verso there asks the person, with
// Face ID or the PIN, makes this TV a session of its own for an hour at most, unlocks it with the PIN and sends its
// token alone, never the PIN (AppleTVSetup on the iPhone). The TV keeps the token in memory, shows the folder through
// a connection without a URL cache and pictures in memory alone, never in the Top Shelf, and ends the session as it
// leaves the folder, leaves the front, signs out, or the server's unlock runs out; the next visit asks the iPhone again.

/// Settings' switch for the Locked Folder in Collections, off until turned on.
enum TVLockedFolderSetting {
    static let key = "lockedFolder.shown"
}

/// The Locked Folder while it is open on this TV: a model of its own, which the folder's grid and viewer read in place
/// of the TV's, with the session's token and the pictures read through it.
@MainActor
final class TVLockedFolderVisit {
    let model: TVModel
    private let client: ImmichClient
    private var expiryCheck: Task<Void, Never>?
    /// A check is under way: the 401 its own request may meet asks for another (TVModel.unauthorizedSeen).
    private var verifying = false
    /// Told when the server no longer has the session unlocked, with the reason to show.
    var onExpired: (String) -> Void = { _ in }

    init(server: URL, apiURL: URL, token: String, owner: TVModel) {
        client = ImmichClient(serverURL: server, apiURL: apiURL, credential: .accessToken(token)).explorePrivateClient()
        model = TVModel(lockedFolder: client, images: ImagePipeline(client: client), owner: owner)
    }

    /// The session's unlock as the server has it: elevated, and until when.
    func status() async throws -> ExploreAuthStatus { try await client.exploreAuth() }

    /// The session's user, to compare with the TV's own.
    func user() async throws -> User { try await client.currentUser() }

    /// Asked again a minute on, or just after the unlock would expire if sooner (the server extends it while it is
    /// used), so Lock on the iPhone, which ends the session, reaches a TV showing one photo within the minute.
    func scheduleCheck(_ expiry: String?) {
        expiryCheck?.cancel()
        let date = min(expiry.flatMap(ImmichDate.parse) ?? .distantFuture, Date().addingTimeInterval(60))
        expiryCheck = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow) + 2)) } catch { return }
            await self?.verify()
        }
    }

    /// Keeps the folder open while the server has the session unlocked; else it locks, saying why.
    func verify() async {
        guard !verifying else { return }
        verifying = true
        defer { verifying = false }
        do {
            let status = try await status()
            if status.isElevated { scheduleCheck(status.pinExpiresAt) }
            else { onExpired(String(localized: "The Locked Folder locked again. Unlock it with your iPhone to go on.")) }
        } catch is CancellationError {
        } catch {
            onExpired(String(localized: "The Locked Folder locked again. Unlock it with your iPhone to go on."))
        }
    }

    /// Ends the session on the server (Immich's logout), drops the pictures and closes the connection.
    func end() {
        expiryCheck?.cancel()
        onExpired = { _ in }
        model.images?.removeAll()
        let client = client
        Task {
            try? await client.endOwnSession()
            ImmichClient.close(client.session)
        }
    }
}

struct TVLockedFolder: View {
    @Environment(TVModel.self) private var tv
    @State private var connection: NWConnection?
    @State private var waiting = false

    var body: some View {
        Group {
            if let visit = tv.lockedFolder {
                TVTimeline(query: TimelineQuery(visibility: "locked"), title: String(localized: "Locked Folder"))
                    .environment(visit.model)
            } else {
                locked
            }
        }
        .task { await followLaunchArguments() }
    }

    /// A development build opens the folder with a session's token (`-tvLockedFolderToken`), as the iPhone would send
    /// it, for a check of the folder and of its session ending without the iPhone and its picker.
    private func followLaunchArguments() async {
        #if DEBUG
        guard tv.lockedFolder == nil, let token = UserDefaults.standard.string(forKey: "tvLockedFolderToken") else { return }
        await tv.openLockedFolder(token: token)
        #endif
    }

    private var locked: some View {
        VStack(spacing: 32) {
            Image(systemName: "lock.fill").font(.system(size: 80)).foregroundStyle(.secondary)
            Text("Locked Folder").font(.title2)
            Text("Open it with your iPhone: Verso there asks for Face ID or your PIN. It locks again as you leave it.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 1100)
            DevicePicker(.applicationService(name: "verso-tv-setup")) { endpoint in
                ask(endpoint)
            } label: {
                Label("Unlock with iPhone", systemImage: "iphone")
            } fallback: {
                Text("This Apple TV cannot look for iPhones.")
            } parameters: {
                .applicationService
            }
            .disabled(waiting)
            if waiting {
                ProgressView("Waiting for your iPhone")
            } else if let reason = tv.lockedFolderReason {
                Text(reason).foregroundStyle(.orange).multilineTextAlignment(.center).frame(maxWidth: 1100)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Asks the chosen iPhone for the Locked Folder, saying this TV's name and server, and opens it with the token the
    /// iPhone sends.
    private func ask(_ endpoint: NWEndpoint) {
        guard let server = tv.client?.serverURL else { return }
        let connection = NWConnection(to: endpoint, using: .applicationService)
        self.connection = connection
        tv.lockedFolderReason = nil
        waiting = true
        connection.start(queue: .main)
        let hello = ["name": UIDevice.current.name, "purpose": "lockedFolder", "server": server.absoluteString]
        connection.send(content: (try? JSONEncoder().encode(hello)) ?? Data(), completion: .contentProcessed { _ in })
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, error in
            Task { @MainActor in
                defer { connection.cancel(); waiting = false }
                let fields = data.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
                if fields?["refused"] != nil {
                    tv.lockedFolderReason = fields?["reason"] ?? String(localized: "The iPhone did not open it.")
                    return
                }
                guard let token = fields?["token"] else {
                    tv.lockedFolderReason = String(localized: "The iPhone did not open it\(error.map { ": \($0.localizedDescription)" } ?? ".")")
                    return
                }
                await tv.openLockedFolder(token: token)
            }
        }
    }
}
