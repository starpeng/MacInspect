import Foundation

/// B5：接口枚举。列出当前通过 USB / 雷雳(Thunderbolt) 接口连接的设备，帮助用户逐口验证接口连通性。
enum PortService {

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

        var details: [String: String] = [:]
        details[L10n.t("ports.usb")] = usb.isEmpty ? L10n.t("ports.none") : usb.joined(separator: sep)
        details[L10n.t("ports.tb")] = tb.isEmpty ? L10n.t("ports.none") : tb.joined(separator: sep)

        let total = usb.count + tb.count
        let summary = total == 0
            ? L10n.t("ports.summary.empty")
            : L10n.t("ports.summary.ok", total)

        return [CheckResult(
            id: "ports",
            title: L10n.t("ports.title"),
            status: .pass,
            summary: summary,
            rawDetails: details
        )]
    }
}
