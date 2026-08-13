import XCTest
@testable import CLIProxyMenuBar

final class AuthenticationOutputCaptureTests: XCTestCase {
    func testCapturesExactLoginURLFromBrowserLaunchOutput() {
        let capture = AuthenticationOutputCapture()
        let loginURL = "https://auth.openai.com/oauth/authorize?client_id=app_123&state=state_456&code_challenge=challenge_789"

        let discoveredURL = capture.append("Attempting to open URL in browser: \(loginURL)\n")

        XCTAssertEqual(discoveredURL, loginURL)
        XCTAssertEqual(capture.loginURL, loginURL)
    }

    func testCapturesLoginURLSplitAcrossPipeReads() {
        let capture = AuthenticationOutputCapture()

        XCTAssertNil(capture.append("Attempting to open URL in browser: https://auth.openai.com/oauth/"))
        let discoveredURL = capture.append("authorize?state=state_456\nWaiting for callback...\n")

        XCTAssertEqual(
            discoveredURL,
            "https://auth.openai.com/oauth/authorize?state=state_456"
        )
    }

    func testCapturesLoginURLFromNoBrowserFallbackOutput() {
        let capture = AuthenticationOutputCapture()
        let loginURL = "https://auth.openai.com/oauth/authorize?state=state_456"

        let discoveredURL = capture.append(
            "Visit the following URL to continue authentication:\r\n\(loginURL)\r\n"
        )

        XCTAssertEqual(discoveredURL, loginURL)
    }

    func testReportsLoginURLOnlyOnce() {
        let capture = AuthenticationOutputCapture()
        let loginURL = "https://auth.openai.com/oauth/authorize?state=state_456"

        XCTAssertEqual(
            capture.append("Attempting to open URL in browser: \(loginURL)\n"),
            loginURL
        )
        XCTAssertNil(capture.append("Visit the following URL to continue authentication:\n\(loginURL)\n"))
    }

    func testIgnoresUnrelatedURLs() {
        let capture = AuthenticationOutputCapture()

        XCTAssertNil(capture.append("OAuth callback listening at http://localhost:1455/auth/callback\n"))
        XCTAssertNil(capture.loginURL)
    }
}
