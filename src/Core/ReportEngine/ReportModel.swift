import Foundation

/// Per-check status. Red flags surface at the top of the report.
enum CheckStatus: String, Codable, Sendable {
    case pass          // OK
    case warning       // Worth attention, not a deal-breaker
    case redFlag       // Hard fail (MDM / lock / tamper suspicion)
    case skipped       // User skipped
    case unsupported   // Not available on this machine/run

    var emoji: String {
        switch self {
        case .pass: return "✅"
        case .warning: return "⚠️"
        case .redFlag: return "⛔"
        case .skipped: return "⏭️"
        case .unsupported: return "➖"
        }
    }
}

/// One check result: plain summary + expandable raw details.
struct CheckResult: Identifiable, Codable, Sendable {
    let id: String                  // Stable id, e.g. "battery.cycleCount"
    let title: String               // Display title
    let status: CheckStatus
    let summary: String              // One-line conclusion
    var rawDetails: [String: String] = [:]   // Collapsible raw key/values
    var isRedFlagHeadline: String? = nil      // Non-nil → promoted to report red-flag section

    init(
        id: String,
        title: String,
        status: CheckStatus,
        summary: String,
        rawDetails: [String: String] = [:],
        isRedFlagHeadline: String? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.summary = summary
        self.rawDetails = rawDetails
        self.isRedFlagHeadline = isRedFlagHeadline
    }
}

/// One GPU row for Specs / report (from `GraphicsProbe`).
struct DeviceGraphicsInfo: Codable, Sendable, Equatable {
    var name: String
    var detail: String
}

/// Structured machine profile for the home header (shown on launch).
struct DeviceProfile: Codable, Sendable {
    var marketingName: String    // e.g. "MacBook Pro (14-inch, 2021)"
    var modelIdentifier: String  // "MacBookPro18,3"
    var chip: String             // "Apple M1 Pro"
    var memory: String           // "32 GB"
    var macOSVersion: String     // "macOS 15.3.2 (24D...)"
    var serialNumber: String
    var architecture: String
    var modelYear: String        // "2021" parsed from marketing name
    var productionDate: String   // Estimated date, or randomized-serial note
    var graphics: [DeviceGraphicsInfo] = []
}

/// Full inspection report.
struct MacInspectReport: Codable, Sendable {
    var generatedAt: Date
    var appVersion: String
    var results: [CheckResult] = []

    var redFlags: [CheckResult] {
        results.filter { $0.status == .redFlag }
    }

    var score: Int {
        guard !results.isEmpty else { return 100 }
        let scored = results.filter { $0.status != .skipped && $0.status != .unsupported }
        guard !scored.isEmpty else { return 100 }
        let deductions = scored.reduce(0.0) { acc, r in
            switch r.status {
            case .redFlag: return acc + 25
            case .warning: return acc + 8
            default: return acc
            }
        }
        return max(0, Int(100 - deductions))
    }

    mutating func add(_ result: CheckResult) {
        results.append(result)
    }
}
