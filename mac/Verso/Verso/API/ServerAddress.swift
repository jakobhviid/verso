// What sign-in decides from a server's address and from how https failed (ImmichClient.discover): whether plain http
// may be tried after https failed, which is only for a server on the local network, and never after a certificate's
// error. ARCHITECTURE.md, "Signing in".

import Foundation

enum ServerAddress {
    /// A certificate the system does not trust, or one it asks of the app: an https server is there, but not one to
    /// trust. A plain http server on the port fails otherwise (`secureConnectionFailed`).
    static func isCertificateError(_ error: Error) -> Bool {
        let code = (error as NSError).code
        return (error as NSError).domain == NSURLErrorDomain && [
            NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted,
            NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
            NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired,
        ].contains(code)
    }

    /// A host on the local network: a private or link-local address (and Tailscale's 100.64.0.0/10), this device, a
    /// name without a dot, or one under a suffix only local networks use.
    static func isLocalNetwork(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.contains(":") {
            // IPv6: this device, link-local fe80::/10, unique local fc00::/7.
            return host == "::1" || host.hasPrefix("fe8") || host.hasPrefix("fe9") || host.hasPrefix("fea")
                || host.hasPrefix("feb") || host.hasPrefix("fc") || host.hasPrefix("fd")
        }
        let octets = host.split(separator: ".").map { Int($0) }
        if octets.count == 4, octets.allSatisfy({ $0.map { (0...255).contains($0) } ?? false }) {
            let first = octets[0]!, second = octets[1]!
            return first == 10 || first == 127 || (first == 172 && (16...31).contains(second))
                || (first == 192 && second == 168) || (first == 169 && second == 254)
                || (first == 100 && (64...127).contains(second))
        }
        if !host.contains(".") { return true }
        return ["localhost", ".local", ".lan", ".home", ".home.arpa", ".internal", ".localdomain"]
            .contains { suffix in suffix.hasPrefix(".") ? host.hasSuffix(suffix) : host == suffix }
    }
}
