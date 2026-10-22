import Foundation
import CoreWLAN

/// A8/B7-8: Wi-Fi via CoreWLAN; Bluetooth controller via system_profiler.
enum NetworkService {

    private enum Key {
        static let power = "power"
        static let mac = "mac"
        static let ssid = "ssid"
        static let rssi = "rssi"
        static let rate = "rate"
        static let band = "band"
        static let note = "note"
        static let btState = "btState"
        static let btChip = "btChip"
        static let btAddress = "btAddress"
        static let btDevices = "btDevices"
    }

    private static let displayKey: [String: String] = [
        Key.power: "net.wifi.power",
        Key.mac: "net.wifi.mac",
        Key.ssid: "net.wifi.ssid",
        Key.rssi: "net.wifi.rssi",
        Key.rate: "net.wifi.rate",
        Key.band: "net.wifi.band",
        Key.note: "net.wifi.note",
        Key.btState: "net.bt.state",
        Key.btChip: "net.bt.chip",
        Key.btAddress: "net.bt.address",
        Key.btDevices: "net.bt.devices",
    ]

    private static func localizeDetails(_ raw: [String: String]) -> [String: String] {
        RawDetails.localize(raw, using: displayKey)
    }

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
        details[Key.power] = powerOn ? L10n.t("net.wifi.on") : L10n.t("net.wifi.off")
        if let hw = iface.hardwareAddress() { details[Key.mac] = hw }

        let ssid = iface.ssid()
        let rssi = iface.rssiValue()
        if let ssid {
            details[Key.ssid] = ssid
            details[Key.rssi] = "\(rssi) dBm"
            details[Key.rate] = "\(iface.transmitRate()) Mbps"
            details[Key.band] = phyModeString(iface.activePHYMode())
            let quality = signalQuality(rssi)
            return CheckResult(
                id: "network.wifi",
                title: L10n.t("net.wifi.title"),
                status: .pass,
                summary: L10n.t("net.wifi.summary.ssid", ssid, rssi, quality),
                rawDetails: localizeDetails(details)
            )
        }

        if powerOn, rssi < 0 {
            details[Key.ssid] = L10n.t("net.wifi.ssid_hidden")
            details[Key.rssi] = "\(rssi) dBm"
            details[Key.rate] = "\(iface.transmitRate()) Mbps"
            details[Key.band] = phyModeString(iface.activePHYMode())
            details[Key.note] = L10n.t("net.wifi.note_location")
            let quality = signalQuality(rssi)
            return CheckResult(
                id: "network.wifi",
                title: L10n.t("net.wifi.title"),
                status: .pass,
                summary: L10n.t("net.wifi.summary.hidden", rssi, quality),
                rawDetails: localizeDetails(details)
            )
        }

        return CheckResult(
            id: "network.wifi",
            title: L10n.t("net.wifi.title"),
            status: powerOn ? .pass : .warning,
            summary: powerOn ? L10n.t("net.wifi.summary.idle") : L10n.t("net.wifi.summary.off"),
            rawDetails: localizeDetails(details)
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
        case .modeNone: return L10n.t("net.wifi.phy.none")
        @unknown default:
            // kCWPHYMode11be = 7; not in macOS 15 SDK (CI Xcode 16.4), present in macOS 26+.
            if mode.rawValue == 7 { return "802.11be (Wi-Fi 7)" }
            return L10n.t("common.unknown")
        }
    }

    // MARK: - Bluetooth

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
            Key.btState: isOn ? L10n.t("net.wifi.on") : L10n.t("net.wifi.off"),
            Key.btChip: chipset,
            Key.btAddress: address,
        ]
        if let connected = first["device_connected"] as? [[String: Any]] {
            details[Key.btDevices] = "\(connected.count)"
        }

        return CheckResult(
            id: "network.bluetooth",
            title: L10n.t("net.bt.title"),
            status: isOn ? .pass : .warning,
            summary: isOn ? L10n.t("net.bt.summary.on", chipset) : L10n.t("net.bt.summary.off"),
            rawDetails: localizeDetails(details)
        )
    }

    static func runAll() -> [CheckResult] {
        [wifiResult(), bluetoothResult()]
    }
}
