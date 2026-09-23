import Foundation

/// Asks ChatGPT for the account's Codex limits — the same request `/status`
/// makes — using the login Codex CLI keeps in `~/.codex/auth.json`.
///
/// The rollout logs only record a limit when a turn runs, so between sessions
/// they go on reporting the last week's figure; this reads the account as it is
/// now. As with Claude, the credential is only ever read: never stored, never
/// logged, never refreshed, since refreshing would rotate the token out from
/// under Codex. An expired one just means the logs stand in until Codex renews it.
enum CodexQuotaReader {

    private static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let authFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/auth.json")

    static func read() -> CodexUsage? {
        guard let data = try? Data(contentsOf: authFile),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String else { return nil }

        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let account = tokens["account_id"] as? String {
            request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        guard let body = get(request),
              let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let limit = obj["rate_limit"] as? [String: Any] else { return nil }

        // Only `rate_limit` is the Codex allowance. `additional_rate_limits`
        // describes other pools, and folding those in is how a spent reserve
        // once showed up as a spent Codex week.
        let now = Date()
        let windows = ["primary_window", "secondary_window"].compactMap { key -> CodexWindow? in
            guard let w = limit[key] as? [String: Any],
                  let used = (w["used_percent"] as? NSNumber)?.doubleValue,
                  let seconds = (w["limit_window_seconds"] as? NSNumber)?.intValue else { return nil }
            let reset = (w["reset_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return CodexWindow(usedPercent: used, windowMinutes: seconds / 60,
                               resetsAt: reset, updatedAt: now)
        }
        guard !windows.isEmpty else { return nil }

        var usage = CodexUsage()
        usage.windows = windows.sorted { $0.windowMinutes < $1.windowMinutes }
        usage.planType = obj["plan_type"] as? String
        usage.updatedAt = now
        return usage
    }

    /// Synchronous on purpose: this only ever runs off the main thread.
    private static func get(_ request: URLRequest) -> Data? {
        var result: Data?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200 { result = data }
            done.signal()
        }.resume()
        done.wait()
        return result
    }
}
