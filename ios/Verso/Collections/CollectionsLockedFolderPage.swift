// The Locked Folder on iOS, opened from Utilities in Collections: unlocked with Immich's PIN, and from then on, while
// Verso runs, with Face ID or the device's passcode (ROADMAP.md, M10: "The Locked Folder behind Face ID, with Immich's
// PIN once per session"). As on the Mac (ExploreLockedView), its photos show in a session of their own whose media
// skips the disk cache, and it locks on leaving the page, on Lock, when Verso goes to the background, on signing out,
// and when the server's unlock expires; locking discards that session with its media and files. Face ID is offered
// once the app's Info.plist says why it asks (NSFaceIDUsageDescription); until then the PIN unlocks it each time.

import LocalAuthentication
import SwiftUI

struct CollectionsLockedFolderPage: View {
    let session: LibrarySession
    @Environment(\.scenePhase) private var scenePhase
    /// False once the page is taken off the navigation stack; a photo opened over it leaves it true.
    @Environment(\.isPresented) private var isPresented
    @State private var status: ExploreAuthStatus?
    @State private var unlocked: LibrarySession?
    @State private var pin = ""
    @State private var confirmation = ""
    @State private var error: String?
    @State private var busy = false
    /// Each unlock attempt's mark: locking or leaving makes a running attempt stale.
    @State private var generation = UUID()
    @State private var expiryTask: Task<Void, Never>?

    /// The PIN that unlocked the folder in this run of Verso, per sign-in, so Face ID unlocks it again without typing
    /// it; kept in memory only, gone when Verso quits, and of no use once signed out, as the next sign-in is another.
    /// Free Up Space's review uses it too, for hidden photos (FreeUpHiddenGroup).
    @MainActor static var sessionPINs: [String: String] = [:]

    /// The sign-in the PIN is kept for: the server and the session's token.
    private var pinKey: String? { Self.pinKey(session.client) }

    static func pinKey(_ client: ImmichClient) -> String? {
        guard case .accessToken(let token) = client.credential else { return nil }
        return client.serverURL.absoluteString + "|" + token
    }
    private var settingUp: Bool { status?.pinCode == false }
    /// Face ID or the passcode stands in for the PIN once it was typed in this run, where the app may ask for Face ID.
    private var canUseDeviceOwner: Bool {
        pinKey.flatMap { Self.sessionPINs[$0] } != nil && Bundle.main.object(forInfoDictionaryKey: "NSFaceIDUsageDescription") != nil
    }

    var body: some View {
        Group {
            if !session.client.exploreSupportsLockedFolder {
                ContentUnavailableView("Session Login Required", systemImage: "lock",
                                       description: Text("Sign in with email and password, or with single sign-on, to use Locked Folder. API keys cannot unlock a session."))
            } else if let unlocked {
                AssetGridPage(session: unlocked, source: .locked, title: String(localized: "Locked Folder"))
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Lock", systemImage: "lock.fill") { lock() }
                        }
                    }
            } else {
                pinForm
            }
        }
        .navigationTitle("Locked Folder")
        .task {
            session.lockFolder = { lock() }
            guard session.client.exploreSupportsLockedFolder else { return }
            do {
                status = try await Self.uncached(session.client) { try await $0.exploreAuth() }
                if canUseDeviceOwner { await unlockWithDeviceOwner() }
            } catch {
                session.handle(error)
                self.error = error.localizedDescription
            }
        }
        // Leaving the page locks it; a photo opened full screen over it does not.
        .onChange(of: isPresented) { _, presented in
            if !presented { leave() }
        }
        .onDisappear {
            if !isPresented { leave() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { lock() }
        }
        .alert("Locked Folder", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: {
            Text(error ?? "")
        }
    }

    /// Setting the PIN up, or unlocking with it.
    private var pinForm: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text(settingUp ? "Set Up Locked Folder" : "Unlock Locked Folder")
                        .font(.title2.bold())
                    Text("Locks when you leave the Locked Folder or Verso.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            Section {
                SecureField("Six-digit PIN", text: $pin)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                if settingUp {
                    SecureField("Confirm PIN", text: $confirmation)
                        .keyboardType(.numberPad)
                }
            }
            Section {
                Button(settingUp ? "Set PIN and Unlock" : "Unlock") {
                    let code = pin
                    Task { await unlock(code) }
                }
                .disabled(!pinIsComplete || busy || status == nil)
                if canUseDeviceOwner {
                    Button("Unlock with Face ID") { Task { await unlockWithDeviceOwner() } }
                        .disabled(busy)
                }
            }
        }
    }

    private var pinIsComplete: Bool {
        pin.range(of: "^[0-9]{6}$", options: .regularExpression) != nil && (!settingUp || pin == confirmation)
    }

    /// Status, unlock and lock requests skip the URL cache, so a stale status is never reused.
    static func uncached<Value>(_ account: ImmichClient, _ request: (ImmichClient) async throws -> Value) async throws -> Value {
        let client = account.explorePrivateClient()
        defer { client.session.finishTasksAndInvalidate() }
        return try await request(client)
    }

    /// Face ID, or the passcode where Face ID cannot be used, then the PIN kept from this run.
    private func unlockWithDeviceOwner() async {
        guard let key = pinKey, let code = Self.sessionPINs[key], !busy else { return }
        let context = LAContext()
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: String(localized: "Unlock the Locked Folder")) else { return }
        } catch {
            return // cancelled, or not available: the PIN is there
        }
        await unlock(code)
    }

    private func unlock(_ code: String) async {
        guard !busy else { return }
        busy = true
        let attempt = generation, account = session.client, services = session.services, key = pinKey
        defer { busy = false; pin = ""; confirmation = "" }
        do {
            let setup = settingUp
            let status = try await Self.uncached(account) { client in
                try await client.exploreUnlock(code, setup: setup)
                return try await client.exploreAuth()
            }
            guard attempt == generation, session.services === services else {
                Self.relock(account)
                return
            }
            self.status = status
            guard status.isElevated else { throw ImmichError.http(403, String(localized: "The server did not unlock this session.")) }
            if let key { Self.sessionPINs[key] = code }
            let media = LockedFolderMedia(account: account)
            media.onRequestFailed = { Task { await verify() } }
            unlocked = LibrarySession(services: services, lockedFolder: media)
            scheduleCheck(status.pinExpiresAt)
        } catch {
            guard attempt == generation else { return }
            // A PIN the server turns down is not kept for Face ID.
            if case ImmichError.http(let httpStatus, _) = error, httpStatus == 400 || httpStatus == 401, let key { Self.sessionPINs[key] = nil }
            session.handle(error)
            self.error = error.localizedDescription
        }
    }

    /// The server extends an unlock while it is used, so it is asked again just after it would have expired.
    private func scheduleCheck(_ expiry: String?) {
        expiryTask?.cancel()
        let date = expiry.flatMap(ImmichDate.parse) ?? Date().addingTimeInterval(15 * 60)
        expiryTask = Task {
            do { try await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow) + 2)) } catch { return }
            await verify()
        }
    }

    /// Locks unless the server still has the session unlocked; also after a Locked Folder request failed.
    private func verify() async {
        guard let media = unlocked?.lockedFolder else { return }
        do {
            let status = try await media.client.exploreAuth()
            guard unlocked?.lockedFolder === media else { return }
            if status.isElevated {
                scheduleCheck(status.pinExpiresAt)
            } else {
                lock()
                error = String(localized: "Locked Folder access expired. Unlock again to continue.")
            }
        } catch {
            guard unlocked?.lockedFolder === media else { return }
            lock()
            self.error = String(localized: "Could not verify Locked Folder access. Unlock again to continue.")
        }
    }

    private func leave() {
        session.lockFolder = {}
        lock()
    }

    /// Drops the unlocked session's grid, cached images and files, and locks the server's session.
    private func lock() {
        generation = UUID()
        pin = ""
        confirmation = ""
        expiryTask?.cancel()
        expiryTask = nil
        guard let locked = unlocked else { return }
        unlocked = nil
        locked.endSession()
        locked.lockedFolder?.discard()
        Self.relock(locked.services.client)
    }

    /// Locks the server's session with the account's client, in a task of its own, as the page may be gone.
    static func relock(_ account: ImmichClient) {
        Task { try? await uncached(account) { try await $0.exploreLock() } }
    }
}
