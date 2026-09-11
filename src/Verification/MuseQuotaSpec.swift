import Foundation

@main
struct MuseQuotaSpec {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = MuseQuotaCache(directory: directory)
        let fixture = Data(#"{"is_subs_active":true,"subs_usage":{"window":{"used_percent":7,"window_duration_mins":300,"resets_at":1788798500},"weekly":{"used_percent":2,"resets_at":1789344000}}}"#.utf8)
        let snapshot = try MuseQuotaDecoder.decode(fixture, fetchedAt: Date())
        precondition(snapshot.window(.fiveHour)?.remainingPercent == 93)
        precondition(snapshot.window(.weekly)?.remainingPercent == 98)
        precondition(snapshot.window(.weekly)?.resetsAt == Date(timeIntervalSince1970: 1789344000))
        for (before, after) in [("300", "60"), ("\"used_percent\":7", "\"used_percent\":true"), ("\"used_percent\":7", "\"used_percent\":-1"), ("\"is_subs_active\":true", "\"is_subs_active\":false")] {
            let malformed = String(decoding: fixture, as: UTF8.self).replacingOccurrences(of: before, with: after)
            do {
                _ = try MuseQuotaDecoder.decode(Data(malformed.utf8), fetchedAt: Date())
                preconditionFailure("Invalid quota accepted")
            } catch {}
        }
        let auth = try JSONDecoder().decode(ProxyAuthFile.self, from: Data(#"{"auth_index":"test","name":"muse.json","provider":"muse"}"#.utf8))
        let client = CLIProxyManagementClient(baseURL: URL(string: "http://127.0.0.1:8317")!, managementSecret: "test", transport: FixtureTransport(body: fixture), museCache: cache)
        let quota = try await client.fetchQuota(for: auth, provider: .muse)
        precondition(quota.window(.weekly)?.remainingPercent == 98)
        let timestamp = quota.fetchedAt
        let missing = Data(#"{"is_subs_active":true}"#.utf8)
        func missingClient(server: String = "http://127.0.0.1:8317", body: Data = missing, status: Int = 200) -> CLIProxyManagementClient {
            CLIProxyManagementClient(baseURL: URL(string: server)!, managementSecret: "test",
                                     transport: FixtureTransport(body: body, status: status),
                                     museCache: MuseQuotaCache(directory: directory))
        }
        let restored = try await missingClient().fetchQuota(for: auth, provider: .muse)
        precondition(restored.isStale && restored.fetchedAt == timestamp)
        precondition(restored.window(.weekly)?.remainingPercent == 98)
        let saved = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let serialized = try String(contentsOf: saved[0], encoding: .utf8)
        precondition(!serialized.contains("api_key") && !serialized.contains("access_token"))
        for (body, expected) in [(Data(#"{"is_subs_active":true,"subs_usage":null}"#.utf8), QuotaFailure.usageNotReported),
                                 (Data(#"{"is_subs_active":true,"subs_usage":{}}"#.utf8), .invalidResponse),
                                 (Data(#"{"is_subs_active":false}"#.utf8), .invalidResponse)] {
            do {
                _ = try MuseQuotaDecoder.decode(body, fetchedAt: Date())
                preconditionFailure("Unexpected successful decode")
            } catch { precondition(error as? QuotaFailure == expected) }
        }
        do {
            _ = try await missingClient(server: "http://127.0.0.1:9999").fetchQuota(for: auth, provider: .muse)
            preconditionFailure("Cross-server cache reuse")
        } catch { precondition(error as? QuotaFailure == .usageNotReported) }
        let otherAccount = try JSONDecoder().decode(ProxyAuthFile.self, from: Data(#"{"auth_index":"test","name":"muse.json","provider":"muse","email":"other@example.com"}"#.utf8))
        do {
            _ = try await missingClient().fetchQuota(for: otherAccount, provider: .muse)
            preconditionFailure("Cross-account cache reuse")
        } catch { precondition(error as? QuotaFailure == .usageNotReported) }
        for (body, status, expected) in [(missing, 401, QuotaFailure.providerAuthenticationFailed),
                                         (Data(#"{"is_subs_active":true,"subs_usage":{}}"#.utf8), 200, .invalidResponse)] {
            do {
                _ = try await missingClient(body: body, status: status).fetchQuota(for: auth, provider: .muse)
                preconditionFailure("Cache hid an error")
            } catch { precondition(error as? QuotaFailure == expected) }
        }
        let recovered = try await client.fetchQuota(for: auth, provider: .muse)
        precondition(!recovered.isStale && recovered.fetchedAt >= timestamp)
        cache.save(QuotaSnapshot(provider: .muse, windows: quota.windows, fetchedAt: timestamp.addingTimeInterval(-100)),
                   server: URL(string: "http://127.0.0.1:8317")!, account: auth)
        precondition(cache.load(server: URL(string: "http://127.0.0.1:8317/")!, account: auth)?.fetchedAt == recovered.fetchedAt)
        try Data("corrupt".utf8).write(to: saved[0])
        do {
            _ = try await missingClient().fetchQuota(for: auth, provider: .muse)
            preconditionFailure("Corrupt cache accepted")
        } catch { precondition(error as? QuotaFailure == .usageNotReported) }
        print("PASS: persisted last-known usage, original timestamp, server/account isolation, malformed/auth responses and corrupt cache")
        print("PASS: Muse quota windows, validation, reset timestamps, management request")
        if CommandLine.arguments.contains("--live") {
            let client = CLIProxyManagementClient(baseURL: URL(string: "http://127.0.0.1:8317")!, managementSecret: ExistingServerPasswordStore.load())
            let accounts = try await client.fetchAuthFiles()
            guard let muse = accounts.first(where: { $0.provider == "muse" }) else { fatalError("Muse account missing on configured server") }
            let quota = try await client.fetchQuota(for: muse, provider: .muse)
            print("PASS: configured server reports Muse remaining: five-hour \(quota.window(.fiveHour)!.remainingPercent)%, weekly \(quota.window(.weekly)!.remainingPercent)%")
        }
    }
}
private struct FixtureTransport: QuotaManagementTransport {
    let body: Data
    var status: Int = 200
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let payload = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        precondition(payload["method"] as? String == "POST")
        precondition(payload["url"] as? String == "https://api.meta.ai/muse-code/key")
        precondition((payload["header"] as? [String: String])?["Authorization"] == "Bearer $TOKEN$")
        let wrapper = try JSONSerialization.data(withJSONObject: ["status_code": status, "body": String(decoding: body, as: UTF8.self)])
        return (wrapper, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
