// Verso in Messages (ROADMAP.md, M10, "A photo picker in Messages"): the iMessage app's view controller, which Messages
// makes as the person opens Verso from its row of apps. It hosts the picker's SwiftUI views (MessagesPicker), tells
// them which of Messages' two sizes shows (compact, under the conversation, or expanded over it), and does for them
// what only it can: put a photo into the conversation's message field, ask for the other size, and open Verso. The
// account is the app's (PickerModel), read again each time the picker becomes active, so signing in or out in Verso
// shows here at once.

import Messages
import SwiftUI
import UIKit

final class MessagesViewController: MSMessagesAppViewController {
    private let model = PickerModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.host = self
        let hosting = UIHostingController(rootView: MessagesPicker(model: model))
        addChild(hosting)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hosting.didMove(toParent: self)
    }

    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        model.isExpanded = presentationStyle == .expanded
        model.becameActive()
    }

    override func willTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        super.willTransition(to: presentationStyle)
        model.isExpanded = presentationStyle == .expanded
    }
}

extension MessagesViewController: PickerHost {
    func insert(_ file: URL, named name: String) async throws {
        guard let conversation = activeConversation else { throw PickerProblem.noConversation }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // Messages may answer on a queue of its own.
            conversation.insertAttachment(file, withAlternateFilename: name) { @Sendable error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func askForSize(expanded: Bool) {
        requestPresentationStyle(expanded ? .expanded : .compact)
    }

    func openVerso() {
        let scheme = Bundle.main.object(forInfoDictionaryKey: "VersoURLScheme") as? String ?? "verso"
        guard let url = URL(string: "\(scheme)://") else { return }
        extensionContext?.open(url, completionHandler: nil)
    }
}
