import Foundation

/// `CheckResult.rawDetails`: stable English keys internally; localize only for display.
/// Never use `L10n.t(...)` results as dictionary keys (breaks on language switch).
enum RawDetails {
    static func localize(_ raw: [String: String], using displayKey: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        out.reserveCapacity(raw.count)
        for (k, v) in raw {
            let label = displayKey[k].map { L10n.t($0) } ?? k
            out[label] = v
        }
        return out
    }
}
