import Foundation
import IOKit

/// A2：电池健康。循环次数/容量走 IORegistry `AppleSmartBattery`，
/// 并用 `ioreg` 做第二来源交叉核对（防篡改）。
enum BatteryService {

    private static func openBatteryService() -> io_service_t {
        IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    }

    private static func ioKitProperties() -> [String: Any] {
        let service = openBatteryService()
        guard service != 0 else { return [:] }
        defer { IOObjectRelease(service) }

        var propsUnmanaged: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(service, &propsUnmanaged, kCFAllocatorDefault, 0)
        guard result == KERN_SUCCESS, let props = propsUnmanaged?.takeRetainedValue() as? [String: Any] else {
            return [:]
        }
        return props
    }

    /// 从 ioreg 文本解析整型字段（第二数据管道）。
    private static func ioregInt(_ key: String) -> Int? {
        let output = ShellRunner.run("/usr/sbin/ioreg", ["-rd1", "-c", "AppleSmartBattery"])
        guard let range = output.range(of: "\"\(key)\" = ") else { return nil }
        let tail = output[range.upperBound...]
        let numberString = tail.prefix { $0.isNumber || $0 == "-" }
        return Int(numberString)
    }

    /// 电池序列号：部分机型在顶层 BatterySerialNumber，部分在 BatteryData.Serial。
    private static func batterySerial(from props: [String: Any]) -> String? {
        if let s = props["BatterySerialNumber"] as? String, !s.isEmpty { return s }
        if let s = props["Serial"] as? String, !s.isEmpty { return s }
        if let data = props["BatteryData"] as? [String: Any],
           let s = data["Serial"] as? String, !s.isEmpty {
            return s
        }
        return nil
    }

    static func runAll() -> [CheckResult] {
        let props = ioKitProperties()
        guard !props.isEmpty else {
            return [CheckResult(
                id: "battery.health",
                title: L10n.t("battery.none.title"),
                status: .unsupported,
                summary: L10n.t("battery.none.summary")
            )]
        }

        var results: [CheckResult] = []

        let cycleCount = props["CycleCount"] as? Int ?? 0
        let designCapacity = props["DesignCapacity"] as? Int ?? 0
        let rawMaxCapacity = props["AppleRawMaxCapacity"] as? Int
            ?? (props["MaxCapacity"] as? Int).flatMap { $0 > 200 ? $0 : nil }
            ?? 0
        // MaxCapacity 在部分机型是 mAh，在部分是百分比；仅当 ≤100 时当百分比用。
        let maxCapacityPercentRaw = (props["MaxCapacity"] as? Int).flatMap { $0 > 0 && $0 <= 100 ? $0 : nil }
        let isCharging = props["IsCharging"] as? Bool ?? false
        let externalConnected = props["ExternalConnected"] as? Bool ?? false
        let temperatureRaw = props["Temperature"] as? Int ?? 0
        let temperatureC = Double(temperatureRaw) / 100.0
        let battSerial = batterySerial(from: props)

        var healthFromRaw: Double?
        if designCapacity > 0 && rawMaxCapacity > 0 {
            healthFromRaw = Double(rawMaxCapacity) / Double(designCapacity) * 100.0
        }
        var health: Double? = healthFromRaw
        if health == nil, let pct = maxCapacityPercentRaw {
            health = Double(pct)
        }

        // rawDetails 用稳定英文键，展示时由 UI 按键本地化（兼容旧中文键）。
        var cycleDetails: [String: String] = [
            "cycleCount": "\(cycleCount)",
            L10n.t("battery.detail.cycles"): "\(cycleCount)",
            L10n.t("battery.detail.life_ref"): L10n.t("battery.detail.design_life"),
        ]

        var healthDetails: [String: String] = [
            L10n.t("battery.detail.design_cap"): designCapacity > 0 ? "\(designCapacity)" : L10n.t("common.na"),
            L10n.t("battery.detail.max_cap"): rawMaxCapacity > 0 ? "\(rawMaxCapacity)" : L10n.t("common.na"),
            L10n.t("battery.detail.temp"): String(format: "%.1f °C", temperatureC),
            L10n.t("battery.detail.charging"): isCharging ? L10n.t("common.yes") : L10n.t("common.no"),
            L10n.t("battery.detail.ac"): externalConnected ? L10n.t("common.yes") : L10n.t("common.no"),
        ]
        if let battSerial { healthDetails[L10n.t("battery.detail.serial")] = battSerial }
        if let adapterDetails = props["AdapterDetails"] as? [String: Any],
           let watts = adapterDetails["Watts"] as? Int {
            healthDetails[L10n.t("battery.detail.adapter")] = "\(watts)W"
        }

        // —— 循环次数交叉核对 ——
        if let ioregCount = ioregInt("CycleCount"), ioregCount != cycleCount {
            results.append(CheckResult(
                id: "battery.cycleCount.crosscheck",
                title: L10n.t("battery.cycle.cross.title"),
                status: .redFlag,
                summary: L10n.t("battery.cycle.cross.summary", cycleCount, ioregCount),
                rawDetails: [
                    L10n.t("battery.detail.iokit_read"): "\(cycleCount)",
                    L10n.t("battery.detail.ioreg_read"): "\(ioregCount)",
                ],
                isRedFlagHeadline: L10n.t("battery.cycle.cross.headline")
            ))
        }

        // —— 容量真实性：设计容量 / 最大容量交叉 + 逻辑矛盾 ——
        results.append(contentsOf: capacityAuthenticityResults(
            designCapacity: designCapacity,
            rawMaxCapacity: rawMaxCapacity,
            healthFromRaw: healthFromRaw,
            maxCapacityPercentRaw: maxCapacityPercentRaw,
            cycleCount: cycleCount
        ))

        // —— 循环次数本体 ——
        let cycleStatus: CheckStatus = cycleCount > 1000 ? .warning : .pass
        let usageHint: String
        switch cycleCount {
        case 0...30: usageHint = L10n.t("battery.cycle.hint.new")
        case 31...200: usageHint = L10n.t("battery.cycle.hint.light")
        case 201...500: usageHint = L10n.t("battery.cycle.hint.mid")
        case 501...1000: usageHint = L10n.t("battery.cycle.hint.heavy")
        default: usageHint = L10n.t("battery.cycle.hint.high")
        }
        results.append(CheckResult(
            id: "battery.cycleCount",
            title: L10n.t("battery.cycle.title"),
            status: cycleStatus,
            summary: L10n.t("battery.cycle.summary", cycleCount, usageHint),
            rawDetails: cycleDetails
        ))

        // —— 健康度 ——
        if let health {
            healthDetails[L10n.t("battery.detail.health")] = String(format: "%.0f%%", health)
            if let healthFromRaw, let pct = maxCapacityPercentRaw {
                healthDetails[L10n.t("battery.detail.cross_cap")] =
                    L10n.t("battery.detail.cross_cap_fmt", healthFromRaw, pct)
            }
            let healthStatus: CheckStatus = health >= 80 ? .pass : (health >= 60 ? .warning : .redFlag)
            let headline: String? = health < 60
                ? L10n.t("battery.health.headline", Int(health))
                : nil
            let summaryKey: String
            if health >= 80 {
                summaryKey = "battery.health.summary.good"
            } else if health >= 60 {
                summaryKey = "battery.health.summary.ok"
            } else {
                summaryKey = "battery.health.summary.bad"
            }
            results.append(CheckResult(
                id: "battery.health",
                title: L10n.t("battery.health.title"),
                status: healthStatus,
                summary: L10n.t(summaryKey, Int(health)),
                rawDetails: healthDetails,
                isRedFlagHeadline: headline
            ))
        } else {
            results.append(CheckResult(
                id: "battery.health",
                title: L10n.t("battery.health.title"),
                status: .warning,
                summary: L10n.t("battery.health.unknown"),
                rawDetails: healthDetails
            ))
        }

        return results
    }

    /// 设计容量 vs 当前最大容量真实性校验。
    private static func capacityAuthenticityResults(
        designCapacity: Int,
        rawMaxCapacity: Int,
        healthFromRaw: Double?,
        maxCapacityPercentRaw: Int?,
        cycleCount: Int
    ) -> [CheckResult] {
        var results: [CheckResult] = []
        let ioregDesign = ioregInt("DesignCapacity")
        let ioregRawMax = ioregInt("AppleRawMaxCapacity") ?? ioregInt("MaxCapacity").flatMap { $0 > 200 ? $0 : nil }

        var details: [String: String] = [
            L10n.t("battery.detail.iokit_design"): designCapacity > 0 ? "\(designCapacity) mAh" : L10n.t("common.na"),
            L10n.t("battery.detail.iokit_max"): rawMaxCapacity > 0 ? "\(rawMaxCapacity) mAh" : L10n.t("common.na"),
        ]
        if let ioregDesign { details[L10n.t("battery.detail.ioreg_design")] = "\(ioregDesign) mAh" }
        if let ioregRawMax { details[L10n.t("battery.detail.ioreg_max")] = "\(ioregRawMax) mAh" }
        if let healthFromRaw {
            details[L10n.t("battery.detail.raw_ratio")] = String(format: "%.1f%%", healthFromRaw)
        }
        if let maxCapacityPercentRaw {
            details[L10n.t("battery.detail.max_pct")] = "\(maxCapacityPercentRaw)%"
        }

        // 两条路径设计容量不一致
        if let ioregDesign, designCapacity > 0, ioregDesign != designCapacity {
            results.append(CheckResult(
                id: "battery.capacity.crosscheck",
                title: L10n.t("battery.cap.design_cross.title"),
                status: .redFlag,
                summary: L10n.t("battery.cap.design_cross.summary", designCapacity, ioregDesign),
                rawDetails: details,
                isRedFlagHeadline: L10n.t("battery.cap.design_cross.headline")
            ))
            return results
        }

        // 两条路径最大容量不一致（允许 ±2% 误差）
        if let ioregRawMax, rawMaxCapacity > 0 {
            let delta = abs(ioregRawMax - rawMaxCapacity)
            let tol = max(50, Int(Double(rawMaxCapacity) * 0.02))
            if delta > tol {
                results.append(CheckResult(
                    id: "battery.capacity.crosscheck",
                    title: L10n.t("battery.cap.max_cross.title"),
                    status: .redFlag,
                    summary: L10n.t("battery.cap.max_cross.summary", rawMaxCapacity, ioregRawMax),
                    rawDetails: details,
                    isRedFlagHeadline: L10n.t("battery.cap.max_cross.headline")
                ))
                return results
            }
        }

        // 逻辑矛盾：最大容量显著高于设计容量
        if designCapacity > 0 && rawMaxCapacity > Int(Double(designCapacity) * 1.05) {
            results.append(CheckResult(
                id: "battery.capacity.integrity",
                title: L10n.t("battery.cap.logic.title"),
                status: .redFlag,
                summary: L10n.t("battery.cap.logic.summary", rawMaxCapacity, designCapacity),
                rawDetails: details,
                isRedFlagHeadline: L10n.t("battery.cap.logic.headline")
            ))
            return results
        }

        // 百分比字段与原始比值严重不符
        if let healthFromRaw, let pct = maxCapacityPercentRaw {
            if abs(healthFromRaw - Double(pct)) > 8 {
                results.append(CheckResult(
                    id: "battery.capacity.integrity",
                    title: L10n.t("battery.cap.consistency.title"),
                    status: .redFlag,
                    summary: L10n.t("battery.cap.consistency.summary", healthFromRaw, pct),
                    rawDetails: details,
                    isRedFlagHeadline: L10n.t("battery.cap.consistency.headline")
                ))
                return results
            }
        }

        // 高循环却仍显示近全新健康度
        if let healthFromRaw, cycleCount >= 600, healthFromRaw >= 98 {
            results.append(CheckResult(
                id: "battery.capacity.integrity",
                title: L10n.t("battery.cap.wear.title"),
                status: .warning,
                summary: L10n.t("battery.cap.wear.summary", cycleCount, healthFromRaw),
                rawDetails: details
            ))
            return results
        }

        if designCapacity > 0 && rawMaxCapacity > 0 {
            results.append(CheckResult(
                id: "battery.capacity.integrity",
                title: L10n.t("battery.cap.auth.title"),
                status: .pass,
                summary: L10n.t("battery.cap.auth.summary",
                                designCapacity, rawMaxCapacity, healthFromRaw ?? 0),
                rawDetails: details
            ))
        }

        return results
    }
}
