import XCTest
@testable import AonsokuNativePlugin

final class AuthenticationTests: XCTestCase {
    func testTokenAndEncodedPasswordMatchSubsonicContract() {
        XCTAssertEqual(
            SubsonicAuthBuilder.generateToken(password: "secret"),
            "8dcfd84619d18f19ce00d449bc1f9611"
        )
        XCTAssertEqual(
            SubsonicAuthBuilder.encodePassword(password: "secret"),
            "enc:736563726574"
        )
    }

    func testTokenAuthenticationUsesTokenAndSaltWithoutPassword() {
        let params = SubsonicAuthBuilder.buildQueryParams(
            username: "alice",
            password: "token-value",
            authType: "token",
            protocolVersion: "1.16.1"
        )

        XCTAssertEqual(params["u"], "alice")
        XCTAssertEqual(params["v"], "1.16.1")
        XCTAssertEqual(params["c"], "Aonsoku")
        XCTAssertEqual(params["f"], "json")
        XCTAssertEqual(params["t"], "token-value")
        XCTAssertEqual(params["s"], SubsonicAuthBuilder.salt)
        XCTAssertNil(params["p"])
    }

    func testPasswordAuthenticationUsesOnlyPasswordField() {
        let params = SubsonicAuthBuilder.buildQueryParams(
            username: "alice",
            password: "enc:736563726574",
            authType: "password",
            protocolVersion: nil
        )

        XCTAssertEqual(params["p"], "enc:736563726574")
        XCTAssertNil(params["t"])
        XCTAssertNil(params["s"])
        XCTAssertEqual(params["v"], SubsonicAuthBuilder.defaultVersion)
    }

    func testVersionNumberParsingMatchesCrossPlatformComparison() {
        XCTAssertEqual(SubsonicAuthBuilder.parseVersionNumber("1.16.2"), 11_602)
        XCTAssertEqual(SubsonicAuthBuilder.parseVersionNumber("1"), 0)
        XCTAssertGreaterThan(
            SubsonicAuthBuilder.parseVersionNumber("2.0.0"),
            SubsonicAuthBuilder.parseVersionNumber("1.16.0")
        )
    }
}
