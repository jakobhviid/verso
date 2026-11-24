// What Verso asks on the Mac, the iPhone and the iPad when a server presents a certificate the system does not trust,
// nor the one trusted for the server (ARCHITECTURE.md, "A certificate of the server's own"; SPEC.md, "Signing in and
// credentials"), in the words Linux uses: whether to trust it, with what to compare. What the certificate says about
// itself is read by the core from its DER (`certificateDetails`), as iOS lets no app read a certificate's dates or
// issuer. Each platform draws it in its own controls (the Mac's CertificateQuestionSheet, the iPhone's).

import Foundation
import VersoCore
#if os(iOS)
import UIKit
#endif

struct CertificateQuestion: Identifiable, Equatable, Sendable {
    /// One line of the certificate's details.
    struct Detail: Identifiable, Equatable, Sendable {
        let title: String
        let value: String
        /// A fingerprint, shown in a fixed-width font to compare pair by pair.
        let fingerprint: Bool
        var id: String { title }
    }

    /// The server it was presented for, as its certificates are trusted (ServerTrust).
    let server: URL
    /// The certificate's SHA-256 fingerprint, in pairs: what Trust This Certificate trusts.
    let sha256: String
    /// The server presented another certificate than the one trusted for it.
    let changed: Bool
    let host: String
    let heading: String
    let body: String
    let details: [Detail]

    var id: String { sha256 }

    @MainActor init(_ refused: ServerTrust.Refused, now: Date = .now) {
        let said = certificateDetails(der: refused.der)
        server = refused.server
        sha256 = refused.sha256
        changed = refused.trustedUntilNow != nil
        host = refused.host
        if changed {
            heading = String(localized: "The Server's Certificate Changed")
        } else {
            heading = String(localized: "Trust This Server's Certificate?")
        }
        let device = Self.thisDevice
        var sentences = [changed
            ? String(localized: "\(host) presented another certificate than the one you trusted for it. If its certificate was renewed or replaced, that is expected; if not, someone between Verso and the server may be pretending to be it. Verso sends nothing to it until you decide.")
            : String(localized: "The certificate \(host) presented is not one this \(device) trusts. A server at home often has a certificate of its own, but anyone between Verso and the server could also be pretending to be it.")]
        if let until = said.validUntil, until < now {
            sentences.append(String(localized: "It expired on \(Self.day(until))."))
        } else if let from = said.validFrom, from > now {
            sentences.append(String(localized: "It is not valid before \(Self.day(from))."))
        } else if refused.otherName {
            sentences.append(String(localized: "It was not made for \(host)."))
        }
        sentences.append(String(localized: "Trust it only if this fingerprint is your server's: on the server, “openssl x509 -noout -fingerprint -sha256 -in” with its certificate file shows it."))
        body = sentences.joined(separator: " ")
        let unknown = String(localized: "Not stated")
        let stated = { (text: String) in text.trimmingCharacters(in: .whitespaces).isEmpty ? unknown : text }
        var details = [
            Detail(title: String(localized: "Fingerprint (SHA-256)"), value: Self.lines(sha256), fingerprint: true),
            Detail(title: String(localized: "Issued To"), value: stated(said.subject), fingerprint: false),
            Detail(title: String(localized: "Issued By"),
                   value: said.selfSigned ? String(localized: "Itself (self-signed)") : stated(said.issuer), fingerprint: false),
            Detail(title: String(localized: "Valid From"), value: said.validFrom.map(Self.day) ?? unknown, fingerprint: false),
            Detail(title: String(localized: "Valid Until"), value: said.validUntil.map(Self.day) ?? unknown, fingerprint: false),
        ]
        if let trusted = refused.trustedUntilNow {
            details.append(Detail(title: String(localized: "Trusted Until Now"), value: Self.lines(trusted), fingerprint: true))
        }
        self.details = details
    }

    /// A fingerprint in lines of eight pairs, so it breaks between pairs rather than inside one.
    static func lines(_ fingerprint: String, pairs: Int = 8) -> String {
        let all = fingerprint.split(separator: ":")
        return stride(from: 0, to: all.count, by: pairs)
            .map { all[$0..<min($0 + pairs, all.count)].joined(separator: ":") }
            .joined(separator: "\n")
    }

    private static func day(_ date: Date) -> String {
        date.formatted(date: .long, time: .omitted)
    }

    /// "Mac", "iPhone" or "iPad", as the question names the device that does not trust the certificate.
    @MainActor private static var thisDevice: String {
        #if os(macOS)
        "Mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }
}
