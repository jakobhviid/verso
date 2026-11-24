// A server's own certificate on the Mac, the iPhone and the iPad (ARCHITECTURE.md, "A certificate of the server's own"):
// the certificate the person trusted for a server where the system does not trust its own, and the one answer every
// session the app makes gives to the server-trust challenge. The core's requests take the same certificate through the
// bridge (`Client::trusting`); AVPlayer, which asks the app nothing, streams through a session of these
// (VideoStream.swift).
//
// The system judges first, as for any server; only a certificate it refuses for a reason a server's own certificate
// gives (an issuer it does not trust, another name, its dates; never a revoked one) is then compared with the
// certificate trusted for that server, by the SHA-256 of its DER, and accepted only when they are the same. A refused
// certificate is left to the system, which fails the request with its error and the certificate in it
// (`refused(in:)`), so the app can ask.

import CryptoKit
import Foundation
import Security
import Synchronization

enum ServerTrust {
    /// The certificate trusted for each server where the system does not trust its own, by the server's host and port:
    /// the account's, kept with it (AccountVault), and one the person trusted as they sign in.
    private static let trusted = Mutex<[String: String]>([:])

    /// A server as its certificates are trusted: its host and port, never its path.
    static func origin(_ server: URL) -> String? {
        guard let host = server.host()?.lowercased() else { return nil }
        return "\(host):\(server.port ?? (server.scheme?.lowercased() == "http" ? 80 : 443))"
    }

    /// Trust `certificate` (its SHA-256 fingerprint) for `server` where the system does not trust its own, or nothing
    /// with nil: Trust This Certificate, Forget, and an account read or kept.
    static func trust(_ certificate: String?, for server: URL) {
        guard let origin = origin(server) else { return }
        let fingerprint = certificate.flatMap(normalized)
        trusted.withLock { $0[origin] = fingerprint }
    }

    /// The certificate trusted for `server`, in pairs (`AB:CD:…`); nil where none is.
    static func certificate(for server: URL) -> String? {
        guard let origin = origin(server) else { return nil }
        return trusted.withLock { $0[origin] }
    }

    /// Forget every certificate trusted in this process: signing out.
    static func forgetAll() {
        trusted.withLock { $0.removeAll() }
    }

    /// A fingerprint as people write it (64 hexadecimal digits in either case, in pairs separated by colons or spaces
    /// or not) as Verso shows it, in pairs of capitals separated by colons; nil when it is not one.
    static func normalized(_ text: String) -> String? {
        let digits = text.split(separator: "=").last.map(String.init) ?? text
        let hex = digits.filter { $0 != ":" && $0 != " " && !$0.isNewline }.uppercased()
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
        return stride(from: 0, to: 64, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return String(hex[start..<hex.index(start, offsetBy: 2)])
        }.joined(separator: ":")
    }

    /// A certificate's SHA-256 fingerprint, over its DER, in pairs, as `openssl x509 -fingerprint -sha256` prints it.
    static func fingerprint(of der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    // MARK: The challenge

    /// The one answer to a session's challenges: the server's certificate as the system judges it, or, where it
    /// refuses one a server's own certificate may be, as the certificate trusted for that server; every other
    /// challenge as the system answers it.
    static func answer(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = space.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        var refusal: CFError?
        if SecTrustEvaluateWithError(trust, &refusal) { return (.performDefaultHandling, nil) }
        // A revoked certificate is refused whatever is trusted.
        if let refusal, CFErrorGetCode(refusal) == Int(errSecCertificateRevoked) { return (.performDefaultHandling, nil) }
        let origin = "\(space.host.lowercased()):\(space.port)"
        guard let pinned = trusted.withLock({ $0[origin] }), let leaf = leafDER(trust), fingerprint(of: leaf) == pinned else {
            // The system refuses it, with its error and the certificate in it.
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }

    /// The delegate that answers a session's challenges so (`answer`), for sessions without a delegate of their own.
    final class Delegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge)
            async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            ServerTrust.answer(challenge)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge)
            async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            ServerTrust.answer(challenge)
        }
    }

    static let delegate = Delegate()

    /// A session that talks to Immich: `configuration`, with the challenges answered as above.
    static func session(_ configuration: URLSessionConfiguration) -> URLSession {
        URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    // MARK: A refused certificate

    /// A certificate a server presented that the system refused, and that is not the one trusted for the server:
    /// what the person sees to decide (CertificateQuestion), as the app's own request found it.
    struct Refused: LocalizedError, Sendable {
        /// The server as its certificates are trusted: its scheme, host and port.
        let server: URL
        /// The certificate's DER.
        let der: Data
        /// Not made for the server's name.
        let otherName: Bool
        /// The certificate trusted for the server until now, when it presented another: it changed.
        let trustedUntilNow: String?

        var sha256: String { ServerTrust.fingerprint(of: der) }
        /// The server as people know it: its host, with its port where it has one.
        var host: String {
            let name = server.host() ?? server.absoluteString
            return server.port.map { "\(name):\($0)" } ?? name
        }

        var errorDescription: String? {
            String(localized: "The server's certificate isn't trusted.")
        }
    }

    /// The certificate in a request's failure, when the system refused the server's certificate and it is not the
    /// one trusted for the server.
    static func refused(in error: Error) -> Refused? {
        guard let urlError = error as? URLError, let trust = urlError.failureURLPeerTrust,
              let failing = urlError.failingURL,
              var parts = URLComponents(url: failing, resolvingAgainstBaseURL: false),
              let leaf = SecTrustCopyCertificateChain(trust).flatMap({ ($0 as? [SecCertificate])?.first }) else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        guard let server = parts.url else { return nil }
        let pinned = certificate(for: server)
        guard pinned != fingerprint(of: der) else { return nil }
        return Refused(server: server, der: der, otherName: madeForAnotherName(trust), trustedUntilNow: pinned)
    }

    /// Whether a request failed because the server's certificate was refused: by the system for the app's own
    /// requests, or by the core's for its own (a URLError of a certificate either way).
    static func isRefusal(_ error: Error) -> Bool {
        if error is Refused { return true }
        if let urlError = error as? URLError, urlError.failureURLPeerTrust != nil { return true }
        return ServerAddress.isCertificateError(error)
    }

    /// The certificate's DER, the leaf of what the server presented.
    private static func leafDER(_ trust: SecTrust) -> Data? {
        guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else { return nil }
        return SecCertificateCopyData(leaf) as Data
    }

    /// Whether the system found the certificate made for another name than the server's. Its error names one reason
    /// alone ("not trusted" before the name), so the evaluation's details per certificate are read, where the leaf's
    /// carries `SSLHostname` when the name failed; without them the question leaves the sentence out. A certificate
    /// judged as its own anchor is no help: it fails first on its purpose (`errSecInvalidExtendedKeyUsage`), as
    /// openssl's default self-signed certificate has none.
    private static func madeForAnotherName(_ trust: SecTrust) -> Bool {
        _ = SecTrustEvaluateWithError(trust, nil)
        let result = SecTrustCopyResult(trust) as? [String: Any]
        let details = result?["TrustResultDetails"] as? [[String: Any]]
        return details?.first?["SSLHostname"] != nil
    }
}
