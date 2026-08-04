import XCTest
@testable import CLIProxyMenuBar

final class ExistingServerConfigurationTests: XCTestCase {
    func testNormalizesSupportedServerURLs() {
        XCTAssertEqual(
            ExistingServerConfiguration.normalizedURL(from: "  HTTP://127.0.0.1:8317/  ")?.absoluteString,
            "http://127.0.0.1:8317"
        )
        XCTAssertEqual(
            ExistingServerConfiguration.normalizedURL(from: "https://proxy.example.com/base")?.absoluteString,
            "https://proxy.example.com/base"
        )
    }

    func testRejectsIncompleteAndUnsupportedServerURLs() {
        XCTAssertNil(ExistingServerConfiguration.normalizedURL(from: "127.0.0.1:8317"))
        XCTAssertNil(ExistingServerConfiguration.normalizedURL(from: "ftp://proxy.example.com"))
        XCTAssertNil(ExistingServerConfiguration.normalizedURL(from: "https://"))
    }

    func testBuildsEndpointsFromTheServerOrigin() throws {
        let baseURL = try XCTUnwrap(
            ExistingServerConfiguration.normalizedURL(from: "https://proxy.example.com/base?old=true")
        )

        XCTAssertEqual(
            ExistingServerConfiguration.endpoint(path: "/v1/models", relativeTo: baseURL)?.absoluteString,
            "https://proxy.example.com/v1/models"
        )
    }
}
