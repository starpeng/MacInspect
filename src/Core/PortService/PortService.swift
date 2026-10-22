import Foundation

/// B5: Enumerate devices on USB / Thunderbolt ports for per-port connectivity checks.
enum PortService {

    private enum Key {
        static let usb = "usb"
        static let tb = "thunderbolt"
    }

    private static let displayKey: [String: String] = [
        Key.usb: "ports.usb",
        Key.tb: "ports.tb",
    ]

    private static func flatten(_ items: [[String: Any]], into names: inout [String]) {
        for item in items {
            if let name = item["_name"] as? String {
                names.append(name)
            }
            if let children = item["_items"] as? [[String: Any]] {
                flatten(children, into: &names)
            }
        }
    }

    private static func usbDevices() -> [String] {
        let output = ShellRunner.run("/usr/sbin/system_profiler", ["SPUSBDataType", "-json"])
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = json["SPUSBDataType"] as? [[String: Any]]
        else { return [] }
        var names: [String] = []
        for root in roots {
            if let children = root["_items"] as? [[String: Any]] {
                flatten(children, into: &names)
            }
        }
        return names
    }

    private static func thunderboltDevices() -> [String] {
        let output = ShellRunner.run("/usr/sbin/system_profiler", ["SPThunderboltDataType", "-json"])
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = json["SPThunderboltDataType"] as? [[String: Any]]
        else { return [] }
        var names: [String] = []
        for root in roots {
            if let children = root["_items"] as? [[String: Any]] {
                flatten(children, into: &names)
            }
        }
        return names
    }

    static func runAll() -> [CheckResult] {
        let usb = usbDevices()
        let tb = thunderboltDevices()
        let sep = AppLanguage.current.resolvedCode.hasPrefix("zh") ? "、" : ", "

        let details: [String: String] = [
            Key.usb: usb.isEmpty ? L10n.t("ports.none") : usb.joined(separator: sep),
            Key.tb: tb.isEmpty ? L10n.t("ports.none") : tb.joined(separator: sep),
        ]

        let total = usb.count + tb.count
        let summary = total == 0
            ? L10n.t("ports.summary.empty")
            : L10n.t("ports.summary.ok", total)

        return [CheckResult(
            id: "ports",
            title: L10n.t("ports.title"),
            status: .pass,
            summary: summary,
            rawDetails: RawDetails.localize(details, using: displayKey)
        )]
    }
}
