import Foundation
import IOKit

/// A3: Storage / SSD checks.
enum StorageService {

    // Stable English keys; localize when building CheckResult.
    private enum Key {
        static let model = "model"
        static let serial = "serial"
        static let firmware = "firmware"
        static let vendor = "vendor"
        static let nvmeVer = "nvme_ver"
        static let interconnect = "interconnect"
        static let location = "location"
        static let encryption = "encryption"
        static let medium = "medium"
        static let smartCap = "smart_cap"
        static let smartDetail = "smart_detail"
        static let temp = "temp"
        static let lifeUsed = "life_used"
        static let spare = "spare"
        static let powerHours = "power_hours"
        static let powerCycles = "power_cycles"
        static let unsafe = "unsafe"
        static let mediaErr = "media_err"
        static let read = "read"
        static let write = "write"
        static let critical = "critical"
        static let volSize = "vol_size"
        static let nominal = "nominal"
        static let free = "free"
        static let pcie = "pcie"
        static let trim = "trim"
        static let smartStatus = "smart_status"
    }

    private static let displayKey: [String: String] = [
        Key.model: "storage.d.model",
        Key.serial: "storage.d.serial",
        Key.firmware: "storage.d.firmware",
        Key.vendor: "storage.d.vendor",
        Key.nvmeVer: "storage.d.nvme_ver",
        Key.interconnect: "storage.d.interconnect",
        Key.location: "storage.d.location",
        Key.encryption: "storage.d.encryption",
        Key.medium: "storage.d.medium",
        Key.smartCap: "storage.d.smart_cap",
        Key.smartDetail: "storage.d.smart_detail",
        Key.temp: "storage.d.temp",
        Key.lifeUsed: "storage.d.life_used",
        Key.spare: "storage.d.spare",
        Key.powerHours: "storage.d.power_hours",
        Key.powerCycles: "storage.d.power_cycles",
        Key.unsafe: "storage.d.unsafe",
        Key.mediaErr: "storage.d.media_err",
        Key.read: "storage.d.read",
        Key.write: "storage.d.write",
        Key.critical: "storage.d.critical",
        Key.volSize: "storage.d.vol_size",
        Key.nominal: "storage.d.nominal",
        Key.free: "storage.d.free",
        Key.pcie: "storage.d.pcie",
        Key.trim: "storage.d.trim",
        Key.smartStatus: "storage.d.smart_status",
    ]

    private static func localizeDetails(_ raw: [String: String]) -> [String: String] {
        RawDetails.localize(raw, using: displayKey)
    }

    // MARK: - system_profiler

    private static func nvmeDrives() -> [[String: Any]] {
        let output = ShellRunner.run("/usr/sbin/system_profiler", ["SPNVMeDataType", "-json"])
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = json["SPNVMeDataType"] as? [[String: Any]]
        else { return [] }
        return controllers.flatMap { ($0["_items"] as? [[String: Any]]) ?? [] }
    }

    // MARK: - Capacity

    private static func volumeCapacities() -> (total: Int64?, free: Int64?) {
        let url = URL(fileURLWithPath: "/")
        let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        return (values?.volumeTotalCapacity.map(Int64.init),
                values?.volumeAvailableCapacityForImportantUsage)
    }

    private static func gb(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }

    private static func tbOrGb(_ bytes: UInt64) -> String {
        let tb = Double(bytes) / 1_000_000_000_000
        if tb >= 1 {
            return String(format: "%.2f TB", tb)
        }
        return String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }

    // MARK: - IORegistry extras

    private static func registryDetails() -> [String: String] {
        var details: [String: String] = [:]

        if let ctrl = firstServiceProperties(className: "AppleANS2Controller")
            ?? firstServiceProperties(className: "AppleNVMeController")
            ?? firstServiceProperties(className: "IONVMeController") {
            if let model = ctrl["Model Number"] as? String { details[Key.model] = model }
            if let serial = ctrl["Serial Number"] as? String { details[Key.serial] = serial }
            if let fw = ctrl["Firmware Revision"] as? String { details[Key.firmware] = fw }
            if let vendor = ctrl["Vendor Name"] as? String, !vendor.isEmpty {
                details[Key.vendor] = vendor
            }
            if let rev = ctrl["NVMe Revision Supported"] as? String {
                details[Key.nvmeVer] = rev
            }
            if let interconnect = ctrl["Physical Interconnect"] as? String {
                details[Key.interconnect] = interconnect
            }
            if let location = ctrl["Physical Interconnect Location"] as? String {
                details[Key.location] = location
            }
            if let chars = ctrl["Controller Characteristics"] as? [String: Any],
               let enc = chars["Encryption Type"] as? String {
                details[Key.encryption] = enc
            }
        }

        if let block = firstServiceProperties(className: "IONVMeBlockStorageDevice") {
            if let device = block["Device Characteristics"] as? [String: Any] {
                if details[Key.model] == nil, let name = device["Product Name"] as? String {
                    details[Key.model] = name
                }
                if details[Key.serial] == nil, let serial = device["Serial Number"] as? String {
                    details[Key.serial] = serial
                }
                if details[Key.firmware] == nil, let rev = device["Product Revision Level"] as? String {
                    details[Key.firmware] = rev
                }
                if let medium = device["Medium Type"] as? String {
                    details[Key.medium] = medium
                }
            }
            if let proto = block["Protocol Characteristics"] as? [String: Any] {
                if details[Key.interconnect] == nil,
                   let interconnect = proto["Physical Interconnect"] as? String {
                    details[Key.interconnect] = interconnect
                }
                if details[Key.location] == nil,
                   let location = proto["Physical Interconnect Location"] as? String {
                    details[Key.location] = location
                }
            }
            if block["NVMe SMART Capable"] as? Bool == true {
                details[Key.smartCap] = L10n.t("storage.d.smart_cap_yes")
            }
        }

        return details
    }

    private static func firstServiceProperties(className: String) -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(className))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var propsUnmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propsUnmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = propsUnmanaged?.takeRetainedValue() as? [String: Any]
        else { return nil }
        return props
    }

    // MARK: - NVMe SMART（IOKit）

    private struct SMARTInfo {
        var details: [String: String] = [:]
        var critical = false
        var summaryBits: [String] = []
        var didRead = false
    }

    private static func readSMART() -> SMARTInfo {
        var snap = MacInspectNVMeSMARTSnapshot()
        guard MacInspectReadNVMeSMART(&snap) != 0, snap.available != 0 else {
            return SMARTInfo(details: [
                Key.smartDetail: L10n.t("storage.d.smart_na"),
            ])
        }

        var info = SMARTInfo(didRead: true)
        if let model = cString(from: snap.model), !model.isEmpty { info.details[Key.model] = model }
        if let serial = cString(from: snap.serial), !serial.isEmpty { info.details[Key.serial] = serial }
        if let fw = cString(from: snap.firmware), !fw.isEmpty { info.details[Key.firmware] = fw }

        info.details[Key.temp] = String(format: "%.0f °C", snap.temperatureC)
        info.details[Key.lifeUsed] = "\(snap.percentageUsed)%"
        info.details[Key.spare] = L10n.t("storage.d.spare_fmt",
                                         Int(snap.availableSpare),
                                         Int(snap.availableSpareThreshold))
        info.details[Key.powerHours] = L10n.t("storage.d.power_hours_fmt", Int(snap.powerOnHours))
        info.details[Key.powerCycles] = "\(snap.powerCycles)"
        info.details[Key.unsafe] = "\(snap.unsafeShutdowns)"
        info.details[Key.mediaErr] = "\(snap.mediaErrors)"
        info.details[Key.read] = tbOrGb(snap.dataUnitsReadBytes)
        info.details[Key.write] = tbOrGb(snap.dataUnitsWrittenBytes)
        info.details[Key.critical] = snap.criticalWarning == 0
            ? L10n.t("storage.d.critical_none")
            : String(format: "0x%02X", snap.criticalWarning)

        info.summaryBits = [
            String(format: "%.0f°C", snap.temperatureC),
            L10n.t("storage.life_bit", Int(snap.percentageUsed)),
        ]

        info.critical = snap.criticalWarning != 0
            || snap.mediaErrors > 0
            || (snap.availableSpareThreshold > 0 && snap.availableSpare < snap.availableSpareThreshold)
            || snap.percentageUsed >= 90
        return info
    }

    private static func cString<T>(from tuple: T) -> String? {
        withUnsafeBytes(of: tuple) { raw -> String? in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return nil }
            let s = String(cString: base)
            return s.isEmpty ? nil : s
        }
    }

    // MARK: - Aggregate

    static func runAll() -> [CheckResult] {
        let drives = nvmeDrives()
        let registry = registryDetails()
        let smart = readSMART()
        let (totalBytes, freeBytes) = volumeCapacities()

        if drives.isEmpty && registry.isEmpty && !smart.didRead {
            return [CheckResult(
                id: "storage",
                title: L10n.t("storage.title_short"),
                status: .unsupported,
                summary: L10n.t("storage.unsupported")
            )]
        }

        let profiler = drives.first
        let model = firstNonEmpty(
            registry[Key.model],
            smart.details[Key.model],
            profiler?["device_model"] as? String,
            profiler?["_name"] as? String
        ) ?? L10n.t("storage.unknown_ssd")

        let smartStatus = (profiler?["smart_status"] as? String) ?? ""
        let trim = (profiler?["spnvme_trim_support"] as? String) ?? ""
        let linkSpeed = profiler?["spnvme_linkspeed"] as? String ?? ""
        let linkWidth = profiler?["spnvme_linkwidth"] as? String ?? ""
        let sizeFromProfiler = profiler?["size"] as? String ?? ""

        var details: [String: String] = [:]
        details[Key.model] = model
        if let v = firstNonEmpty(registry[Key.serial], smart.details[Key.serial], profiler?["device_serial"] as? String) {
            details[Key.serial] = v
        }
        if let v = firstNonEmpty(registry[Key.firmware], smart.details[Key.firmware], profiler?["device_revision"] as? String) {
            details[Key.firmware] = v
        }
        if let v = registry[Key.vendor] { details[Key.vendor] = v }
        if let v = registry[Key.medium] { details[Key.medium] = v }
        if let v = registry[Key.nvmeVer] { details[Key.nvmeVer] = v }

        if let totalBytes {
            details[Key.volSize] = gb(totalBytes)
        } else if !sizeFromProfiler.isEmpty {
            details[Key.nominal] = sizeFromProfiler
        }
        if let freeBytes {
            details[Key.free] = gb(freeBytes)
        }

        if !linkSpeed.isEmpty || !linkWidth.isEmpty {
            details[Key.pcie] = [linkSpeed, linkWidth].filter { !$0.isEmpty }.joined(separator: " · ")
        } else if let v = registry[Key.interconnect] {
            details[Key.interconnect] = v
        }
        if let v = registry[Key.location] { details[Key.location] = v }
        if !trim.isEmpty { details[Key.trim] = trim }
        if let v = registry[Key.encryption] { details[Key.encryption] = v }
        if let v = registry[Key.smartCap] { details[Key.smartCap] = v }
        if !smartStatus.isEmpty { details[Key.smartStatus] = smartStatus }

        for key in [
            Key.temp, Key.lifeUsed, Key.spare, Key.powerHours, Key.powerCycles,
            Key.unsafe, Key.mediaErr, Key.read, Key.write, Key.critical,
            Key.smartDetail,
        ] {
            if let v = smart.details[key] { details[key] = v }
        }

        let statusVerified = smartStatus.isEmpty || smartStatus.lowercased() == "verified"
        let unhealthy = !statusVerified || smart.critical

        let sizeText = details[Key.volSize] ?? sizeFromProfiler
        var summaryParts: [String] = [model]
        if !sizeText.isEmpty { summaryParts.append(sizeText) }
        if statusVerified {
            if smart.didRead, !smart.summaryBits.isEmpty {
                summaryParts.append(L10n.t("storage.smart_ok_bits", smart.summaryBits.joined(separator: " · ")))
            } else {
                summaryParts.append(smartStatus.isEmpty ? L10n.t("storage.smart_na_short") : L10n.t("storage.smart_ok"))
            }
        } else {
            summaryParts.append(L10n.t("storage.smart_bad", smartStatus))
        }

        let localized = localizeDetails(details)

        if unhealthy {
            let reason: String
            if !statusVerified {
                reason = L10n.t("storage.reason.status", smartStatus)
            } else {
                reason = L10n.t("storage.reason.metrics")
            }
            return [CheckResult(
                id: "storage",
                title: L10n.t("storage.title"),
                status: .redFlag,
                summary: reason,
                rawDetails: localized,
                isRedFlagHeadline: L10n.t("storage.headline")
            )]
        }

        return [CheckResult(
            id: "storage",
            title: L10n.t("storage.title"),
            status: .pass,
            summary: summaryParts.joined(separator: " · "),
            rawDetails: localized
        )]
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            if let value, !value.isEmpty { return value }
        }
        return nil
    }
}
