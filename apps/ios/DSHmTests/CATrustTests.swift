import Foundation
import Security
import XCTest
@testable import DSHm

/// v0.1.1 C（CA 信任链）离线测试。
///
/// 夹具全部是 openssl 生成的**测试用**自签 CA / leaf 证书（只有公钥证书，无真实
/// 私钥、无生产凭据），因此可以安全提交：它们是公开材料，仅用于验证 `CATrust`
/// 的验链行为与旧凭据/载荷的向后兼容解码。
final class CATrustTests: XCTestCase {

    // MARK: - Fixtures (base64 DER, generated with openssl, public certs only)

    private enum Fixtures {
        /// Test CA, CN="DSH-m Test CA ca", 10 years.
        static let caCert = "MIIBmzCCAUGgAwIBAgIUdS59m+2kdKc3Ha7m99RH2ZbBmKQwCgYIKoZIzj0EAwIwGzEZMBcGA1UEAwwQRFNILW0gVGVzdCBDQSBjYTAeFw0yNjEwMjIwNTE3MDVaFw0zNjEwMTkwNTE3MDVaMBsxGTAXBgNVBAMMEERTSC1tIFRlc3QgQ0EgY2EwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAATCtEtrobWGZN8gl0EiNFJHlw/+Q0kV/JfEbcGPqXTv+lHKy+YkjUInuPKTPju/98kpwYFoLk3wIww2M67Dxd0Vo2MwYTAdBgNVHQ4EFgQUk+Zr1GraKJc6W4Ff1vO342twBBYwHwYDVR0jBBgwFoAUk+Zr1GraKJc6W4Ff1vO342twBBYwDwYDVR0TAQH/BAUwAwEB/zAOBgNVHQ8BAf8EBAMCAQYwCgYIKoZIzj0EAwIDSAAwRQIgB5C69Ww8JPoNV3J+JwzXe58GU1A4fpY0lbA5ZQ+n7j4CIQDwTdDghQlKbRHOBo4cfbl4VTKfe9+iV+mNx2gZf54vKg=="

        /// Leaf cert signed by `caCert`, CN="dsh-m test leaf leaf", SAN localhost/127.0.0.1.
        static let leafCert = "MIIByDCCAW+gAwIBAgIUDh6UHwcaDJL3YJgEKSseD/8DRcUwCgYIKoZIzj0EAwIwGzEZMBcGA1UEAwwQRFNILW0gVGVzdCBDQSBjYTAeFw0yNjEwMjIwNTE3MDVaFw0yNzEwMjIwNTE3MDVaMB8xHTAbBgNVBAMMFGRzaC1tIHRlc3QgbGVhZiBsZWFmMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE4D08UOI05voRfNa1AsQWE5eSupOFhT2ZkhxH0+ES73CugnuW6CU75/2ZN/VgLThz0GtKd5zCBilP9aHnhi6bZ6OBjDCBiTAJBgNVHRMEAjAAMAsGA1UdDwQEAwIFoDATBgNVHSUEDDAKBggrBgEFBQcDATAaBgNVHREEEzARgglsb2NhbGhvc3SHBH8AAAEwHQYDVR0OBBYEFJyZwbp/azVmlt8eKwbxTE0UGtqiMB8GA1UdIwQYMBaAFJPma9Rq2iiXOluBX9bzt+NrcAQWMAoGCCqGSM49BAMCA0cAMEQCICLemdZaB9Ip5EcCoXqakcAnnoIY6CVBadjde+WY2wf3AiBpub3oO1VyNAtxv5vgzyZoKTaLOrYxk0gAjw2iQD8YrA=="

        /// Unrelated test CA (must NOT validate `leafCert`).
        static let wrongCACert = "MIIBpjCCAUugAwIBAgIUC2MBf4NitM8O5ZHkguOhOoqZ828wCgYIKoZIzj0EAwIwIDEeMBwGA1UEAwwVRFNILW0gVGVzdCBDQSB3cm9uZ2NhMB4XDTI2MTAyMjA1MTcwNVoXDTM2MTAxOTA1MTcwNVowIDEeMBwGA1UEAwwVRFNILW0gVGVzdCBDQSB3cm9uZ2NhMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEbYYqthpC++hDZT7FErRJMebrle0PwTlAS3jqs8Xwa7vUtp34NRsByiAZ7YSFqssECA+rRgRoadvuWBO1TX+cXKNjMGEwHQYDVR0OBBYEFO5n4IHobFuJ71XYhOi03ApXGpGuMB8GA1UdIwQYMBaAFO5n4IHobFuJ71XYhOi03ApXGpGuMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMCA0kAMEYCIQCL2igJcbhWrHo5Pe6T/7iATmucY8bmlsZB0VcqL4AVMgIhAIVpVy41wNpvSEfER+alfIA9g74iuWTdVmLswwy28rVs"

        /// Leaf signed by `wrongCACert`.
        static let wrongLeafCert = "MIIB1DCCAXmgAwIBAgIUMXpUcBPwuEvxXdvtQYS63aXDcQgwCgYIKoZIzj0EAwIwIDEeMBwGA1UEAwwVRFNILW0gVGVzdCBDQSB3cm9uZ2NhMB4XDTI2MTAyMjA1MTcwNVoXDTI3MTAyMjA1MTcwNVowJDEiMCAGA1UEAwwZZHNoLW0gdGVzdCBsZWFmIHdyb25nbGVhZjBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABPkTrnMeCgXMRm8PxhQxjSg+hdOUIHAjMWScLHK19qiAIpzJL85D8d/QVnGU5qzW0q9uValh1rj7FK4k9WAtUvqjgYwwgYkwCQYDVR0TBAIwADALBgNVHQ8EBAMCBaAwEwYDVR0lBAwwCgYIKwYBBQUHAwEwGgYDVR0RBBMwEYIJbG9jYWxob3N0hwR/AAABMB0GA1UdDgQWBBSvE25YMvkImh36tPZAXBF26fOC9TAfBgNVHSMEGDAWgBTuZ+CB6Gxbie9V2ITotNwKVxqRrjAKBggqhkjOPQQDAgNJADBGAiEA3G3gi8H0jtfRIQaVZbXFoXXDNe7hgIo73nG5EpwcEisCIQCcTbqEDSIFu21mBTPDCREIpVC3tal+XHrXrZixySmmpQ=="

        /// Leaf issued by the correct CA but outside its validity window
        /// (2020-01-01 .. 2020-02-01).
        static let expiredLeafCert = "MIIBszCCAVigAwIBAgIUDh6UHwcaDJL3YJgEKSseD/8DRcYwCgYIKoZIzj0EAwIwGzEZMBcGA1UEAwwQRFNILW0gVGVzdCBDQSBjYTAeFw0yMDAxMDEwMDAwMDBaFw0yMDAyMDEwMDAwMDBaMB0xGzAZBgNVBAMMEmRzaC1tIGV4cGlyZWQgbGVhZjBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABNEpJEN+YzRMAB63p80rx+4rFshX2LZ5ctNXxplvFHTGe5N8E7THPXEGc7Hy8QCE0ds/ZmbIat8UsWvsSKHIljmjeDB2MAkGA1UdEwQCMAAwEwYDVR0lBAwwCgYIKwYBBQUHAwEwFAYDVR0RBA0wC4IJbG9jYWxob3N0MB0GA1UdDgQWBBTH09HD9VMKfwLaEKvH3izIrD80TDAfBgNVHSMEGDAWgBST5mvUatoolzpbgV/W87fja3AEFjAKBggqhkjOPQQDAgNJADBGAiEAw9ordBKiFx0Q60SJb05e1fhvQ+LNW5vEXKO5aQOWuEICIQCaof2htE83uguo7hpheDBP3FGaD9iUVutPY2rzQwidJw=="
    }

    private func certificate(_ base64: String) throws -> SecCertificate {
        try XCTUnwrap(CATrust.certificate(fromBase64: base64), "fixture certificate must decode")
    }

    // MARK: - Chain evaluation

    func testLeafChainingToPinnedCAAccepted() throws {
        let ca = try certificate(Fixtures.caCert)
        let leaf = try certificate(Fixtures.leafCert)
        XCTAssertTrue(CATrust.evaluate(chain: [leaf], anchor: ca))
    }

    func testWrongAnchorRejected() throws {
        let wrongCA = try certificate(Fixtures.wrongCACert)
        let leaf = try certificate(Fixtures.leafCert)
        XCTAssertFalse(CATrust.evaluate(chain: [leaf], anchor: wrongCA))
    }

    func testWrongChainRejected() throws {
        let ca = try certificate(Fixtures.caCert)
        let wrongLeaf = try certificate(Fixtures.wrongLeafCert)
        let wrongCA = try certificate(Fixtures.wrongCACert)
        XCTAssertFalse(CATrust.evaluate(chain: [wrongLeaf], anchor: ca))
        // Presenting the wrong CA alongside its leaf must not make it trusted by
        // the pinned CA (anchor-only evaluation).
        XCTAssertFalse(CATrust.evaluate(chain: [wrongLeaf, wrongCA], anchor: ca))
    }

    func testExpiredLeafRejected() throws {
        let ca = try certificate(Fixtures.caCert)
        let expired = try certificate(Fixtures.expiredLeafCert)
        XCTAssertFalse(CATrust.evaluate(chain: [expired], anchor: ca))
    }

    func testEmptyChainRejected() throws {
        XCTAssertFalse(CATrust.evaluate(chain: [], anchor: try certificate(Fixtures.caCert)))
    }

    func testCACertificateDecodingRejectsGarbage() {
        XCTAssertNil(CATrust.certificate(fromBase64: nil))
        XCTAssertNil(CATrust.certificate(fromBase64: ""))
        XCTAssertNil(CATrust.certificate(fromBase64: "not-base64!!"))
        XCTAssertNil(CATrust.certificate(fromBase64: Data("hello".utf8).base64EncodedString()))
    }

    // MARK: - Wire format / backward compatibility

    func testPairingPayloadParsesCACertFromTLSBlock() throws {
        let json = """
        {"v":1,"kind":"dsh-m.pair","tls":{"kind":"self-signed-ca","caPin":"ignored","caCert":"\(Fixtures.caCert)"}}
        """
        let payload = try XCTUnwrap(PairingPayload.parse(json))
        XCTAssertEqual(payload.tlsCACertBase64, Fixtures.caCert)
        XCTAssertNotNil(CATrust.certificate(fromBase64: payload.tlsCACertBase64))
    }

    func testPairingPayloadWithoutCACertStaysBackwardCompatible() throws {
        let json = #"{"v":1,"origins":["https://127.0.0.1:3466"],"tls":{"caPin":"x"}}"#
        let payload = try XCTUnwrap(PairingPayload.parse(json))
        XCTAssertNil(payload.tlsCACertBase64)
    }

    func testCredentialsDecodeLegacyJSONAndRoundTripCA() throws {
        let legacy = """
        {"origin":"https://127.0.0.1:3466","leafPin":"aa","deviceId":"dev","credential":"c",
         "deviceName":"phone","pairedAt":1}
        """
        let credentials = try JSONDecoder().decode(PairingCredentials.self, from: Data(legacy.utf8))
        XCTAssertNil(credentials.caCertBase64, "pre-C credentials must still decode")

        var upgraded = credentials
        upgraded.caCertBase64 = Fixtures.caCert
        let roundTrip = try JSONDecoder().decode(
            PairingCredentials.self,
            from: JSONEncoder().encode(upgraded)
        )
        XCTAssertEqual(roundTrip, upgraded)
    }

    func testRedeemResponseParsesCACert() {
        let json = TestJSON.value("""
        {"deviceId":"d1","credential":"c1","tls":{"caCert":"\(Fixtures.caCert)"}}
        """)
        let response = PairingCodeRedeemResponse.parse(json: json, observedLeafPin: nil)
        XCTAssertEqual(response?.tlsCACertBase64, Fixtures.caCert)
    }
}
