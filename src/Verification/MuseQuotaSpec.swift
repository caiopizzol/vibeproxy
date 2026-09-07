import Foundation

@main
struct MuseQuotaSpec {
    static func main() async throws {
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
        let client = CLIProxyManagementClient(baseURL: URL(string: "http://127.0.0.1:8317")!, managementSecret: "test", transport: FixtureTransport(body: fixture))
        let quota = try await client.fetchQuota(for: auth, provider: .muse)
        precondition(quota.window(.weekly)?.remainingPercent == 98)
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
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let payload = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        precondition(payload["method"] as? String == "POST")
        precondition(payload["url"] as? String == "https://api.meta.ai/muse-code/key")
        precondition((payload["header"] as? [String: String])?["Authorization"] == "Bearer $TOKEN$")
        let wrapper = try JSONSerialization.data(withJSONObject: ["status_code": 200, "body": String(decoding: body, as: UTF8.self)])
        return (wrapper, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
