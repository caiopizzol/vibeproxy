enum ServiceConnectionAction: Equatable {
    case authCommand(AuthCommand)
    case importMuseLogin
    case promptForQwenEmail
    case promptForZAIAPIKey
}

extension ServiceType {
    var connectionAction: ServiceConnectionAction {
        switch self {
        case .claude:
            return .authCommand(.claudeLogin)
        case .codex:
            return .authCommand(.codexLogin)
        case .copilot:
            return .authCommand(.copilotLogin)
        case .gemini:
            return .authCommand(.geminiLogin)
        case .kimi:
            return .authCommand(.kimiLogin)
        case .muse:
            return .importMuseLogin
        case .xai:
            return .authCommand(.xaiLogin)
        case .qwen:
            return .promptForQwenEmail
        case .antigravity:
            return .authCommand(.antigravityLogin)
        case .zai:
            return .promptForZAIAPIKey
        }
    }
}
