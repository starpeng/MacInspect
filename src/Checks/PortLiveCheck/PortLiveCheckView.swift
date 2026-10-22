import SwiftUI
import IOKit
import IOKit.usb

/// B5+：接口逐口实测。定时枚举 USB 设备并与上一帧差分，实时输出插入/拔出事件与速率，
/// 引导用户依次插入每个物理接口逐口验证。用轮询差分而非 C 回调桥接（避开 Swift 6 并发陷阱）。
@MainActor
final class PortLiveMonitor: ObservableObject {
    struct Event: Identifiable {
        let id = UUID()
        let time: String
        let inserted: Bool
        let name: String
        let speed: String
    }

    @Published var events: [Event] = []
    @Published var currentDevices: [String] = []
    @Published var isMonitoring = false

    private var previous: Set<String> = []
    private var timer: Timer?
    private var startedBaseline = false

    func start() {
        guard timer == nil else { return }
        isMonitoring = true
        // 先建立基线（当前已连接的设备不算"新插入"）
        previous = Set(Self.enumerate().map(\.key))
        startedBaseline = true
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        isMonitoring = false
    }

    func reset() {
        events.removeAll()
        previous = Set(Self.enumerate().map(\.key))
    }

    private func tick() {
        let now = Self.enumerate()
        let nowKeys = Set(now.map(\.key))
        let inserted = nowKeys.subtracting(previous)
        let removed = previous.subtracting(nowKeys)

        for key in inserted {
            if let dev = now.first(where: { $0.key == key }) {
                events.insert(Event(time: Self.timestamp(), inserted: true, name: dev.name, speed: dev.speed), at: 0)
            }
        }
        for key in removed {
            let name = key.components(separatedBy: "|").first ?? key
            events.insert(Event(time: Self.timestamp(), inserted: false, name: name, speed: ""), at: 0)
        }
        previous = nowKeys
        currentDevices = now.map { "\($0.name) · \($0.speed)" }
    }

    /// 事件数（插入）——用于统计验证了多少次接入。
    var insertCount: Int { events.filter(\.inserted).count }

    // MARK: - IOKit 枚举

    private struct Dev { let key: String; let name: String; let speed: String }

    private static func enumerate() -> [Dev] {
        var result: [Dev] = []
        var iterator: io_iterator_t = 0
        // 现代 macOS 用 IOUSBHostDevice
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return [] }
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            let name = stringProp(service, "USB Product Name")
                ?? stringProp(service, "Product Name")
                ?? registryName(service)
            guard let name, !name.isEmpty else { continue }
            let speed = speedLabel(intProp(service, "Device Speed"))
            let locationID = intProp(service, "locationID") ?? 0
            // key 用 名称+locationID 保证不同口的同名设备也能区分
            result.append(Dev(key: "\(name)|\(locationID)", name: name, speed: speed))
        }
        return result
    }

    private static func stringProp(_ service: io_service_t, _ key: String) -> String? {
        guard let cf = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else { return nil }
        return cf.takeRetainedValue() as? String
    }

    private static func intProp(_ service: io_service_t, _ key: String) -> Int? {
        guard let cf = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else { return nil }
        return (cf.takeRetainedValue() as? NSNumber)?.intValue
    }

    private static func registryName(_ service: io_service_t) -> String? {
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: 128)
        defer { buffer.deallocate() }
        guard IORegistryEntryGetName(service, buffer) == KERN_SUCCESS else { return nil }
        return String(cString: buffer)
    }

    private static func speedLabel(_ speed: Int?) -> String {
        switch speed {
        case 0: return L10n.t("check.ports_live.speed.usb1")
        case 1: return L10n.t("check.ports_live.speed.usb11")
        case 2: return L10n.t("check.ports_live.speed.usb2")
        case 3: return "USB 3.0 (5 Gbps)"
        case 4: return "USB 3.1 (10 Gbps)"
        case 5: return "USB 3.2 (20 Gbps)"
        default: return L10n.t("check.ports_live.speed.unknown")
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}

struct PortLiveCheckView: View {
    @StateObject private var monitor = PortLiveMonitor()
    let onComplete: (CheckResult) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            CheckHeader(
                icon: "cable.connector.horizontal",
                title: L10n.t("check.ports_live.title"),
                subtitle: L10n.t("check.ports_live.subtitle")
            )

            Card {
                HStack {
                    Circle().fill(monitor.isMonitoring ? .green : .secondary).frame(width: 8, height: 8)
                    Text(monitor.isMonitoring ? L10n.t("check.ports_live.listening") : L10n.t("check.ports_live.idle"))
                        .font(DS.Font.body).foregroundStyle(.secondary)
                    Spacer()
                    Text(L10n.t("check.ports_live.captured", monitor.insertCount)).font(DS.Font.caption).foregroundStyle(.secondary)
                }
                if monitor.events.isEmpty {
                    Text(L10n.t("check.ports_live.empty")).font(DS.Font.caption).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, DS.Spacing.md)
                } else {
                    ForEach(monitor.events.prefix(12)) { e in
                        HStack(spacing: DS.Spacing.sm) {
                            Image(systemName: e.inserted ? "arrow.down.circle.fill" : "arrow.up.circle")
                                .foregroundStyle(e.inserted ? .green : .secondary)
                            Text(e.time).font(DS.Font.mono).foregroundStyle(.secondary)
                            Text(e.inserted ? L10n.t("check.ports_live.in") : L10n.t("check.ports_live.out")).font(DS.Font.bodyEmphasis)
                            Text(e.name).font(DS.Font.body).lineLimit(1)
                            Spacer()
                            if !e.speed.isEmpty {
                                Text(e.speed).font(DS.Font.caption).foregroundStyle(.blue)
                            }
                        }
                    }
                }
            }

            DS.Divider()

            HStack(spacing: DS.Spacing.md) {
                if monitor.isMonitoring {
                    Button(L10n.t("check.ports_live.stop")) { monitor.stop() }.buttonStyle(.bordered)
                    Button(L10n.t("check.ports_live.clear")) { monitor.reset() }.buttonStyle(.bordered)
                } else {
                    Button(L10n.t("check.ports_live.start")) { monitor.start() }.buttonStyle(.borderedProminent)
                }
                Spacer()
                Button(L10n.t("check.ports_live.ok_btn")) {
                    finish(pass: true)
                }.buttonStyle(.borderedProminent).disabled(monitor.insertCount == 0)
                Button(L10n.t("check.ports_live.bad_btn")) { finish(pass: false) }.buttonStyle(.bordered)
            }

            Button(L10n.t("common.skip")) {
                monitor.stop()
                onComplete(CheckResult(
                    id: "portsLive",
                    title: L10n.t("check.ports_live.title"),
                    status: .skipped,
                    summary: L10n.t("check.ports_live.skip_summary")
                ))
            }
            .buttonStyle(.bordered)
        }
        .padding(DS.Spacing.xl)
        .checkPane(L10n.t("check.ports_live.title"))
        .onDisappear { monitor.stop() }
    }

    private func finish(pass: Bool) {
        monitor.stop()
        let names = monitor.events.filter(\.inserted).map { "\($0.name) (\($0.speed))" }
        onComplete(CheckResult(
            id: "portsLive",
            title: L10n.t("check.ports_live.title"),
            status: pass ? .pass : .warning,
            summary: pass
                ? L10n.t("check.ports_live.ok", monitor.insertCount)
                : L10n.t("check.ports_live.bad"),
            rawDetails: names.isEmpty ? [:] : [L10n.t("check.ports_live.detail.log"): names.joined(separator: "; ")]
        ))
    }
}
