import Foundation

@main
struct GrokLoginSpec {
    static func main() throws {
        let prefix = "Starting xAI authentication...\nhttps://accounts.x.ai/device\nThen enter this code: ABCD"
        if CommandLine.arguments.count == 2 {
            let actualOutput = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
            precondition(GrokLogin.prompt(in: actualOutput) != nil)
        }
        precondition(GrokLogin.prompt(in: prefix) == nil)
        precondition(GrokLogin.prompt(in: prefix + "-1234\n")?.contains("ABCD-1234") == true)
        precondition(GrokLogin.prompt(in: "https://x.ai.example.com/device\nThen enter this code: ABCD-1234\n") == nil)

        try login("printf 'https://accounts.x.ai/device\nThen enter this code: ABCD-1234\n'; printf 'Authorization denied\n' >&2; exit 1", succeeds: false, showsPrompt: true)
        try login("printf 'xAI authentication successful\nxAI authentication failed: could not save credentials\n'", succeeds: false)
        try login("printf 'xAI authentication successful!\n'", succeeds: true)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("xai-test.json")
        try Data(#"{"type":"xai","email":"test@example.com","expired":"2099-01-01T00:00:00Z"}"#.utf8).write(to: file)
        let auth = AuthManager(authDirectory: directory)
        auth.checkAuthStatus()
        wait { auth.accounts(for: .xai).count == 1 }
        precondition(auth.accounts(for: .xai).first?.email == "test@example.com")
        precondition(auth.accounts(for: .xai).first?.isExpired == false)
        precondition(ProviderCatalog.oauthProviderKeys["xai"] == "xai")
        precondition(ProviderCatalog.reservedCustomProviderKeys.contains("xai"))
        let root = ConfigComposer.composeRuntimeConfig(
            baseRoot: [:], reservedCustomProviderKeys: ProviderCatalog.reservedCustomProviderKeys,
            disabledCustomProviderIDs: [], disabledOAuthProviderKeys: ["xai"],
            zaiAPIKeys: [], customProviderAuthRecords: [], includeManagedZAIProvider: false
        )
        precondition(ConfigComposer.isOAuthProviderWildcardExcluded("xai", in: root))
        print("PASS: Grok login, account detection, and provider controls")
    }

    static func login(_ script: String, succeeds: Bool, showsPrompt: Bool = false) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        var finished = false
        var promptCount = 0
        try GrokLogin.start(process, onPrompt: { message in
            precondition(Thread.isMainThread)
            precondition(message.contains("ABCD-1234"))
            promptCount += 1
        }, completion: { success, _ in
            precondition(Thread.isMainThread)
            precondition(success == succeeds)
            precondition(promptCount == (showsPrompt ? 1 : 0))
            finished = true
        })
        wait { finished }
    }

    static func wait(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(condition(), "Verification timed out")
    }
}
