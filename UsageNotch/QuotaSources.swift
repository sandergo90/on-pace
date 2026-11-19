import Foundation

enum QuotaSources {
    static func read(_ provider: Provider) -> Result<UsageReading, UsageFailure> {
        do {
            let (windows, plan) = switch provider {
            case .claude: try claudeQuota()
            case .codex: try codexQuota()
            }
            guard let reading = UsageReading(windows: windows, plan: plan) else { return .failure(.unavailable) }
            return .success(reading)
        } catch let failure as UsageFailure {
            return .failure(failure)
        } catch {
            return .failure(.unavailable)
        }
    }

    // A control request to the installed CLI. No prompt, session, or credentials of our own.
    private static func claudeQuota() throws -> ([QuotaWindow], String?) {
        let arguments = [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json",
            "--verbose", "--no-session-persistence", "--strict-mcp-config",
            "--setting-sources", "", "--settings", #"{"disableAllHooks":true}"#
        ]
        let response: ClaudeEnvelope = try CLIConnection.run(.claude, arguments: arguments) { cli in
            try cli.send(#"{"type":"control_request","request_id":"usage-notch","request":{"subtype":"get_usage","skip_behaviors":true}}"#)
            return try cli.receive {
                $0["type"] as? String == "control_response" &&
                    ($0["response"] as? [String: Any])?["request_id"] as? String == "usage-notch"
            }
        }
        guard response.response.subtype == "success",
              let payload = response.response.response else { throw UsageFailure.unavailable }
        if payload.rateLimitsAvailable == false {
            let status: ClaudeAuthStatus = try CLIConnection.run(.claude, arguments: ["auth", "status", "--json"]) {
                try $0.readDocument()
            }
            throw status.loggedIn ? UsageFailure.noQuota : UsageFailure.signInRequired
        }
        guard let limits = payload.rateLimits else { throw UsageFailure.unavailable }
        let windows = [
            limits.fiveHour?.window(id: "session", title: "5-hour session", durationMinutes: 300),
            limits.sevenDay?.window(id: "week", title: "Weekly · all models", durationMinutes: 10_080),
            limits.sevenDayOpus?.window(id: "opus", title: "Weekly · Opus", durationMinutes: 10_080),
            limits.sevenDaySonnet?.window(id: "sonnet", title: "Weekly · Sonnet", durationMinutes: 10_080)
        ].compactMap { $0 }
        let plan = switch payload.rateLimitTier {
        case "default_claude_max_20x": "Max 20×"
        case "default_claude_max_5x": "Max 5×"
        default: planName(payload.subscriptionType)
        }
        return (windows, plan)
    }

    private static func codexQuota() throws -> ([QuotaWindow], String?) {
        try CLIConnection.run(.codex, arguments: ["app-server", "--listen", "stdio://"]) { cli in
            try cli.send(#"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"usage_notch","version":"0.1.0"}}}"#)
            let initialized: RPCResponse<EmptyResult> = try cli.receive { $0["id"] as? Int == 1 }
            guard initialized.result != nil else { throw UsageFailure.unavailable }
            try cli.send(#"{"method":"initialized"}"#)
            try cli.send(#"{"id":2,"method":"account/rateLimits/read"}"#)
            let response: RPCResponse<CodexLimits> = try cli.receive { $0["id"] as? Int == 2 }
            guard let limits = response.result else {
                try cli.send(#"{"id":3,"method":"account/read","params":{"refreshToken":false}}"#)
                let auth: RPCResponse<CodexAccount> = try cli.receive { $0["id"] as? Int == 3 }
                if let account = auth.result {
                    if account.type == "apiKey" || account.type == "amazonBedrock" { throw UsageFailure.noQuota }
                    if account.type == nil, account.requiresOpenaiAuth == true {
                        throw UsageFailure.signInRequired
                    }
                }
                throw UsageFailure.unavailable
            }
            let bucket = limits.rateLimitsByLimitId?["codex"] ?? limits.rateLimits
            let primary = bucket.primary?.window(id: "primary", fallbackTitle: "Usage limit")
            let secondary = bucket.secondary?.window(id: "secondary", fallbackTitle: "Usage limit")
            let cloud = limits.rateLimitsByLimitId?.sorted { $0.key < $1.key }.first {
                $0.key.lowercased().contains("cloud") || $0.value.limitName?.lowercased().contains("cloud tasks") == true
            }?.value
            let reportedCloudWindow = cloud?.secondary ?? cloud?.primary
            let cloudWindow = reportedCloudWindow?.window(
                id: "cloud", fallbackTitle: "Cloud tasks",
                titleOverride: reportedCloudWindow?.windowDurationMins == 10080 ? "Cloud tasks · week" : "Cloud tasks"
            )
            return ([primary, secondary, cloudWindow].compactMap { $0 },
                    planName(bucket.planType ?? limits.rateLimits.planType))
        }
    }
    private static func planName(_ raw: String?) -> String? {
        switch raw?.lowercased() {
        case "free": "Free"
        case "plus": "Plus"
        case "prolite": "Pro Lite"
        case "pro": "Pro"
        case "max": "Max"
        case "ultra": "Ultra"
        case "team": "Team"
        case "business", "self_serve_business_prolite", "self_serve_business_usage_based": "Business"
        case "enterprise": "Enterprise"
        case "edu": "Edu"
        default: nil
        }
    }
}

private struct ClaudeEnvelope: Decodable {
    struct Response: Decodable {
        struct Payload: Decodable {
            let rateLimitsAvailable: Bool?
            let rateLimits: Limits?
            let subscriptionType: String?
            let rateLimitTier: String?

            enum CodingKeys: String, CodingKey {
                case rateLimitsAvailable = "rate_limits_available"
                case rateLimits = "rate_limits"
                case subscriptionType = "subscription_type"
                case rateLimitTier = "rate_limit_tier"
            }
        }
        struct Limits: Decodable {
            struct Window: Decodable {
                let utilization: Double?
                let resetsAt: String?

                enum CodingKeys: String, CodingKey {
                    case utilization
                    case resetsAt = "resets_at"
                }

                func window(id: String, title: String, durationMinutes: Int? = nil) -> QuotaWindow? {
                    let date = resetsAt.flatMap { value in
                        let formatter = ISO8601DateFormatter()
                        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                        if let date = formatter.date(from: value) { return date }
                        return ISO8601DateFormatter().date(from: value)
                    }
                    return QuotaWindow(id, title: title, used: utilization, resetsAt: date, durationMinutes: durationMinutes)
                }
            }
            let fiveHour: Window?
            let sevenDay: Window?
            let sevenDayOpus: Window?
            let sevenDaySonnet: Window?

            enum CodingKeys: String, CodingKey {
                case fiveHour = "five_hour"
                case sevenDay = "seven_day"
                case sevenDayOpus = "seven_day_opus"
                case sevenDaySonnet = "seven_day_sonnet"
            }
        }
        let subtype: String
        let response: Payload?
    }
    let response: Response
}

private struct ClaudeAuthStatus: Decodable {
    let loggedIn: Bool
}

private struct EmptyResult: Decodable {}

private struct RPCResponse<Result: Decodable>: Decodable {
    let result: Result?
}

private struct CodexAccount: Decodable {
    struct Account: Decodable { let type: String }
    let account: Account?
    let requiresOpenaiAuth: Bool?
    var type: String? { account?.type }
}

private struct CodexLimits: Decodable {
    struct Bucket: Decodable {
        struct Window: Decodable {
            let usedPercent: Double?
            let windowDurationMins: Int?
            let resetsAt: Int64?

            func window(id: String, fallbackTitle: String, titleOverride: String? = nil) -> QuotaWindow? {
                let title: String
                switch windowDurationMins {
                case 10080: title = "Weekly limit"
                case 300: title = "5-hour session"
                case let mins? where mins > 0 && mins.isMultiple(of: 1440): title = "\(mins / 1440)-day limit"
                case let mins? where mins > 0 && mins.isMultiple(of: 60): title = "\(mins / 60)-hour limit"
                case let mins? where mins > 0: title = "\(mins)-minute limit"
                default: title = fallbackTitle
                }
                return QuotaWindow(
                    id, title: titleOverride ?? title, used: usedPercent,
                    resetsAt: resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    durationMinutes: windowDurationMins
                )
            }
        }
        let primary: Window?
        let secondary: Window?
        let planType: String?
        let limitName: String?
    }

    let rateLimits: Bucket
    let rateLimitsByLimitId: [String: Bucket]?
}
