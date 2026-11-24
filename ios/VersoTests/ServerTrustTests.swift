// Logic tests of the certificate trusted for a server (mac/Verso/Verso/API/ServerTrust.swift; ARCHITECTURE.md, "A
// certificate of the server's own"): a fingerprint as people write it, the one a certificate has, and a certificate
// trusted for one server alone.

import XCTest

final class ServerTrustTests: XCTestCase {
    override func tearDown() {
        ServerTrust.forgetAll()
    }

    func testAFingerprintReadsAsPeopleWriteIt() {
        let pairs = (0..<32).map { String(format: "%02X", $0 * 7 % 256) }.joined(separator: ":")
        XCTAssertEqual(ServerTrust.normalized(pairs), pairs)
        XCTAssertEqual(ServerTrust.normalized(pairs.replacingOccurrences(of: ":", with: "").lowercased()), pairs)
        XCTAssertEqual(ServerTrust.normalized("sha256 Fingerprint=" + pairs + "\n"), pairs, "as openssl prints it")
        XCTAssertEqual(ServerTrust.normalized(pairs.replacingOccurrences(of: ":", with: " ")), pairs)
        XCTAssertNil(ServerTrust.normalized(String(pairs.dropLast(3))), "too short")
        XCTAssertNil(ServerTrust.normalized(pairs + ":00"), "too long")
        XCTAssertNil(ServerTrust.normalized("G" + pairs.dropFirst()), "not hexadecimal")
        XCTAssertNil(ServerTrust.normalized(""))
    }

    func testACertificatesFingerprintIsTheSHA256OfItsDER() {
        let fingerprint = ServerTrust.fingerprint(of: Data("a certificate".utf8))
        // `printf 'a certificate' | sha256sum`
        XCTAssertEqual(fingerprint, ServerTrust.normalized("81acd762140fa692a142822d2fbe4dc6f54bcaa501f68ab37e5aeed0bafe4d99"))
        XCTAssertTrue(fingerprint.hasPrefix("81:AC:D7:62"), fingerprint)
    }

    func testACertificateIsTrustedForOneServerAlone() {
        let fingerprint = ServerTrust.fingerprint(of: Data("a certificate".utf8))
        let server = URL(string: "https://photos.home.arpa/api")!
        ServerTrust.trust(fingerprint.lowercased(), for: server)
        XCTAssertEqual(ServerTrust.certificate(for: server), fingerprint)
        XCTAssertEqual(ServerTrust.certificate(for: URL(string: "https://PHOTOS.home.arpa:443/api/assets/1")!), fingerprint,
                       "the same server, whatever the path")
        XCTAssertNil(ServerTrust.certificate(for: URL(string: "https://photos.home.arpa:8443/api")!), "another port")
        XCTAssertNil(ServerTrust.certificate(for: URL(string: "https://other.home.arpa/api")!), "another server")
        ServerTrust.trust("not a fingerprint", for: server)
        XCTAssertNil(ServerTrust.certificate(for: server), "only a fingerprint is trusted")
        ServerTrust.trust(fingerprint, for: server)
        ServerTrust.trust(nil, for: server)
        XCTAssertNil(ServerTrust.certificate(for: server), "forgotten")
    }

    func testARefusedCertificateIsTold() {
        XCTAssertTrue(ServerTrust.isRefusal(URLError(.serverCertificateUntrusted)))
        XCTAssertTrue(ServerTrust.isRefusal(URLError(.serverCertificateHasUnknownRoot)))
        XCTAssertFalse(ServerTrust.isRefusal(URLError(.cannotConnectToHost)))
        XCTAssertNil(ServerTrust.refused(in: URLError(.serverCertificateUntrusted)), "no certificate in it to ask about")
    }
}
