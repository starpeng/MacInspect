import Foundation
import CoreWLAN

/// A8/B7-8：无线连接。Wi-Fi 当前连接信息走 CoreWLAN（原生框架），蓝牙控制器状态走 system_profiler。
enum NetworkService {

    // MARK: - Wi-Fi

    private static func wifiResult() -> CheckResult {
        guard let iface = CWWiFiClient.shared().interface() else {
            return CheckResult(
                id: "network.wifi",
                title: L10n.t("net.wifi.title"),
                status: .unsupported,
                summary: L10n.t("net.wifi.none")
            )
        }

        var details: [String: String] = [:]
        let powerOn = iface.powerOn()
        details[L10n.t("net.wifi.power")] = powerOn ? L10n.t("net.wifi.on") : L10n.t("net.wifi.off")
        if let hw = iface.hardwareAddress() { details[L10n.t("net.wifi.mac")] = hw }

        let ssid = iface.ssid()
        let rssi = iface.rssiValue()
        if let ssid {
            details[L10n.t("net.wifi.ssid")] = ssid
            details[L10n.t("net.wifi.rssi")] = "\(rssi) dBm"
            details[L10n.t("net.wifi.rate")] = "\(iface.transmitRate()) Mbps"
            details[L10n.t("net.wifi.band")] = phyModeString(iface.activePHYMode())
            let quality = signalQuality(rssi)
            return CheckResult(
                id: "network.wifi",
                title: L10n.t("net.wifi.title"),
                status: .pass,
                summary: L10n.t("net.wifi.summary.ssid", ssid, rssi, quality),
                rawDetails: details
            )
        }

        if powerOn, rssi < 0 {
            details[L10n.t("net.wifi.ssid")] = L10n.t("net.wifi.ssid_hidden")
            details[L10n.t("net.wifi.rssi")] = "\(rssi) dBm"
            details[L10n.t("net.wifi.rate")] = "\(iface.transmitRate()) Mbps"
            details[L10n.t("net.wifi.band")] = phyModeString(iface.activePHYMode())
            details[L10n.t("net.wifi.note")] = L10n.t("net.wifi.note_location")
            let quality = signalQuality(rssi)
            return CheckResult(
                id: "network.wifi",
                title: L10n.t("net.wifi.title"),
                status: .pass,
                summary: L10n.t("net.wifi.summary.hidden", rssi, quality),
                rawDetails: details
            )
        }

        return CheckResult(
            id: "network.wifi",
            title: L10n.t("net.wifi.title"),
            status: powerOn ? .pass : .warning,
            summary: powerOn ? L10n.t("net.wifi.summary.idle") : L10n.t("net.wifi.summary.off"),
            rawDetails: details
        )
    }

    private static func signalQuality(_ rssi: Int) -> String {
        if rssi >= -60 { return L10n.t("net.wifi.q.good") }
        if rssi >= -75 { return L10n.t("net.wifi.q.ok") }
        return L10n.t("net.wifi.q.weak")
    }

    private static func phyModeString(_ mode: CWPHYMode) -> String {
        switch mode {
        case .mode11a: return "802.11a"
        case .mode11b: return "802.11b"
        case .mode11g: return "802.11g"
        case .mode11n: return "802.11n (Wi-Fi 4)"
        case .mode11ac: return "802.11ac (Wi-Fi 5)"
        case .mode11ax: return "802.11ax (Wi-Fi 6/6E)"
        // mode11be exists only in the arm64 CoreWLAN SDK; omit for x86_64 CI builds.
        #if arch(arm64)
        case .mode11be: return "802.11be (Wi-Fi 7)"
        #endif
        case .modeNone: return L10n.t("net.wifi.phy.none")
        @unknown default: return L10n.t("common.unknown")
        }
    }

    // MARK: - 蓝牙

    private static func bluetoothResult() -> CheckResult {
        let output = ShellRunner.run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"])
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["SPBluetoothDataType"] as? [[String: Any]],
              let first = items.first,
              let ctrl = first["controller_properties"] as? [String: Any]
        else {
            return CheckResult(
                id: "network.bluetooth",
                title: L10n.t("net.bt.title"),
                status: .warning,
                summary: L10n.t("net.bt.fail")
            )
        }

        let state = (ctrl["controller_state"] as? String) ?? ""
        let chipset = (ctrl["controller_chipset"] as? String) ?? ""
        let address = (ctrl["controller_address"] as? String) ?? ""
        let isOn = state.contains("on")

        var details: [String: String] = [
            L10n.t("net.bt.state"): isOn ? L10n.t("net.wifi.on") : L10n.t("net.wifi.off"),
            L10n.t("net.bt.chip"): chipset,
            L10n.t("net.bt.address"): address,
        ]
        if let connected = first["device_connected"] as? [[String: Any]] {
            details[L10n.t("net.bt.devices")] = "\(connected.count)"
        }

        return CheckResult(
            id: "network.bluetooth",
            title: L10n.t("net.bt.title"),
            status: isOn ? .pass : .warning,
            summary: isOn ? L10n.t("net.bt.summary.on", chipset) : L10n.t("net.bt.summary.off"),
            rawDetails: details
        )
    }

    static func runAll() -> [CheckResult] {
        [wifiResult(), bluetoothResult()]
    }
}
