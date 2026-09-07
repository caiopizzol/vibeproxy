import Foundation

enum GrokLogin {
    static func prompt(in output: String) -> String? {
        let lines = output.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let codeLine = lines.dropLast().first(where: { $0.hasPrefix("Then enter this code: ") }),
              let urlLine = lines.first(where: { $0.hasPrefix("https://") }),
              let url = URL(string: urlLine),
              let host = url.host, host == "x.ai" || host.hasSuffix(".x.ai") else {
            return nil
        }
        let code = codeLine.replacingOccurrences(of: "Then enter this code: ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return nil }
        return "Open \(urlLine)\n\nEnter this code: \(code)\n\nWaiting for you to finish signing in."
    }

    static func start(
        _ process: Process,
        onPrompt: @escaping (String) -> Void,
        completion: @escaping (Bool, String) -> Void
    ) throws {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()

        DispatchQueue.global(qos: .userInitiated).async {
            var output = Data()
            var sentPrompt = false
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                output.append(chunk)
                if !sentPrompt, let prompt = prompt(in: String(decoding: output, as: UTF8.self)) {
                    sentPrompt = true
                    DispatchQueue.main.async { onPrompt(prompt) }
                }
            }
            process.waitUntilExit()
            let text = String(decoding: output, as: UTF8.self)
            // The backend also exits zero on login failure; only this final marker follows credential saving.
            let success = process.terminationReason == .exit && process.terminationStatus == 0
                && text.components(separatedBy: "\n").contains("xAI authentication successful!")
            let message = success ? "Grok Build connected." : text
            DispatchQueue.main.async { completion(success, message) }
        }
    }
}
