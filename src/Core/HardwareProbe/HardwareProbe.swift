import Foundation
import IOKit

/// A1: Machine identity via IOKit/sysctl (not About This Mac UI).
/// Serial also cross-checked with system_profiler.
enum HardwareProbe {

    private enum Key {
        static let iokit = "iokit"
        static let sp = "systemProfiler"
        static let board = "board"
        static let modelId = "modelId"
        static let modelCross = "modelCross"
        static let uuid = "uuid"
        static let batt = "battery"
        static let display = "display"
        static let sysctlModel = "sysctlModel"
        static let spModel = "spModel"
    }

    private static let displayKey: [String: String] = [
        Key.iokit: "hw.serial.iokit",
        Key.sp: "hw.serial.sp",
        Key.board: "hw.serial.board",
        Key.modelId: "hw.serial.model_id",
        Key.modelCross: "hw.serial.model_cross",
        Key.uuid: "hw.serial.uuid",
        Key.batt: "hw.serial.batt",
        Key.display: "hw.serial.display",
        Key.sysctlModel: "hw.model.sysctl",
        Key.spModel: "hw.model.sp",
    ]

    private static func localizeDetails(_ raw: [String: String]) -> [String: String] {
        RawDetails.localize(raw, using: displayKey)
    }

    // MARK: - IOKit

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

    // MARK: - sysctl

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

    // MARK: - system_profiler cross-check

    static func systemProfilerHardwareJSON() -> [String: Any] {
        let output = ShellRunner.run("/usr/sbin/system_profiler", ["SPHardwareDataType", "-json"])
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["SPHardwareDataType"] as? [[String: Any]],
              let first = items.first
        else { return [:] }
        return first
    }

    // MARK: - Chip / OS version

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

    /// Structured profile for the home header (shown on launch).
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

    /// Pull a 4-digit year from the marketing name, e.g. "…, 2021" → "2021".
    private static func modelYear(from marketingName: String) -> String {
        if let range = marketingName.range(of: #"20\d{2}"#, options: .regularExpression) {
            return String(marketingName[range])
        }
        return ""
    }

    // MARK: - Component serials (refurb / franken-Mac clues)

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
        // Some built-in panels expose AlphanumericSerialNumber / DisplaySerialNumber under IODisplay
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

    // MARK: - Aggregate checks

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

        // Serial mismatch IOKit vs system_profiler → red flag
        if ioSerial.isEmpty && spSerial.isEmpty {
            results.append(CheckResult(
                id: "hardware.serial",
                title: L10n.t("hw.serial.title"),
                status: .warning,
                summary: L10n.t("hw.serial.missing"),
                rawDetails: localizeDetails([
                    Key.iokit: ioSerial,
                    Key.sp: spSerial,
                ])
            ))
        } else if !ioSerial.isEmpty && !spSerial.isEmpty && ioSerial != spSerial {
            results.append(CheckResult(
                id: "hardware.serial",
                title: L10n.t("hw.serial.title"),
                status: .redFlag,
                summary: L10n.t("hw.serial.mismatch"),
                rawDetails: localizeDetails([
                    Key.iokit: ioSerial,
                    Key.sp: spSerial,
                ]),
                isRedFlagHeadline: L10n.t("hw.serial.mismatch.headline")
            ))
        } else {
            let serial = ioSerial.isEmpty ? spSerial : ioSerial
            let cross = model == spModel || spModel.isEmpty
                ? L10n.t("hw.serial.match")
                : L10n.t("hw.serial.mismatch_fmt", model, spModel)
            var details: [String: String] = [
                Key.board: serial,
                Key.modelId: model,
                Key.modelCross: cross,
            ]
            if !uuid.isEmpty { details[Key.uuid] = uuid }
            results.append(CheckResult(
                id: "hardware.serial",
                title: L10n.t("hw.serial.title"),
                status: .pass,
                summary: L10n.t("hw.serial.ok", serial),
                rawDetails: localizeDetails(details)
            ))
        }

        // Component serials — helps spot swapped board/battery/panel
        var componentDetails: [String: String] = [:]
        if !ioSerial.isEmpty { componentDetails[Key.board] = ioSerial }
        else if !spSerial.isEmpty { componentDetails[Key.board] = spSerial }
        if let battSerial { componentDetails[Key.batt] = battSerial }
        if let displaySerial { componentDetails[Key.display] = displaySerial }
        if !uuid.isEmpty { componentDetails[Key.uuid] = uuid }
        let localizedComponents = localizeDetails(componentDetails)

        let hasBattery = !ioKitBatteryMissing()
        if hasBattery && battSerial == nil {
            results.append(CheckResult(
                id: "hardware.componentSerials",
                title: L10n.t("hw.components.title"),
                status: .warning,
                summary: L10n.t("hw.components.no_batt_serial"),
                rawDetails: localizedComponents
            ))
        } else if componentDetails.count >= 2 {
            let battSuffix = battSerial != nil ? L10n.t("hw.components.battery_suffix") : ""
            let displaySuffix = displaySerial != nil ? L10n.t("hw.components.display_suffix") : ""
            results.append(CheckResult(
                id: "hardware.componentSerials",
                title: L10n.t("hw.components.title"),
                status: .pass,
                summary: L10n.t("hw.components.ok", battSuffix, displaySuffix),
                rawDetails: localizedComponents
            ))
        } else if !componentDetails.isEmpty {
            results.append(CheckResult(
                id: "hardware.componentSerials",
                title: L10n.t("hw.components.title"),
                status: .pass,
                summary: L10n.t("hw.components.recorded"),
                rawDetails: localizedComponents
            ))
        }

        // Model id cross-check: hw.model vs system_profiler
        if !spModel.isEmpty && !model.isEmpty && model != spModel {
            results.append(CheckResult(
                id: "hardware.modelIdentity",
                title: L10n.t("hw.model.cross.title"),
                status: .redFlag,
                summary: L10n.t("hw.model.cross.summary", model, spModel),
                rawDetails: localizeDetails([
                    Key.sysctlModel: model,
                    Key.spModel: spModel,
                ]),
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
