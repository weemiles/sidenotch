import Foundation

/// Approximate list prices, USD per 1M tokens. Only the *ratios* between models
/// and cache kinds matter here: the result is compared against a budget derived
/// from the same numbers, so a uniform error cancels out.
enum ClaudePricing {
    struct Rate {
        let input: Double, output: Double, write5m: Double, write1h: Double, read: Double
    }

    static let opus   = Rate(input: 15, output: 75, write5m: 18.75, write1h: 30, read: 1.50)
    static let sonnet = Rate(input: 3,  output: 15, write5m: 3.75,  write1h: 6,  read: 0.30)
    static let haiku  = Rate(input: 1,  output: 5,  write5m: 1.25,  write1h: 2,  read: 0.10)

    static func rate(for model: String?) -> Rate {
        guard let m = model?.lowercased() else { return sonnet }
        if m.contains("opus") { return opus }
        if m.contains("haiku") { return haiku }
        return sonnet
    }

    /// Weighted cost of one assistant message, and its raw token count.
    static func weigh(usage: [String: Any], model: String?) -> (cost: Double, tokens: Int) {
        let p = rate(for: model)
        let input = usage["input_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? 0
        let read = usage["cache_read_input_tokens"] as? Int ?? 0

        var write5m = 0, write1h = 0
        if let detail = usage["cache_creation"] as? [String: Any] {
            write5m = detail["ephemeral_5m_input_tokens"] as? Int ?? 0
            write1h = detail["ephemeral_1h_input_tokens"] as? Int ?? 0
        }
        if write5m == 0 && write1h == 0 {
            write5m = usage["cache_creation_input_tokens"] as? Int ?? 0
        }

        let cost = (Double(input) * p.input + Double(output) * p.output
                    + Double(write5m) * p.write5m + Double(write1h) * p.write1h
                    + Double(read) * p.read) / 1_000_000
        return (cost, input + output + read + write5m + write1h)
    }
}
