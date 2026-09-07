import Foundation

@main
struct GrokQuotaSpec {
    static func main() async throws {
        let now = Date()
        let fixture = Data(#"{"config":{"isUnifiedBillingUser":true,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2026-09-09T05:59:18.784546+00:00"},"creditUsagePercent":17,"productUsage":[{"product":"GrokBuild","usagePercent":12}]}}"#.utf8)
        let snapshot = try GrokQuotaDecoder.decode(fixture, fetchedAt: now)
        precondition(snapshot.provider == .xai)
        precondition(snapshot.window(.weekly)?.remainingPercent == 83)
        precondition(snapshot.window(.weekly)?.resetsAt != nil)
        precondition(snapshot.window(.fiveHour) == nil)
        precondition(snapshot.window(.fable) == nil)
        precondition(snapshot.fetchedAt == now)

        for replacement in ["null", "true", "-1", "\"17\""] {
            let malformed = String(decoding: fixture, as: UTF8.self)
                .replacingOccurrences(of: "\"creditUsagePercent\":17", with: "\"creditUsagePercent\":\(replacement)")
            do {
                _ = try GrokQuotaDecoder.decode(Data(malformed.utf8), fetchedAt: now)
                preconditionFailure("Invalid percentage accepted")
            } catch {}
        }
        let separateBilling = String(decoding: fixture, as: UTF8.self)
            .replacingOccurrences(of: "\"isUnifiedBillingUser\":true", with: "\"isUnifiedBillingUser\":false")
        do {
            _ = try GrokQuotaDecoder.decode(Data(separateBilling.utf8), fetchedAt: now)
            preconditionFailure("Unverified billing format accepted")
        } catch {}
        let unknownPeriod = String(decoding: fixture, as: UTF8.self)
            .replacingOccurrences(of: "USAGE_PERIOD_TYPE_WEEKLY", with: "USAGE_PERIOD_TYPE_MONTHLY")
        do {
            _ = try GrokQuotaDecoder.decode(Data(unknownPeriod.utf8), fetchedAt: now)
            preconditionFailure("Unknown period labeled weekly")
        } catch {}

        let auth = try JSONDecoder().decode(ProxyAuthFile.self, from: Data(#"{"auth_index":"test","name":"xai-test.json","provider":"xai"}"#.utf8))
        let client = CLIProxyManagementClient(
            baseURL: URL(string: "http://127.0.0.1:8318")!, managementSecret: "fixture",
            transport: FixtureTransport(body: fixture)
        )
        let proxied = try await client.fetchQuota(for: auth, provider: .xai)
        precondition(proxied.window(.weekly)?.remainingPercent == 83)
        print("PASS: Grok weekly credits, invalid payloads, reset timestamp, and management request")

        if CommandLine.arguments.contains("--live") {
            let defaults = UserDefaults(suiteName: "com.vibeproxy.app")!
            guard defaults.bool(forKey: ExistingServerConfiguration.enabledKey),
                  let base = ExistingServerConfiguration.normalizedURL(from:
                    defaults.string(forKey: ExistingServerConfiguration.urlKey) ?? ExistingServerConfiguration.defaultURL) else {
                fatalError("No existing server configured")
            }
            let liveClient = CLIProxyManagementClient(baseURL: base, managementSecret: ExistingServerPasswordStore.load())
            let files = try await liveClient.fetchAuthFiles()
            guard let grok = files.first(where: { $0.provider == "xai" }) else {
                fatalError("Connected server has no Grok account")
            }
            let result = try await liveClient.fetchQuota(for: grok, provider: .xai)
            guard let weekly = result.window(.weekly) else { fatalError("Weekly quota missing") }
            print("PASS: configured server reports Grok weekly remaining \(weekly.remainingPercent)%")
        }
    }
}

private struct FixtureTransport: QuotaManagementTransport {
    let body: Data

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        precondition(request.url?.path == "/v0/management/api-call")
        precondition(request.httpMethod == "POST")
        let payload = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        precondition(payload["url"] as? String == "https://cli-chat-proxy.grok.com/v1/billing?format=credits")
        precondition(payload["method"] as? String == "GET")
        precondition((payload["header"] as? [String: String])?["Authorization"] == "Bearer $TOKEN$")
        let wrapper = try JSONSerialization.data(withJSONObject: [
            "status_code": 200, "body": String(decoding: body, as: UTF8.self)
        ])
        return (wrapper, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
