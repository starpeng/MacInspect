import Foundation
import IOKit

/// A1: Machine identity via IOKit/sysctl (not About This Mac UI).
/// Serial also cross-checked with system_profiler.
enum HardwareProbe {

    private enum Key {
        static let iokit = "iokit"
        static let sp = "systemProfiler"
        static let platformSerial = "platformSerial"
        static let modelId = "modelId"
        static let modelCross = "modelCross"
        static let modelNumber = "modelNumber"
        static let boardID = "boardID"
        static let uuid = "uuid"
        static let batt = "battery"
        static let display = "display"
        static let sysctlModel = "sysctlModel"
        static let spModel = "spModel"
        static let specsChip = "specsChip"
        static let actualChip = "actualChip"
        static let specsModelNo = "specsModelNo"
    }

    private static let displayKey: [String: String] = [
        Key.iokit: "hw.serial.iokit",
        Key.sp: "hw.serial.sp",
        Key.platformSerial: "hw.serial.platform",
        Key.modelId: "hw.serial.model_id",
        Key.modelCross: "hw.serial.model_cross",
        Key.modelNumber: "hw.serial.model_number",
        Key.boardID: "hw.serial.board_id",
        Key.uuid: "hw.serial.uuid",
        Key.batt: "hw.serial.batt",
        Key.display: "hw.serial.display",
        Key.sysctlModel: "hw.model.sysctl",
        Key.spModel: "hw.model.sp",
        Key.specsChip: "hw.specs.chip",
        Key.actualChip: "hw.specs.actual_chip",
        Key.specsModelNo: "hw.specs.model_no",
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

    /// Human-usable board identity.
    /// Intel: classic `Mac-…` board-id. Apple Silicon: board code (`J316cAP` / `target-type`),
    /// not the opaque device-tree `board-id` blob (often `0a000000`).
    static func boardID() -> String {
        boardIdentity().display
    }

    struct BoardIdentity: Sendable {
        /// Value shown in UI / reports.
        var display: String
        /// Apple Silicon board code (e.g. J316cAP), when available.
        var boardCode: String
        /// `target-type` (e.g. J316c), when available.
        var targetType: String
        /// Classic Intel-style board-id (`Mac-…`), when available.
        var legacyBoardID: String
    }

    static func boardIdentity() -> BoardIdentity {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        var boardCode = ""
        var targetType = ""
        var legacy = ""
        if service != 0 {
            defer { IOObjectRelease(service) }
            var nameBuf = [CChar](repeating: 0, count: 128)
            if IORegistryEntryGetName(service, &nameBuf) == KERN_SUCCESS {
                let name = String(cString: nameBuf).trimmingCharacters(in: .whitespacesAndNewlines)
                if looksLikeBoardCode(name) { boardCode = name }
            }
            if let t = stringProperty(service, "target-type"), !t.isEmpty {
                targetType = t
            }
            if boardCode.isEmpty, let compatible = stringProperty(service, "compatible") {
                // First token is often J316cAP on Apple Silicon.
                let first = compatible.split(separator: ",").first.map(String.init)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if looksLikeBoardCode(first) { boardCode = first }
            }
            if let bid = stringProperty(service, "board-id") ?? dataPropertyAsUsefulBoardID(service, "board-id") {
                if isClassicMacBoardID(bid) {
                    legacy = bid
                }
            }
        }
        if legacy.isEmpty {
            let fromTree = classicBoardIDFromIoreg()
            if isClassicMacBoardID(fromTree) { legacy = fromTree }
        }

        // Prefer readable board code on Apple Silicon; classic Mac- id on Intel.
        let display: String
        if !boardCode.isEmpty {
            if !targetType.isEmpty, !boardCode.localizedCaseInsensitiveContains(targetType) {
                display = "\(boardCode) (\(targetType))"
            } else {
                display = boardCode
            }
        } else if !targetType.isEmpty {
            display = targetType
        } else if !legacy.isEmpty {
            display = legacy
        } else {
            display = ""
        }
        return BoardIdentity(
            display: display,
            boardCode: boardCode,
            targetType: targetType,
            legacyBoardID: legacy
        )
    }

    private static func looksLikeBoardCode(_ value: String) -> Bool {
        // e.g. J316cAP, MacBookPro18,2 is model id — board codes are usually alnum without comma.
        let s = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count >= 4, s.count <= 32, !s.contains(",") else { return false }
        guard s.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0) }) else {
            return false
        }
        // Board codes often end with AP (Apple Silicon) or look like Mac-… (handled separately).
        return s.hasSuffix("AP") || s.hasSuffix("ap") || (s.first?.isLetter == true && s.contains(where: \.isNumber))
    }

    private static func isClassicMacBoardID(_ value: String) -> Bool {
        let s = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.hasPrefix("Mac-") && s.count > 8
    }

    private static func stringProperty(_ service: io_service_t, _ key: String) -> String? {
        guard let cfValue = IORegistryEntryCreateCFProperty(
            service, key as CFString, kCFAllocatorDefault, 0
        ) else { return nil }
        let value = cfValue.takeRetainedValue()
        if let s = value as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let data = value as? Data, !data.isEmpty {
            if let asString = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines)),
               !asString.isEmpty {
                return asString
            }
        }
        return nil
    }

    /// Only returns classic `Mac-…` style values from Data/hex — never opaque AS blobs.
    private static func dataPropertyAsUsefulBoardID(_ service: io_service_t, _ key: String) -> String? {
        guard let cfValue = IORegistryEntryCreateCFProperty(
            service, key as CFString, kCFAllocatorDefault, 0
        ) else { return nil }
        let value = cfValue.takeRetainedValue()
        if let s = value as? String, isClassicMacBoardID(s) { return s }
        if let data = value as? Data,
           let asString = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines)),
           isClassicMacBoardID(asString) {
            return asString
        }
        return nil
    }

    private static func classicBoardIDFromIoreg() -> String {
        let output = ShellRunner.run("/usr/sbin/ioreg", ["-p", "IODeviceTree", "-k", "board-id", "-r"])
        guard let range = output.range(of: "\"board-id\"") else { return "" }
        let tail = output[range.upperBound...]
        if let angleStart = tail.firstIndex(of: "<"),
           let angleEnd = tail[angleStart...].firstIndex(of: ">") {
            let inner = String(tail[tail.index(after: angleStart)..<angleEnd])
                .replacingOccurrences(of: "\"", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if isClassicMacBoardID(inner) { return inner }
        }
        return ""
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

    /// Official Model Number (Axxxx) from SPHardwareDataType.
    static func modelNumber(from sp: [String: Any]? = nil) -> String {
        let hardware = sp ?? systemProfilerHardwareJSON()
        if let raw = hardware["model_number"] as? String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let match = trimmed.range(of: #"A\d{4,5}"#, options: .regularExpression) {
                return String(trimmed[match])
            }
            if trimmed.hasPrefix("A") { return trimmed }
        }
        return ""
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
        let modelNo = modelNumber(from: sp)
        let chip = chipString()
        let board = boardID()
        let specs = MacSpecsDatabase.lookup(identifier: identifier)
            ?? MacSpecsDatabase.lookup(modelNo: modelNo)
        return DeviceProfile(
            marketingName: marketing,
            modelIdentifier: identifier,
            chip: chip,
            memory: String(format: "%.0f GB", physicalMemoryGB().rounded()),
            macOSVersion: macOSVersionString(),
            serialNumber: serial,
            architecture: isAppleSiliconHardware() ? "Apple Silicon (arm64)" : "Intel (x86_64)",
            modelYear: modelYear(from: marketing),
            productionDate: SerialDecoder.productionDescription(serial: serial),
            graphics: GraphicsProbe.profileEntries(),
            modelNumber: modelNo.isEmpty ? (specs?.model_no ?? "") : modelNo,
            boardID: board,
            specsChip: specs?.chip ?? "",
            specsScreen: specs?.screen ?? "",
            specsName: specs?.name ?? ""
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
        let modelNo = modelNumber(from: sp)
        let board = boardIdentity()
        let chip = chipString()
        let specs = MacSpecsDatabase.lookup(identifier: model)
            ?? MacSpecsDatabase.lookup(modelNo: modelNo)

        // One card: platform serial cross-check + component serials (battery / display / UUID).
        var serialDetails: [String: String] = [:]
        if !ioSerial.isEmpty { serialDetails[Key.iokit] = ioSerial }
        if !spSerial.isEmpty { serialDetails[Key.sp] = spSerial }
        let platformSerial = !ioSerial.isEmpty ? ioSerial : spSerial
        if !platformSerial.isEmpty { serialDetails[Key.platformSerial] = platformSerial }
        if !model.isEmpty { serialDetails[Key.modelId] = model }
        if !modelNo.isEmpty { serialDetails[Key.modelNumber] = modelNo }
        if !board.display.isEmpty { serialDetails[Key.boardID] = board.display }
        if !uuid.isEmpty { serialDetails[Key.uuid] = uuid }
        if let battSerial { serialDetails[Key.batt] = battSerial }
        if let displaySerial { serialDetails[Key.display] = displaySerial }
        let modelCross = model == spModel || spModel.isEmpty || model.isEmpty
            ? L10n.t("hw.serial.match")
            : L10n.t("hw.serial.mismatch_fmt", model, spModel)
        if !model.isEmpty || !spModel.isEmpty {
            serialDetails[Key.modelCross] = modelCross
        }

        let hasBattery = !ioKitBatteryMissing()
        let serialMismatch = !ioSerial.isEmpty && !spSerial.isEmpty && ioSerial != spSerial
        let serialMissing = platformSerial.isEmpty
        let batterySerialMissing = hasBattery && battSerial == nil

        let status: CheckStatus
        let summary: String
        let headline: String?
        if serialMismatch {
            status = .redFlag
            summary = L10n.t("hw.serial.mismatch")
            headline = L10n.t("hw.serial.mismatch.headline")
        } else if serialMissing {
            status = .warning
            summary = L10n.t("hw.serial.missing")
            headline = nil
        } else if batterySerialMissing {
            status = .warning
            summary = L10n.t("hw.components.no_batt_serial")
            headline = nil
        } else {
            status = .pass
            let battSuffix = battSerial != nil ? L10n.t("hw.components.battery_suffix") : ""
            let displaySuffix = displaySerial != nil ? L10n.t("hw.components.display_suffix") : ""
            summary = L10n.t("hw.serial.ok_merged", platformSerial, battSuffix, displaySuffix)
            headline = nil
        }

        results.append(CheckResult(
            id: "hardware.serial",
            title: L10n.t("hw.serial.title"),
            status: status,
            summary: summary,
            rawDetails: localizeDetails(serialDetails),
            isRedFlagHeadline: headline
        ))

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

        // Board identity (AS board code / Intel Mac-… — not opaque device-tree blobs)
        var boardDetails: [String: String] = [:]
        if !board.display.isEmpty { boardDetails[Key.boardID] = board.display }
        if !board.boardCode.isEmpty { boardDetails["boardCode"] = board.boardCode }
        if !board.targetType.isEmpty { boardDetails["targetType"] = board.targetType }
        if !board.legacyBoardID.isEmpty { boardDetails["legacyBoardID"] = board.legacyBoardID }
        let boardDisplayKeys: [String: String] = [
            Key.boardID: "hw.serial.board_id",
            "boardCode": "hw.board.code",
            "targetType": "hw.board.target_type",
            "legacyBoardID": "hw.board.legacy_id",
        ]
        if board.display.isEmpty {
            results.append(CheckResult(
                id: "hardware.boardID",
                title: L10n.t("hw.board.title"),
                status: .warning,
                summary: L10n.t("hw.board.missing"),
                rawDetails: [:]
            ))
        } else {
            results.append(CheckResult(
                id: "hardware.boardID",
                title: L10n.t("hw.board.title"),
                status: .pass,
                summary: L10n.t("hw.board.ok", board.display),
                rawDetails: RawDetails.localize(boardDetails, using: boardDisplayKeys)
            ))
        }

        // Specs library / A-number chip cross-check
        results.append(specsCrossCheckResult(
            identifier: model,
            modelNo: modelNo,
            actualChip: chip,
            specs: specs
        ))

        return results
    }

    private static func specsCrossCheckResult(
        identifier: String,
        modelNo: String,
        actualChip: String,
        specs: MacSpecsEntry?
    ) -> CheckResult {
        var details: [String: String] = [:]
        if !modelNo.isEmpty { details[Key.modelNumber] = modelNo }
        if !identifier.isEmpty { details[Key.modelId] = identifier }
        if !actualChip.isEmpty { details[Key.actualChip] = actualChip }

        if let err = MacSpecsDatabase.loadError {
            return CheckResult(
                id: "hardware.specs",
                title: L10n.t("hw.specs.title"),
                status: .warning,
                summary: L10n.t("hw.specs.load_failed"),
                rawDetails: ["error": err]
            )
        }

        guard let specs else {
            let summary: String
            if modelNo.isEmpty {
                summary = L10n.t("hw.specs.no_model_number")
            } else {
                summary = L10n.t("hw.specs.unknown_model", identifier.isEmpty ? modelNo : identifier)
            }
            return CheckResult(
                id: "hardware.specs",
                title: L10n.t("hw.specs.title"),
                status: .warning,
                summary: summary,
                rawDetails: localizeDetails(details)
            )
        }

        if !specs.model_no.isEmpty { details[Key.specsModelNo] = specs.model_no }
        if !specs.chip.isEmpty { details[Key.specsChip] = specs.chip }

        let displayNo = modelNo.isEmpty ? specs.model_no : modelNo
        if MacSpecsDatabase.chipFamiliesMismatch(actual: actualChip, expected: specs.chip) {
            return CheckResult(
                id: "hardware.specs",
                title: L10n.t("hw.specs.title"),
                status: .warning,
                summary: L10n.t("hw.specs.chip_mismatch", displayNo, specs.chip, actualChip),
                rawDetails: localizeDetails(details),
                isRedFlagHeadline: L10n.t("hw.specs.chip_mismatch.headline")
            )
        }

        var parts: [String] = []
        if !displayNo.isEmpty { parts.append(displayNo) }
        if !specs.chip.isEmpty { parts.append(specs.chip) }
        if !specs.board.isEmpty { parts.append(specs.board) }
        if !specs.screen.isEmpty { parts.append(specs.screen) }
        let joined = parts.joined(separator: " · ")
        return CheckResult(
            id: "hardware.specs",
            title: L10n.t("hw.specs.title"),
            status: .pass,
            summary: joined.isEmpty ? L10n.t("hw.specs.ok_generic") : L10n.t("hw.specs.ok", joined),
            rawDetails: localizeDetails(details)
        )
    }

    private static func ioKitBatteryMissing() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service == 0 { return true }
        IOObjectRelease(service)
        return false
    }
}
