import Foundation

enum MuseQuotaDecoder {
    static func decode(_ data: Data, fetchedAt: Date) throws -> QuotaSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["is_subs_active"] as? Bool == true,
              let usage = root["subs_usage"] as? [String: Any] else {
            throw QuotaFailure.invalidResponse
        }
        let windows = try [("window", QuotaWindowKind.fiveHour), ("weekly", .weekly)].map { key, kind in
            guard let window = usage[key] as? [String: Any],
                  let used = QuotaDateParser.number(window["used_percent"]), used.isFinite, used >= 0,
                  let reset = QuotaDateParser.number(window["resets_at"]), reset.isFinite, reset > 0,
                  kind != .fiveHour || QuotaDateParser.number(window["window_duration_mins"]) == 300 else {
                throw QuotaFailure.invalidResponse
            }
            return QuotaWindow(kind: kind, usedPercent: used, resetsAt: Date(timeIntervalSince1970: reset))
        }
        return QuotaSnapshot(provider: .muse, windows: windows, fetchedAt: fetchedAt)
    }
}
