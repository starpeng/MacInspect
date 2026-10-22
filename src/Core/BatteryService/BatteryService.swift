import Foundation
import IOKit

/// A2: Battery health via IORegistry `AppleSmartBattery`, cross-checked with `ioreg`.
enum BatteryService {

    /// Stable English keys; localize when writing CheckResult.
    private enum Key {
        static let cycles = "cycleCount"
        static let lifeRef = "designLifeRef"
        static let designCap = "designCapacity"
        static let maxCap = "maxCapacity"
        static let temp = "temperature"
        static let charging = "charging"
        static let ac = "acPower"
        static let serial = "batterySerial"
        static let adapter = "adapterWatts"
        static let health = "health"
        static let crossCap = "capacityCross"
        static let iokitRead = "iokitRead"
        static let ioregRead = "ioregRead"
        static let iokitDesign = "iokitDesign"
        static let iokitMax = "iokitMax"
        static let ioregDesign = "ioregDesign"
        static let ioregMax = "ioregMax"
        static let rawRatio = "rawRatio"
        static let maxPct = "maxCapacityPercent"
    }

    private static let displayKey: [String: String] = [
        Key.cycles: "battery.detail.cycles",
        Key.lifeRef: "battery.detail.life_ref",
        Key.designCap: "battery.detail.design_cap",
        Key.maxCap: "battery.detail.max_cap",
        Key.temp: "battery.detail.temp",
        Key.charging: "battery.detail.charging",
        Key.ac: "battery.detail.ac",
        Key.serial: "battery.detail.serial",
        Key.adapter: "battery.detail.adapter",
        Key.health: "battery.detail.health",
        Key.crossCap: "battery.detail.cross_cap",
        Key.iokitRead: "battery.detail.iokit_read",
        Key.ioregRead: "battery.detail.ioreg_read",
        Key.iokitDesign: "battery.detail.iokit_design",
        Key.iokitMax: "battery.detail.iokit_max",
        Key.ioregDesign: "battery.detail.ioreg_design",
        Key.ioregMax: "battery.detail.ioreg_max",
        Key.rawRatio: "battery.detail.raw_ratio",
        Key.maxPct: "battery.detail.max_pct",
    ]

    private static func localizeDetails(_ raw: [String: String]) -> [String: String] {
        RawDetails.localize(raw, using: displayKey)
    }

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

    /// Parse an int field from ioreg text (second data path).
    private static func ioregInt(_ key: String) -> Int? {
        let output = ShellRunner.run("/usr/sbin/ioreg", ["-rd1", "-c", "AppleSmartBattery"])
        guard let range = output.range(of: "\"\(key)\" = ") else { return nil }
        let tail = output[range.upperBound...]
        let numberString = tail.prefix { $0.isNumber || $0 == "-" }
        return Int(numberString)
    }

    /// Battery serial: top-level BatterySerialNumber or BatteryData.Serial.
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
        // MaxCapacity is mAh on some models, percent on others; treat as % only if ≤100.
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

        // Stable English keys in rawDetails; localize later (never L10n.t as keys).
        let cycleDetails: [String: String] = [
            Key.cycles: "\(cycleCount)",
            Key.lifeRef: L10n.t("battery.detail.design_life"),
        ]

        var healthDetails: [String: String] = [
            Key.designCap: designCapacity > 0 ? "\(designCapacity)" : L10n.t("common.na"),
            Key.maxCap: rawMaxCapacity > 0 ? "\(rawMaxCapacity)" : L10n.t("common.na"),
            Key.temp: String(format: "%.1f °C", temperatureC),
            Key.charging: isCharging ? L10n.t("common.yes") : L10n.t("common.no"),
            Key.ac: externalConnected ? L10n.t("common.yes") : L10n.t("common.no"),
        ]
        if let battSerial { healthDetails[Key.serial] = battSerial }
        if let adapterDetails = props["AdapterDetails"] as? [String: Any],
           let watts = adapterDetails["Watts"] as? Int {
            healthDetails[Key.adapter] = "\(watts)W"
        }

        // Cycle-count cross-check
        if let ioregCount = ioregInt("CycleCount"), ioregCount != cycleCount {
            results.append(CheckResult(
                id: "battery.cycleCount.crosscheck",
                title: L10n.t("battery.cycle.cross.title"),
                status: .redFlag,
                summary: L10n.t("battery.cycle.cross.summary", cycleCount, ioregCount),
                rawDetails: localizeDetails([
                    Key.iokitRead: "\(cycleCount)",
                    Key.ioregRead: "\(ioregCount)",
                ]),
                isRedFlagHeadline: L10n.t("battery.cycle.cross.headline")
            ))
        }

        // Capacity authenticity: design/max cross-check + contradictions
        results.append(contentsOf: capacityAuthenticityResults(
            designCapacity: designCapacity,
            rawMaxCapacity: rawMaxCapacity,
            healthFromRaw: healthFromRaw,
            maxCapacityPercentRaw: maxCapacityPercentRaw,
            cycleCount: cycleCount
        ))

        // Cycle count
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
            rawDetails: localizeDetails(cycleDetails)
        ))

        // Health %
        if let health {
            healthDetails[Key.health] = String(format: "%.0f%%", health)
            if let healthFromRaw, let pct = maxCapacityPercentRaw {
                healthDetails[Key.crossCap] =
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
                rawDetails: localizeDetails(healthDetails),
                isRedFlagHeadline: headline
            ))
        } else {
            results.append(CheckResult(
                id: "battery.health",
                title: L10n.t("battery.health.title"),
                status: .warning,
                summary: L10n.t("battery.health.unknown"),
                rawDetails: localizeDetails(healthDetails)
            ))
        }

        return results
    }

    /// Design capacity vs current max — authenticity checks.
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
            Key.iokitDesign: designCapacity > 0 ? "\(designCapacity) mAh" : L10n.t("common.na"),
            Key.iokitMax: rawMaxCapacity > 0 ? "\(rawMaxCapacity) mAh" : L10n.t("common.na"),
        ]
        if let ioregDesign { details[Key.ioregDesign] = "\(ioregDesign) mAh" }
        if let ioregRawMax { details[Key.ioregMax] = "\(ioregRawMax) mAh" }
        if let healthFromRaw {
            details[Key.rawRatio] = String(format: "%.1f%%", healthFromRaw)
        }
        if let maxCapacityPercentRaw {
            details[Key.maxPct] = "\(maxCapacityPercentRaw)%"
        }
        let localizedDetails = localizeDetails(details)

        // Design capacity mismatch across paths
        if let ioregDesign, designCapacity > 0, ioregDesign != designCapacity {
            results.append(CheckResult(
                id: "battery.capacity.crosscheck",
                title: L10n.t("battery.cap.design_cross.title"),
                status: .redFlag,
                summary: L10n.t("battery.cap.design_cross.summary", designCapacity, ioregDesign),
                rawDetails: localizedDetails,
                isRedFlagHeadline: L10n.t("battery.cap.design_cross.headline")
            ))
            return results
        }

        // Max capacity mismatch across paths (±2% tolerance)
        if let ioregRawMax, rawMaxCapacity > 0 {
            let delta = abs(ioregRawMax - rawMaxCapacity)
            let tol = max(50, Int(Double(rawMaxCapacity) * 0.02))
            if delta > tol {
                results.append(CheckResult(
                    id: "battery.capacity.crosscheck",
                    title: L10n.t("battery.cap.max_cross.title"),
                    status: .redFlag,
                    summary: L10n.t("battery.cap.max_cross.summary", rawMaxCapacity, ioregRawMax),
                    rawDetails: localizedDetails,
                    isRedFlagHeadline: L10n.t("battery.cap.max_cross.headline")
                ))
                return results
            }
        }

        // Contradiction: max capacity well above design
        if designCapacity > 0 && rawMaxCapacity > Int(Double(designCapacity) * 1.05) {
            results.append(CheckResult(
                id: "battery.capacity.integrity",
                title: L10n.t("battery.cap.logic.title"),
                status: .redFlag,
                summary: L10n.t("battery.cap.logic.summary", rawMaxCapacity, designCapacity),
                rawDetails: localizedDetails,
                isRedFlagHeadline: L10n.t("battery.cap.logic.headline")
            ))
            return results
        }

        // Percent field disagrees badly with raw ratio
        if let healthFromRaw, let pct = maxCapacityPercentRaw {
            if abs(healthFromRaw - Double(pct)) > 8 {
                results.append(CheckResult(
                    id: "battery.capacity.integrity",
                    title: L10n.t("battery.cap.consistency.title"),
                    status: .redFlag,
                    summary: L10n.t("battery.cap.consistency.summary", healthFromRaw, pct),
                    rawDetails: localizedDetails,
                    isRedFlagHeadline: L10n.t("battery.cap.consistency.headline")
                ))
                return results
            }
        }

        // High cycles but near-new health %
        if let healthFromRaw, cycleCount >= 600, healthFromRaw >= 98 {
            results.append(CheckResult(
                id: "battery.capacity.integrity",
                title: L10n.t("battery.cap.wear.title"),
                status: .warning,
                summary: L10n.t("battery.cap.wear.summary", cycleCount, healthFromRaw),
                rawDetails: localizedDetails
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
                rawDetails: localizedDetails
            ))
        }

        return results
    }
}
