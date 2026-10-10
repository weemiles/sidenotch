import Foundation

/// Grok Bot's allowance as its own settings pane shows it.
///
/// Grok Bot is Anysphere's app and signs in with a Cursor account, so the
/// figure comes from the same Cursor dashboard call the app makes —
/// `DashboardService/GetSandUsageStatus`, over Connect's JSON encoding.
struct GrokUsage: Equatable {
    var usedPercent: Double
    var resetsAt: Date?
    var planLabel: String?
    var updatedAt: Date

    var remaining: Double { max(0, min(1, 1 - usedPercent / 100)) }
}

/// The same account's Cursor allowance for the billing cycle — the figure
/// Grok Bot's usage pane charts beside its own, from `GetCurrentPeriodUsage`.
struct CursorUsage: Equatable {
    var usedPercent: Double
    var resetsAt: Date?
    var updatedAt: Date

    var remaining: Double { max(0, min(1, 1 - usedPercent / 100)) }
}

enum GrokQuotaReader {

    private static let dashboard = "https://api2.cursor.sh/aiserver.v1.DashboardService/"

    /// Read each app independently; Cursor login also provides Grok dashboard access.
    static func read() -> (grok: GrokUsage?, cursor: CursorUsage?) {
        // Cursor's login is already readable by this app and provides both dashboards.
        // Try it first so an inaccessible Grok keychain cannot block Cursor's gauge.
        let cursorToken = cursorAccessToken()
        var grokUsage = cursorToken.flatMap(grok)
        var cursorUsage = cursorToken.flatMap(cursor)
        if grokUsage == nil || cursorUsage == nil, let token = accessToken() {
            if grokUsage == nil { grokUsage = grok(token) }
            if cursorUsage == nil { cursorUsage = cursor(token) }
        }
        return (grokUsage, cursorUsage)
    }

    private static func grok(_ token: String) -> GrokUsage? {
        guard let obj = call("GetSandUsageStatus", token),
              let used = (obj["usagePercent"] as? NSNumber)?.doubleValue,
              used.isFinite, used >= 0 else { return nil }

        // A Timestamp arrives as RFC 3339, with or without fractional seconds.
        let reset = (obj["nextResetTimestampUtc"] as? String).flatMap { stamp in
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: stamp) { return d }
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: stamp)
        }
        let plan = (obj["grokPlanLabel"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return GrokUsage(usedPercent: used, resetsAt: reset, planLabel: plan, updatedAt: Date())
    }

    private static func cursor(_ token: String) -> CursorUsage? {
        guard let obj = call("GetCurrentPeriodUsage", token),
              let plan = obj["planUsage"] as? [String: Any],
              let used = (plan["totalPercentUsed"] as? NSNumber)?.doubleValue,
              used.isFinite, used >= 0 else { return nil }
        // int64 milliseconds, which Connect's JSON writes as a string.
        let end = (obj["billingCycleEnd"] as? String).flatMap(Double.init)
            ?? (obj["billingCycleEnd"] as? NSNumber)?.doubleValue
        let reset = end.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
        return CursorUsage(usedPercent: used, resetsAt: reset, updatedAt: Date())
    }

    private static func call(_ method: String, _ token: String) -> [String: Any]? {
        var request = URLRequest(url: URL(string: dashboard + method)!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let body = post(request) else { return nil }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    // MARK: Credential

    private static let secretsFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Grok Bot/sand-secrets.json")

    /// Grok Bot's Cursor login, as the app itself stores it: the active
    /// account's token inside `cursor-accounts`, sealed with Electron's
    /// `safeStorage`. Only ever read — never stored, logged or refreshed, since
    /// refreshing would rotate the token out from under Grok Bot. An expired
    /// one just means a dash until the app renews it.
    private static func accessToken() -> String? {
        guard let data = try? Data(contentsOf: secretsFile),
              let file = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return nil }

        var sealed = file["cursor-access-token"]    // older single-account layout
        if let raw = file["cursor-accounts"]?.data(using: .utf8),
           let saved = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
           let active = saved["active"] as? String,
           let accounts = saved["accounts"] as? [String: [String: String]],
           let token = accounts[active]?["cursor-access-token"] {
            sealed = token
        }
        guard var value = sealed else { return nil }

        let plaintext = "plaintext:v1:"
        if value.hasPrefix(plaintext) {
            return Data(base64Encoded: String(value.dropFirst(plaintext.count)))
                .flatMap { String(data: $0, encoding: .utf8) }
        }
        // "scoped:v1:<64 hex>:<ciphertext>" names the account it belongs to.
        let scoped = "scoped:v1:"
        if value.hasPrefix(scoped) {
            let rest = value.dropFirst(scoped.count)
            guard let colon = rest.firstIndex(of: ":") else { return nil }
            value = String(rest[rest.index(after: colon)...])
        }
        guard let cipher = Data(base64Encoded: value) else { return nil }
        return SafeStorage.decrypt(cipher)
    }

    /// Read Cursor's active login without changing its database or credentials.
    private static func cursorAccessToken() -> String? {
        let database = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        guard FileManager.default.fileExists(atPath: database.path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", database.path,
            "SELECT value FROM ItemTable WHERE key='cursorAuth/accessToken' LIMIT 1;"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return nil }
        return token
    }

    /// Synchronous on purpose: this only ever runs off the main thread.
    private static func post(_ request: URLRequest) -> Data? {
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
