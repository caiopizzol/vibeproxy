import Foundation

enum GrokQuotaDecoder {
    static func decode(_ data: Data, fetchedAt: Date) throws -> QuotaSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = root["config"] as? [String: Any],
              config["isUnifiedBillingUser"] as? Bool == true,
              let period = config["currentPeriod"] as? [String: Any],
              period["type"] as? String == "USAGE_PERIOD_TYPE_WEEKLY",
              let used = QuotaDateParser.number(config["creditUsagePercent"]),
              used.isFinite, used >= 0,
              let end = period["end"] as? String else {
            throw QuotaFailure.invalidResponse
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let reset = formatter.date(from: end) ?? QuotaDateParser.iso8601(end) else {
            throw QuotaFailure.invalidResponse
        }
        return QuotaSnapshot(
            provider: .xai,
            windows: [QuotaWindow(kind: .weekly, usedPercent: used, resetsAt: reset)],
            fetchedAt: fetchedAt
        )
    }
}
