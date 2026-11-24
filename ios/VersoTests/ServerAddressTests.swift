// Logic tests of which server addresses sign-in may try over plain http after https failed
// (mac/Verso/Verso/API/ServerAddress.swift): a server on the local network, never after a certificate's error.

import XCTest

final class ServerAddressTests: XCTestCase {
    func testTheLocalNetwork() {
        for host in ["192.168.1.20", "10.0.0.5", "172.16.4.1", "172.31.255.1", "127.0.0.1", "169.254.10.10",
                     "100.101.102.103", "[::1]", "fe80::1", "fd12:3456::1", "nas", "immich.local", "photos.lan",
                     "server.home.arpa", "immich.internal", "localhost"] {
            XCTAssertTrue(ServerAddress.isLocalNetwork(host), host)
        }
        for host in ["photos.example.com", "8.8.8.8", "172.32.0.1", "192.169.1.1", "100.128.0.1", "2001:db8::1",
                     "immich.local.example.com", "my.home.example"] {
            XCTAssertFalse(ServerAddress.isLocalNetwork(host), host)
        }
    }

    func testCertificateErrors() {
        XCTAssertTrue(ServerAddress.isCertificateError(URLError(.serverCertificateUntrusted)))
        XCTAssertTrue(ServerAddress.isCertificateError(URLError(.serverCertificateHasUnknownRoot)))
        XCTAssertFalse(ServerAddress.isCertificateError(URLError(.secureConnectionFailed)),
                       "a plain http server on the port: http may follow on the local network")
        XCTAssertFalse(ServerAddress.isCertificateError(URLError(.cannotConnectToHost)))
    }
}
