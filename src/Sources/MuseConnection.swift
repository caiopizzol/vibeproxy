import Foundation

enum MuseConnection {
    static func importLogin(authDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cli-proxy-api")) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "ai.meta.dev.credentials", "-a", "meta", "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let secret = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = secret["access_token"] as? String, !token.isEmpty else {
            throw ConnectionError.loginRequired
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let metadataURL = home.appendingPathComponent(".config/muse/auth.json")
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any]
        let providers = metadata?["providers"] as? [String: Any]
        let meta = providers?["meta"] as? [String: Any]
        var credential: [String: Any] = ["type": "muse", "access_token": token]
        credential["email"] = meta?["user_email"] as? String
        let directory = authDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("muse.json")
        let encoded = try JSONSerialization.data(withJSONObject: credential, options: [.sortedKeys])
        // Protect the temporary file before the atomic replacement, including on synced folders.
        let temporary = directory.appendingPathComponent(".muse-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: encoded,
                                            attributes: [.posixPermissions: 0o600]) else {
            throw ConnectionError.saveFailed
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        NotificationCenter.default.post(name: .authDirectoryChanged, object: nil)
    }

    enum ConnectionError: LocalizedError {
        case loginRequired, saveFailed
        var errorDescription: String? {
            switch self {
            case .loginRequired: return "Sign in with `muse login` first, then connect Muse again."
            case .saveFailed: return "Could not save the Muse account."
            }
        }
    }
}
