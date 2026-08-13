import Foundation

/// Captures an authentication subprocess stream and reports its login URL once.
///
/// The CLI owns the OAuth state and PKCE challenge, so VibeProxy must copy the URL
/// emitted by that exact process instead of trying to rebuild an equivalent URL.
final class AuthenticationOutputCapture {
    private static let loginURLExpression = try! NSRegularExpression(
        pattern: #"(?:Attempting to open URL in browser:|Visit the following URL to continue authentication:)\s*(https?://[^\r\n]+)\r?\n"#,
        options: [.caseInsensitive]
    )

    private let lock = NSLock()
    private var capturedText = ""
    private var capturedLoginURL: String?

    var text: String {
        lock.withLock { capturedText }
    }

    var loginURL: String? {
        lock.withLock { capturedLoginURL }
    }

    /// Returns the login URL only when it is first discovered.
    func append(_ chunk: String) -> String? {
        lock.withLock {
            capturedText += chunk
            guard capturedLoginURL == nil else { return nil }

            let range = NSRange(capturedText.startIndex..., in: capturedText)
            guard let match = Self.loginURLExpression.firstMatch(in: capturedText, range: range),
                  let urlRange = Range(match.range(at: 1), in: capturedText) else {
                return nil
            }

            let loginURL = String(capturedText[urlRange])
            capturedLoginURL = loginURL
            return loginURL
        }
    }
}
