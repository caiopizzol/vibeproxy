import CryptoKit
import Foundation

struct MuseQuotaCache: Sendable {
    private static let lock = NSLock()
    let directory: URL

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.vibeproxy.app/MuseUsage")) {
        self.directory = directory
    }

    func load(server: URL, account: ProxyAuthFile) -> QuotaSnapshot? {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard let data = try? Data(contentsOf: file(server: server, account: account)),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              let snapshot = try? MuseQuotaDecoder.decode(record.usage, fetchedAt: record.fetchedAt) else {
            return nil
        }
        return QuotaSnapshot(provider: .muse, windows: snapshot.windows, fetchedAt: snapshot.fetchedAt, isStale: true)
    }

    func save(_ snapshot: QuotaSnapshot, server: URL, account: ProxyAuthFile) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard snapshot.provider == .muse, !snapshot.isStale,
              let window = snapshot.window(.fiveHour), let weekly = snapshot.window(.weekly),
              let windowReset = window.resetsAt, let weeklyReset = weekly.resetsAt else { return }
        if let data = try? Data(contentsOf: file(server: server, account: account)),
           let existing = try? JSONDecoder().decode(Record.self, from: data),
           existing.fetchedAt > snapshot.fetchedAt { return }
        let payload: [String: Any] = ["is_subs_active": true, "subs_usage": [
            "window": ["used_percent": 100 - window.remainingPercent, "window_duration_mins": 300,
                       "resets_at": windowReset.timeIntervalSince1970],
            "weekly": ["used_percent": 100 - weekly.remainingPercent, "resets_at": weeklyReset.timeIntervalSince1970]
        ]]
        guard let usage = try? JSONSerialization.data(withJSONObject: payload),
              let data = try? JSONEncoder().encode(Record(usage: usage, fetchedAt: snapshot.fetchedAt)) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: file(server: server, account: account), options: .atomic)
        } catch {
            // A cache write failure must not hide a successful live quota response.
        }
    }

    private func file(server: URL, account: ProxyAuthFile) -> URL {
        var origin = URLComponents(url: server, resolvingAgainstBaseURL: true)
        origin?.path = ""
        origin?.query = nil
        origin?.fragment = nil
        let identity = [origin?.string ?? server.absoluteString, account.authIndex, account.name, account.email ?? ""].joined(separator: "\n")
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }

    private struct Record: Codable {
        let usage: Data
        let fetchedAt: Date
    }
}
