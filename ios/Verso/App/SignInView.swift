// Signing in on iOS, the app's first screen, in iOS 26's own design. A welcome first: the app's icon, "Verso for
// Immich" and what it is, above the server's address and a line on what Verso needs (an Immich server, run by the
// person or a hosting provider) with Try the Demo, which signs in to Immich's public demo, and with Continue and the
// non-affiliation notice (SPEC.md) in a bar at the foot that rides above the keyboard, as Apple's welcome screens have
// their button and privacy line. Continue
// pushes the sign-in page for the server it found: the server's name and Immich's version, then the ways in the
// server offers, laid out as on Linux (linux/verso/src/window.blp): its single sign-on with its own button text, in
// the system's web authentication session, where passkeys and password managers work; an email and password, whose
// fields AutoFill knows; and an API key, tucked under a disclosure unless it is the only way in. The steps and the
// calls are the Mac's LoginView's (mac/Verso/Verso/Views/Login/LoginView.swift); AppModel keeps the account.
//
// Each page is a column of a reading width on the grouped background, centred where it fits and scrolling where it
// does not (the largest text, landscape, the keyboard), so it stays a column on iPad. Return moves to the next field
// and signs in from the last. An error shows in plain words under what caused it and goes once that is edited.
// Nothing moves as it loads: the sign-in page is pushed as the answer to Continue, and only the API key's section,
// opened by a tap, expands.

import AuthenticationServices
import SwiftUI
import UIKit

/// The column's width on a wide screen, about that of a sign-in sheet.
private let columnWidth: CGFloat = 440

struct SignInView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The server Continue found, which the sign-in page is pushed for.
    @State private var found: FoundServer?
    #if DEBUG
    @State private var serverText = AccountStore.lastServer ?? "https://demo.immich.app"
    #else
    @State private var serverText = AccountStore.lastServer ?? ""
    #endif
    @State private var isConnecting = false
    @State private var tryingDemo = false
    @State private var serverProblem: String?
    @FocusState private var serverFocused: Bool

    var body: some View {
        NavigationStack {
            welcome
                .navigationDestination(item: $found) { server in
                    SignInMethodsPage(server: server)
                }
        }
    }

    private var isCompactHeight: Bool { verticalSizeClass == .compact }

    /// The notice sits above Continue unless it would crowd the page out (landscape on the iPhone, the largest
    /// text), where it ends the page instead; it gives way to the keyboard while the address is typed.
    private var noticeInBar: Bool { !isCompactHeight && !dynamicTypeSize.isAccessibilitySize }

    private var welcome: some View {
        SignInColumn {
            VStack(spacing: isCompactHeight ? 20 : 36) {
                WelcomeHeader(compact: isCompactHeight)
                serverField
                demoOffer
                if !noticeInBar {
                    NonAffiliationNotice()
                        .padding(.top, 12)
                }
            }
        }
        .safeAreaBar(edge: .bottom) {
            VStack(spacing: 16) {
                if noticeInBar && !serverFocused {
                    NonAffiliationNotice()
                }
                SignInButton(Text("Continue"), prominent: true, working: isConnecting, action: connect)
                    .disabled(serverText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || tryingDemo)
            }
            .frame(maxWidth: columnWidth)
            .padding(.horizontal, 24)
            .padding(.bottom, isCompactHeight ? 4 : 12)
        }
        // A firm edge under the bar where the page scrolls beneath Continue; the system's soft one where it fits.
        .scrollEdgeEffectStyle(noticeInBar ? .soft : .hard, for: .bottom)
        .toolbarVisibility(.hidden, for: .navigationBar)
    }

    private var serverField: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldBox {
                HStack(spacing: 12) {
                    if !dynamicTypeSize.isAccessibilitySize {
                        Image(systemName: "server.rack")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    TextField("Server Address", text: $serverText, prompt: Text(verbatim: "photos.example.com"))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.continue)
                        .focused($serverFocused)
                        .onSubmit(connect)
                        .accessibilityIdentifier("server")
                }
                .fieldRow()
            }
            FieldNote(problem: serverProblem, note: "Enter the address of your Immich server.")
        }
        .onChange(of: serverText) { serverProblem = nil }
    }

    /// What Verso needs, and a way to look around without it.
    private var demoOffer: some View {
        VStack(spacing: 12) {
            Text("Verso shows the photos on an Immich server: one you run yourself, or one from a hosting provider. No server yet? Try Verso on Immich's public demo.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            SignInButton(Text("Try the Demo"), systemImage: "play.circle", prominent: false, working: tryingDemo,
                         action: tryDemo)
                .disabled(isConnecting)
                .accessibilityIdentifier("tryDemo")
        }
    }

    /// Immich's public demo, with the sign-in Immich publishes for it on its own sign-in page.
    private static let demo = (server: "https://demo.immich.app", email: "demo@immich.app", password: "demo")

    /// Signs in to the demo straight away, its server found and its account signed in as Continue and a password do.
    private func tryDemo() {
        guard !tryingDemo, !isConnecting else { return }
        tryingDemo = true
        serverProblem = nil
        Task {
            do {
                let client = try await ImmichClient.discover(Self.demo.server)
                let token = try await client.login(email: Self.demo.email, password: Self.demo.password)
                try await app.signIn(client: client, credential: .accessToken(token))
            } catch {
                serverProblem = error.localizedDescription
                AccessibilityNotification.Announcement(error.localizedDescription).post()
            }
            tryingDemo = false
        }
    }

    private func connect() {
        let address = serverText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isConnecting, !address.isEmpty else { return }
        serverProblem = nil
        isConnecting = true
        Task {
            do {
                found = try await FoundServer.discover(address)
            } catch {
                serverProblem = error.localizedDescription
                AccessibilityNotification.Announcement(error.localizedDescription).post()
            }
            isConnecting = false
        }
    }
}

/// A server Continue found: its client, what it offers, and its version.
private struct FoundServer: Identifiable, Hashable, Sendable {
    let id = UUID()
    let client: ImmichClient
    let features: ServerFeatures
    let version: ServerVersion?
    /// The server's own single sign-on button text, when it offers single sign-on.
    let oauthButton: String?

    /// The server as people know it: its host, and its port where it has one.
    var name: String {
        let address = client.serverURL
        guard let host = address.host() else { return address.absoluteString }
        return address.port.map { "\(host):\($0)" } ?? host
    }

    /// Finds the Immich server at an address and what it offers, as the Mac's LoginView does.
    static func discover(_ address: String) async throws -> FoundServer {
        let client = try await ImmichClient.discover(address)
        async let features = try? client.serverFeatures()
        async let version = try? client.serverVersion()
        let offered = await features ?? ServerFeatures()
        let oauthButton = offered.oauth ? await client.oauthButtonText() : nil
        return FoundServer(client: client, features: offered, version: await version, oauthButton: oauthButton)
    }

    static func == (left: FoundServer, right: FoundServer) -> Bool { left.id == right.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - The sign-in page

/// The ways into a found server, as it offers them, under its name and version.
private struct SignInMethodsPage: View {
    let server: FoundServer

    @Environment(AppModel.self) private var app
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    private enum Way: Hashable { case singleSignOn, password, apiKey }
    private enum Field: Hashable { case email, password, apiKey }
    private struct Problem: Equatable {
        let way: Way
        let message: String
    }

    @State private var email = ""
    @State private var password = ""
    @State private var apiKey = ""
    @State private var showsAPIKey = false
    @State private var working: Way?
    @State private var problem: Problem?
    @FocusState private var focused: Field?

    /// An API key is the only way into a server with neither single sign-on nor passwords: its section shows open,
    /// with the prominent button.
    private var apiKeyOnly: Bool { server.oauthButton == nil && !server.features.passwordLogin }

    var body: some View {
        SignInColumn {
            VStack(spacing: 28) {
                header
                if let oauthButton = server.oauthButton {
                    singleSignOn(oauthButton)
                    if server.features.passwordLogin { OrDivider() }
                }
                if server.features.passwordLogin {
                    passwordFields
                }
                apiKeySection
            }
        }
        .allowsHitTesting(working == nil)
        .onAppear {
            // Straight on to typing where the fields are the main way in.
            if server.oauthButton == nil {
                focused = server.features.passwordLogin ? .email : .apiKey
            }
        }
        .onChange(of: email) { clearProblem(.password) }
        .onChange(of: password) { clearProblem(.password) }
        .onChange(of: apiKey) { clearProblem(.apiKey) }
    }

    private var header: some View {
        VStack(spacing: 20) {
            Text("Sign In")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            ServerCard(server: server)
        }
    }

    private func singleSignOn(_ title: String) -> some View {
        VStack(spacing: 10) {
            SignInButton(Text(verbatim: title), systemImage: "person.badge.key", prominent: true,
                         working: working == .singleSignOn, action: signInWithBrowser)
            FieldNote(problem: problem(for: .singleSignOn),
                      note: "Opens your server's sign-in page, where passkeys and password managers work.",
                      alignment: .center)
        }
    }

    private var passwordFields: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                FieldBox {
                    TextField("Email", text: $email, prompt: Text("Email"))
                        .keyboardType(.emailAddress)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focused, equals: .email)
                        .onSubmit { focused = .password }
                        .accessibilityIdentifier("email")
                        .fieldRow()
                    Divider()
                        .padding(.leading, 16)
                    SecureField("Password", text: $password, prompt: Text("Password"))
                        .textContentType(.password)
                        .submitLabel(.go)
                        .focused($focused, equals: .password)
                        .onSubmit(signInWithPassword)
                        .accessibilityIdentifier("password")
                        .fieldRow()
                }
                FieldNote(problem: problem(for: .password))
            }
            SignInButton(Text("Sign In"), prominent: server.oauthButton == nil, working: working == .password,
                         action: signInWithPassword)
                .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
        }
    }

    private var apiKeySection: some View {
        VStack(spacing: 16) {
            if !apiKeyOnly {
                Button(action: toggleAPIKey) {
                    HStack(spacing: 6) {
                        Text("Use an API Key Instead")
                        Image(systemName: "chevron.down")
                            .font(.footnote.weight(.semibold))
                            .rotationEffect(.degrees(showsAPIKey ? 180 : 0))
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Use an API Key Instead")
                .accessibilityValue(showsAPIKey ? Text("Shown") : Text("Hidden"))
                .accessibilityIdentifier("apiKeyDisclosure")
            }
            if showsAPIKey || apiKeyOnly {
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        FieldBox {
                            SecureField("API Key", text: $apiKey, prompt: Text("API Key"))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .submitLabel(.go)
                                .focused($focused, equals: .apiKey)
                                .onSubmit(signInWithAPIKey)
                                .accessibilityIdentifier("apiKey")
                                .fieldRow()
                        }
                        FieldNote(problem: problem(for: .apiKey),
                                  note: "Create an API key in Immich under Account Settings → API Keys. Its permissions limit what Verso can change.")
                    }
                    SignInButton(Text("Sign In with Key"), prominent: apiKeyOnly, working: working == .apiKey,
                                 action: signInWithAPIKey)
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .transition(.opacity)
                // Opened by a tap, straight on to pasting the key.
                .onAppear { if !apiKeyOnly { focused = .apiKey } }
            }
        }
    }

    private func toggleAPIKey() {
        if showsAPIKey, focused == .apiKey { focused = nil }
        withAnimation(.smooth(duration: 0.3)) { showsAPIKey.toggle() }
    }

    private func problem(for way: Way) -> String? {
        problem?.way == way ? problem?.message : nil
    }

    private func clearProblem(_ way: Way) {
        if problem?.way == way { problem = nil }
    }

    private func signInWithPassword() {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { focused = .email; return }
        guard !password.isEmpty else { focused = .password; return }
        let client = server.client
        let secret = password
        run(.password) {
            let token = try await client.login(email: address, password: secret)
            try await app.signIn(client: client, credential: .accessToken(token))
        }
    }

    private func signInWithAPIKey() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { focused = .apiKey; return }
        let client = server.client
        run(.apiKey) {
            try await app.signIn(client: client, credential: .apiKey(key))
        }
    }

    /// Single sign-on in a web authentication session, which ends at the redirect URI Immich's mobile app uses.
    private func signInWithBrowser() {
        let client = server.client
        run(.singleSignOn) {
            let attempt = try OAuthAttempt()
            let address = try await client.oauthAuthorize(attempt)
            let redirect: URL
            do {
                redirect = try await webAuthenticationSession.authenticate(
                    using: address, callbackURLScheme: OAuthAttempt.callbackScheme, preferredBrowserSession: nil)
            } catch ASWebAuthenticationSessionError.canceledLogin {
                return
            }
            let response = try await client.oauthCallback(redirect, attempt)
            try await app.signIn(client: client, credential: .accessToken(response.accessToken))
        }
    }

    private func run(_ way: Way, _ work: @escaping () async throws -> Void) {
        guard working == nil else { return }
        problem = nil
        working = way
        Task {
            do {
                try await work()
            } catch {
                let message = plainMessage(error, way: way)
                problem = Problem(way: way, message: message)
                AccessibilityNotification.Announcement(message).post()
            }
            working = nil
        }
    }

    /// A refusal in the server's words, or else in those of the way that was tried; any other error as the client
    /// words it.
    private func plainMessage(_ error: Error, way: Way) -> String {
        let refused: String? = switch error {
        case ImmichError.unauthorized(let message): message
        case ImmichError.http(401, let message): message
        default: error.localizedDescription
        }
        if let refused { return refused }
        return switch way {
        case .password: String(localized: "The email or password is wrong.")
        case .apiKey: String(localized: "Immich didn't accept this API key. Check that it's whole and hasn't been deleted.")
        case .singleSignOn: String(localized: "Immich didn't accept the sign-in. Please try again.")
        }
    }
}

// MARK: - Pieces

/// A page's column: a reading width on iPad, centred a little above the middle where it fits and scrolling where it
/// does not, on the grouped background the fields' boxes stand out from.
private struct SignInColumn<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: columnWidth)
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(UnitPoint(x: 0.5, y: 0.4), for: .alignment)
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemGroupedBackground))
    }
}

/// The app's icon, its name with Immich's beside it, and what it is, in the words of its desktop entry.
private struct WelcomeHeader: View {
    let compact: Bool

    var body: some View {
        VStack(spacing: compact ? 8 : 12) {
            if let icon = UIImage.versoAppIcon {
                let size: CGFloat = compact ? 72 : 120
                Image(uiImage: icon)
                    .resizable()
                    .frame(width: size, height: size)
                    // The Home Screen's rounded square, at its proportion of the icon.
                    .clipShape(.rect(cornerRadius: size * 0.225, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                    .padding(.bottom, compact ? 4 : 12)
                    .accessibilityHidden(true)
            }
            Text(verbatim: "Verso for Immich")
                .font(compact ? .title.bold() : .largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            Text("Browse, search and organise your Immich photos and videos.")
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
    }
}

/// The server found: its name and Immich's version, with a tick, or a warning where the version is older than
/// Verso supports.
private struct ServerCard: View {
    let server: FoundServer

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isSupported: Bool { server.version?.isSupported ?? true }

    /// The mark beside the name, or above it at the largest sizes, where the name needs the card's whole width.
    private var layout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 14))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            layout {
                Image(systemName: isSupported ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(isSupported ? .green : .orange)
                    .accessibilityLabel(isSupported ? Text("Server found") : Text("Server found, with a warning"))
                VStack(alignment: .leading, spacing: 2) {
                    // A break allowed after each dot, where the largest text wraps the name rather than hyphenating it.
                    Text(verbatim: server.name.replacingOccurrences(of: ".", with: ".\u{200B}"))
                        .font(.headline)
                        .accessibilityLabel(Text(verbatim: server.name))
                    if let version = server.version {
                        Text("Immich \(version.description)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(verbatim: "Immich")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 26, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("serverCard")
            if !isSupported {
                Text("This server is older than Immich 3.2 and may not work correctly.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
        }
    }
}

/// Fields in one rounded box, as a grouped list's section draws them; the rows bring their own dividers.
private struct FieldBox<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 26, style: .continuous))
    }
}

private extension View {
    /// A field's row in a FieldBox.
    func fieldRow() -> some View {
        padding(.horizontal, 16)
            .padding(.vertical, 15)
    }
}

/// The line under a field or a button: what went wrong there, in red with its mark, or else a quiet note.
private struct FieldNote: View {
    let problem: String?
    var note: LocalizedStringKey?
    var alignment: TextAlignment = .leading

    var body: some View {
        Group {
            if let problem {
                Label {
                    Text(verbatim: problem)
                } icon: {
                    Image(systemName: "exclamationmark.circle.fill")
                }
                .foregroundStyle(.red)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("problem")
            } else if let note {
                Text(note)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.footnote)
        .multilineTextAlignment(alignment)
        .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
        .padding(.horizontal, 16)
    }
}

/// A full-width glass capsule, the prominent one for the page's main way in; a spinner takes its title's place
/// while it works.
private struct SignInButton: View {
    let title: Text
    let systemImage: String?
    let prominent: Bool
    let working: Bool
    let action: () -> Void

    init(_ title: Text, systemImage: String? = nil, prominent: Bool, working: Bool, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.prominent = prominent
        self.working = working
        self.action = action
    }

    var body: some View {
        let button = Button(action: action) {
            ZStack {
                Group {
                    if let systemImage {
                        Label { title } icon: { Image(systemName: systemImage) }
                    } else {
                        title
                    }
                }
                .fontWeight(.semibold)
                .opacity(working ? 0 : 1)
                if working {
                    ProgressView()
                        .tint(prominent ? .white : nil)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonBorderShape(.capsule)
        if prominent {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.glass)
        }
    }
}

/// "or" between single sign-on and the email and password, on a hairline.
private struct OrDivider: View {
    var body: some View {
        HStack(spacing: 12) {
            VStack { Divider() }
            Text("or")
                .font(.footnote)
                .foregroundStyle(.secondary)
            VStack { Divider() }
        }
        .accessibilityHidden(true)
    }
}

/// The non-affiliation notice the app's Info.plist carries, which SPEC.md words, small and quiet.
private struct NonAffiliationNotice: View {
    var body: some View {
        Text(verbatim: Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? "")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}

extension UIImage {
    /// The picture of the app's icon as the Home Screen shows it, Day in light mode and Night in dark mode: the design
    /// and lens chosen in App Icon, in this build's drawing (AppIconImage for Mist in color, AppIconDevImage in Verso
    /// Dev; AccountAppIconPage.swift). The icon itself is an Icon Composer document, which UIImage(named:) has no API to
    /// read back, and doing so can fail inside UIKit.
    @MainActor static var versoAppIcon: UIImage? {
        appIconPicture(.current) ?? UIImage(named: "AppIconImage")
    }
}
