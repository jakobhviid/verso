import DeviceDiscoveryUI
import Network
import SwiftUI
import UIKit

/// Before the iPhone has set the TV up: the system's picker of the iPhones nearby with Verso's Set Up Apple TV open,
/// and the server and key the chosen one sends (`AccountAppleTVPage` on the iPhone).
struct TVSetUpView: View {
    @Environment(TVModel.self) private var model
    @State private var failure: String?
    @State private var connection: NWConnection?

    var body: some View {
        VStack(spacing: 32) {
            Image(systemName: "iphone.and.arrow.forward").font(.system(size: 80))
            Text("Set Up Verso with Your iPhone").font(.title2)
            Text("On your iPhone, open Verso, then Account, Set Up Apple TV.").foregroundStyle(.secondary)
            DevicePicker(.applicationService(name: "verso-tv-setup")) { endpoint in
                receive(from: endpoint)
            } label: {
                Label("Set Up with iPhone", systemImage: "iphone")
            } fallback: {
                Text("This Apple TV cannot look for iPhones.")
            } parameters: {
                .applicationService
            }
            if let failure { Text(failure).foregroundStyle(.orange) }
        }
    }

    private func receive(from endpoint: NWEndpoint) {
        let connection = NWConnection(to: endpoint, using: .applicationService)
        self.connection = connection
        failure = nil
        connection.start(queue: .main)
        // The TV's name first, which the iPhone asks the person about.
        let hello = (try? JSONEncoder().encode(["name": UIDevice.current.name])) ?? Data()
        connection.send(content: hello, completion: .contentProcessed { _ in })
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, error in
            Task { @MainActor in
                defer { connection.cancel() }
                let fields = data.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
                if fields?["refused"] != nil {
                    failure = String(localized: "The iPhone did not allow it.")
                    return
                }
                guard let fields, let server = fields["server"], let key = fields["key"] else {
                    failure = String(localized: "The iPhone did not send the sign-in\(error.map { ": \($0.localizedDescription)" } ?? ".")")
                    return
                }
                model.signIn(TVAccount(server: server, key: key))
            }
        }
    }
}
