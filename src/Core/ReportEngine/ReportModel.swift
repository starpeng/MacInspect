import Foundation

/// 单项检测结果的状态。红旗项会被提升到报告顶部单独展示。
enum CheckStatus: String, Codable, Sendable {
    case pass          // 绿色，正常
    case warning       // 黄色，需要注意但不是硬伤
    case redFlag       // 红色，一票否决级问题（监管/锁定/疑似篡改）
    case skipped       // 用户主动跳过
    case unsupported   // 本机型/本次运行环境不支持该项检测

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

/// 一项检测的完整结果：人话结论 + 可展开的专业原始数据。
struct CheckResult: Identifiable, Codable, Sendable {
    let id: String                  // 稳定 ID，如 "battery.cycleCount"
    let title: String               // 人话标题，如 "电池健康"
    let status: CheckStatus
    let summary: String              // 一句人话结论，如 "循环次数 47 次，约等于轻度使用 3 个月"
    var rawDetails: [String: String] = [:]   // 专业详情折叠区：原始键值
    var isRedFlagHeadline: String? = nil      // 非空时会被提升到报告顶部红旗区，用大白话完整解释后果

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

/// 结构化机器档案，供首页头部直接展示（打开 App 即可见，无需任何操作）。
struct DeviceProfile: Codable, Sendable {
    var marketingName: String    // "MacBook Pro（14 英寸，2021）"
    var modelIdentifier: String  // "MacBookPro18,3"
    var chip: String             // "Apple M1 Pro"
    var memory: String           // "32 GB"
    var macOSVersion: String     // "macOS 15.3.2 (24D...)"
    var serialNumber: String
    var architecture: String
    var modelYear: String        // "2021"（从营销名解析）
    var productionDate: String   // 生产日期估算或随机化说明
    var graphics: [DeviceGraphicsInfo] = []
}

/// 完整验机报告。
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
