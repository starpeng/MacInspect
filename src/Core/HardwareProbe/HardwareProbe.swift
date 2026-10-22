import Foundation
import IOKit

/// A1：机器身份信息。所有字段走 IOKit/sysctl 底层读取，不依赖「关于本机」这类可被替换的上层展示。
/// 序列号额外用 system_profiler 交叉核对（5.5 防篡改原则）。
enum HardwareProbe {

    // MARK: - IOKit 读取

    static func ioPlatformSerialNumber() -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return "" }
        defer { IOObjectRelease(service) }
        guard let cfValue = IORegistryEntryCreateCFProperty(
            service, kIOPlatformSerialNumberKey as CFString, kCFAllocatorDefault, 0
        ) else { return "" }
        return (cfValue.takeRetainedValue() as? String) ?? ""
    }

    static func ioPlatformUUID() -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return "" }
        defer { IOObjectRelease(service) }
        guard let cfValue = IORegistryEntryCreateCFProperty(
            service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0
        ) else { return "" }
        return (cfValue.takeRetainedValue() as? String) ?? ""
    }

    // MARK: - sysctl 读取

    static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }

    static func isAppleSiliconHardware() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        if result == 0 { return value == 1 }
        return sysctlString("machdep.cpu.brand_string").contains("Apple")
    }

    static func physicalMemoryGB() -> Double {
        var memSize: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &memSize, &size, nil, 0)
        return Double(memSize) / 1_073_741_824.0
    }

    static func modelIdentifier() -> String {
        sysctlString("hw.model")
    }

    // MARK: - system_profiler 交叉核对

    static func systemProfilerHardwareJSON() -> [String: Any] {
        let output = ShellRunner.run("/usr/sbin/system_profiler", ["SPHardwareDataType", "-json"])
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["SPHardwareDataType"] as? [[String: Any]],
              let first = items.first
        else { return [:] }
        return first
    }

    // MARK: - 芯片 / 系统版本

    static func chipString() -> String {
        let sp = systemProfilerHardwareJSON()
        if let chip = sp["chip_type"] as? String { return chip }
        if let cpu = sp["cpu_type"] as? String { return cpu }
        return sysctlString("machdep.cpu.brand_string")
    }

    static func macOSVersionString() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let build = sysctlString("kern.osversion")
        var s = "macOS \(v.majorVersion).\(v.minorVersion)"
        if v.patchVersion > 0 { s += ".\(v.patchVersion)" }
        if !build.isEmpty { s += " (\(build))" }
        return s
    }

    /// 首页头部用的结构化机器档案（打开即展示，无需用户操作）。
    static func buildProfile() -> DeviceProfile {
        let sp = systemProfilerHardwareJSON()
        let identifier = modelIdentifier()
        let machineName = (sp["machine_name"] as? String) ?? ""
        let ioSerial = ioPlatformSerialNumber()
        let serial = ioSerial.isEmpty ? ((sp["serial_number"] as? String) ?? "") : ioSerial
        let marketing = DeviceNaming.friendlyName(fallbackMachineName: machineName, identifier: identifier)
        return DeviceProfile(
            marketingName: marketing,
            modelIdentifier: identifier,
            chip: chipString(),
            memory: String(format: "%.0f GB", physicalMemoryGB().rounded()),
            macOSVersion: macOSVersionString(),
            serialNumber: serial,
            architecture: isAppleSiliconHardware() ? "Apple Silicon (arm64)" : "Intel (x86_64)",
            modelYear: modelYear(from: marketing),
            productionDate: SerialDecoder.productionDescription(serial: serial),
            graphics: GraphicsProbe.profileEntries()
        )
    }

    /// 从营销名里提取 4 位年份，如 "MacBook Pro（14 英寸，2021）" → "2021"。
    private static func modelYear(from marketingName: String) -> String {
        if let range = marketingName.range(of: #"20\d{2}"#, options: .regularExpression) {
            return String(marketingName[range])
        }
        return ""
    }

    // MARK: - 组件序列号（拼装机线索）

    private static func batterySerialNumber() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var propsUnmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propsUnmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = propsUnmanaged?.takeRetainedValue() as? [String: Any]
        else { return nil }
        if let s = props["BatterySerialNumber"] as? String, !s.isEmpty { return s }
        if let s = props["Serial"] as? String, !s.isEmpty { return s }
        if let data = props["BatteryData"] as? [String: Any],
           let s = data["Serial"] as? String, !s.isEmpty {
            return s
        }
        return nil
    }

    private static func displaySerialNumber() -> String? {
        // 部分内建屏在 IODisplay 树里暴露 AlphanumericSerialNumber / DisplaySerialNumber
        let output = ShellRunner.run("/usr/sbin/ioreg", ["-lw0"])
        for key in ["AlphanumericSerialNumber", "DisplaySerialNumber", "display-serial-number"] {
            if let range = output.range(of: "\"\(key)\" = \"") {
                let tail = output[range.upperBound...]
                if let end = tail.firstIndex(of: "\"") {
                    let value = String(tail[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty, value.uppercased() != "NULL" { return value }
                }
            }
        }
        return nil
    }

    // MARK: - 汇总检测

    static func runAll() -> [CheckResult] {
        var results: [CheckResult] = []

        let sp = systemProfilerHardwareJSON()
        let ioSerial = ioPlatformSerialNumber()
        let spSerial = (sp["serial_number"] as? String) ?? ""
        let model = modelIdentifier()
        let spModel = (sp["machine_model"] as? String) ?? ""
        let uuid = ioPlatformUUID()
        let battSerial = batterySerialNumber()
        let displaySerial = displaySerialNumber()

        // 序列号交叉核对：IOKit vs system_profiler 不一致 → 红旗（疑似篡改/环境异常）
        if ioSerial.isEmpty && spSerial.isEmpty {
            results.append(CheckResult(
                id: "hardware.serial",
                title: L10n.t("hw.serial.title"),
                status: .warning,
                summary: L10n.t("hw.serial.missing"),
                rawDetails: ["IOKit": ioSerial, "system_profiler": spSerial]
            ))
        } else if !ioSerial.isEmpty && !spSerial.isEmpty && ioSerial != spSerial {
            results.append(CheckResult(
                id: "hardware.serial",
                title: L10n.t("hw.serial.title"),
                status: .redFlag,
                summary: L10n.t("hw.serial.mismatch"),
                rawDetails: [
                    L10n.t("hw.serial.iokit"): ioSerial,
                    L10n.t("hw.serial.sp"): spSerial,
                ],
                isRedFlagHeadline: L10n.t("hw.serial.mismatch.headline")
            ))
        } else {
            let serial = ioSerial.isEmpty ? spSerial : ioSerial
            let cross = model == spModel || spModel.isEmpty
                ? L10n.t("hw.serial.match")
                : L10n.t("hw.serial.mismatch_fmt", model, spModel)
            var details: [String: String] = [
                L10n.t("hw.serial.board"): serial,
                L10n.t("hw.serial.model_id"): model,
                L10n.t("hw.serial.model_cross"): cross,
            ]
            if !uuid.isEmpty { details[L10n.t("hw.serial.uuid")] = uuid }
            results.append(CheckResult(
                id: "hardware.serial",
                title: L10n.t("hw.serial.title"),
                status: .pass,
                summary: L10n.t("hw.serial.ok", serial),
                rawDetails: details
            ))
        }

        // 组件序列号汇总：便于发现「换主板/换电池/换屏」拼装机
        var componentDetails: [String: String] = [:]
        if !ioSerial.isEmpty { componentDetails[L10n.t("hw.serial.board")] = ioSerial }
        else if !spSerial.isEmpty { componentDetails[L10n.t("hw.serial.board")] = spSerial }
        if let battSerial { componentDetails[L10n.t("hw.serial.batt")] = battSerial }
        if let displaySerial { componentDetails[L10n.t("hw.serial.display")] = displaySerial }
        if !uuid.isEmpty { componentDetails[L10n.t("hw.serial.uuid")] = uuid }

        let hasBattery = !ioKitBatteryMissing()
        if hasBattery && battSerial == nil {
            results.append(CheckResult(
                id: "hardware.componentSerials",
                title: L10n.t("hw.components.title"),
                status: .warning,
                summary: L10n.t("hw.components.no_batt_serial"),
                rawDetails: componentDetails
            ))
        } else if componentDetails.count >= 2 {
            let battSuffix = battSerial != nil ? L10n.t("hw.components.battery_suffix") : ""
            let displaySuffix = displaySerial != nil ? L10n.t("hw.components.display_suffix") : ""
            results.append(CheckResult(
                id: "hardware.componentSerials",
                title: L10n.t("hw.components.title"),
                status: .pass,
                summary: L10n.t("hw.components.ok", battSuffix, displaySuffix),
                rawDetails: componentDetails
            ))
        } else if !componentDetails.isEmpty {
            results.append(CheckResult(
                id: "hardware.componentSerials",
                title: L10n.t("hw.components.title"),
                status: .pass,
                summary: L10n.t("hw.components.recorded"),
                rawDetails: componentDetails
            ))
        }

        // 机型标识交叉：hw.model vs system_profiler
        if !spModel.isEmpty && !model.isEmpty && model != spModel {
            results.append(CheckResult(
                id: "hardware.modelIdentity",
                title: L10n.t("hw.model.cross.title"),
                status: .redFlag,
                summary: L10n.t("hw.model.cross.summary", model, spModel),
                rawDetails: ["sysctl hw.model": model, "system_profiler": spModel],
                isRedFlagHeadline: L10n.t("hw.model.cross.headline")
            ))
        }

        return results
    }

    private static func ioKitBatteryMissing() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service == 0 { return true }
        IOObjectRelease(service)
        return false
    }
}
