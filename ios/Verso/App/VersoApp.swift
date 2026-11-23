// Verso on iPhone and iPad (ROADMAP.md, "M10. Verso on iOS"): the app's entry, which starts the shared Rust core and
// keeps the one AppModel, as the Mac's VersoApp does, and its root, which shows sign-in or the library by the
// account's phase and gives backing up the signed-in account, and tells it when Verso comes to the foreground, where
// new photos go at once.

import SwiftUI

@main
struct VersoApp: App {
    /// Backing the iPhone up's part of launching, and the background session's wake-ups (BackupLaunch).
    @UIApplicationDelegateAdaptor(VersoAppDelegate.self) private var appDelegate
    @State private var app = AppModel()

    init() {
        CoreTransport.install() // the endpoint calls through the shared Rust core
        // The Backup page opens in the window in front, one of several on an iPad.
        BackupCenter.shared.frontWindow = {
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
                .first(where: \.isKeyWindow)
        }
    }

    var body: some Scene {
        WindowGroup {
            VersoRoot()
                .environment(app)
        }
        // The hardware keyboard's commands, in iPadOS's menu bar (VersoCommands).
        .commands { VersoCommands() }
    }
}

/// Sign-in while signed out, the three tabs while signed in, and the account's errors in an alert.
struct VersoRoot: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        // A container of its own, not a Group, which would hand its modifiers to whichever page shows: the task below
        // then belongs to the root and runs once, rather than again at every sign-in and sign-out, where the launch
        // arguments would sign Verso Dev straight back in or out.
        ZStack {
            switch app.phase {
            case .launching:
                ProgressView()
            case .signedOut:
                SignInView()
            case .signedIn(let services):
                LibraryTabs(services: services)
                    .id(ObjectIdentifier(services))
            }
        }
        .alert("Account Error", isPresented: accountErrorShown) {
            Button("OK") { app.accountError = nil }
        } message: {
            Text(app.accountError ?? "")
        }
        // The app's own link to its Backup page (`<scheme>://backup`), which the Live Activity opens.
        .onOpenURL { url in
            if url.host() == "backup" { BackupCenter.shared.showPage() }
        }
        // In the foreground, backing up reads the library again and sends its new photos at once.
        .onChange(of: scenePhase, initial: true) { _, phase in
            BackupCenter.shared.setActive(phase == .active)
        }
        .task {
            // Backing up goes to the signed-in account (BackupCenter).
            BackupCenter.shared.follow(app)
            await app.restore()
            #if DEBUG
            // Signing Verso Dev in and out from launch arguments, as on the Mac (AppModel.followLaunchArguments), or
            // from its environment. A script's sign-out also switches backing up off, so a walk leaves nothing behind
            // that a later sign-in to the same account would start.
            if UserDefaults.standard.bool(forKey: "signOut") { await BackupCenter.shared.setOn(false) }
            // Backing up's walk holds uploads for a while (`VERSO_BACKUP_HOLD`, in seconds), to see photos on their
            // way.
            if let seconds = ProcessInfo.processInfo.environment["VERSO_BACKUP_HOLD"].flatMap(Double.init) {
                BackupCenter.shared.holdUploads(for: seconds)
            }
            await app.followLaunchArguments()
            await app.signInFromEnvironment()
            #endif
        }
    }

    private var accountErrorShown: Binding<Bool> {
        Binding(get: { app.accountError != nil }, set: { shown in if !shown { app.accountError = nil } })
    }
}

#if DEBUG
extension AppModel {
    /// Verso Dev signed in from its environment rather than its launch arguments, as backing up's walk does it against
    /// a lab server (ios/VersoUITests/BackupWalkTests.swift): `VERSO_SIGN_IN_SERVER` with `VERSO_SIGN_IN_API_KEY`, or
    /// with `VERSO_SIGN_IN_EMAIL` and `VERSO_SIGN_IN_PASSWORD` for a session of its own, which the Locked Folder needs
    /// (MenuWritesWalkTests), so the key or password is in no argument list.
    func signInFromEnvironment() async {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["VERSO_SIGN_IN_SERVER"] else { return }
        do {
            let client = try await ImmichClient.discover(server)
            let credential: Credential
            if let key = environment["VERSO_SIGN_IN_API_KEY"] {
                credential = .apiKey(key)
            } else if let email = environment["VERSO_SIGN_IN_EMAIL"], let password = environment["VERSO_SIGN_IN_PASSWORD"] {
                credential = .accessToken(try await client.login(email: email, password: password))
            } else {
                return
            }
            await restore()
            try await signIn(client: client, credential: credential)
        } catch {
            accountError = error.localizedDescription
        }
    }
}
#endif
