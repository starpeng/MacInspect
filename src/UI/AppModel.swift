import Foundation

/// 侧边栏导航项。概览 + 系统自动检测分类 + 硬件交互测试。
enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case overview
    // 系统自动检测
    case specs, battery, security, storage, network, ports
    // 硬件交互测试
    case keyboard, screen, audio, microphone, camera, touchID, trackpad, performance, diskSpeed, portsLive
    case aiModels
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return L10n.t("sidebar.overview")
        case .specs: return L10n.t("sidebar.specs")
        case .battery: return L10n.t("sidebar.battery")
        case .security: return L10n.t("sidebar.security")
        case .storage: return L10n.t("sidebar.storage")
        case .network: return L10n.t("sidebar.network")
        case .ports: return L10n.t("sidebar.ports")
        case .keyboard: return L10n.t("sidebar.keyboard")
        case .screen: return L10n.t("sidebar.screen")
        case .audio: return L10n.t("sidebar.audio")
        case .microphone: return L10n.t("sidebar.microphone")
        case .camera: return L10n.t("sidebar.camera")
        case .touchID: return L10n.t("sidebar.touchid")
        case .trackpad: return L10n.t("sidebar.trackpad")
        case .performance: return L10n.t("sidebar.performance")
        case .diskSpeed: return L10n.t("sidebar.disk_speed")
        case .portsLive: return L10n.t("sidebar.ports_live")
        case .aiModels: return L10n.t("sidebar.ai")
        case .settings: return L10n.t("sidebar.settings")
        }
    }

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2.fill"
        case .specs: return "cpu.fill"
        case .battery: return "battery.100.bolt"
        case .security: return "lock.shield.fill"
        case .storage: return "internaldrive.fill"
        case .network: return "wifi"
        case .ports: return "cable.connector"
        case .keyboard: return "keyboard.fill"
        case .screen: return "display"
        case .audio: return "speaker.wave.3.fill"
        case .microphone: return "mic.fill"
        case .camera: return "camera.fill"
        case .touchID: return "touchid"
        case .trackpad: return "rectangle.and.hand.point.up.left.fill"
        case .performance: return "gauge.with.dots.needle.67percent"
        case .diskSpeed: return "speedometer"
        case .portsLive: return "cable.connector.horizontal"
        case .aiModels: return "sparkles"
        case .settings: return "gearshape.fill"
        }
    }

    var isInteractive: Bool {
        switch self {
        case .keyboard, .screen, .audio, .microphone, .camera, .touchID, .trackpad, .performance, .diskSpeed, .portsLive: return true
        default: return false
        }
    }

    /// 需要全屏接管的测试（其余交互测试在详情面板内进行）。
    var needsFullscreen: Bool { self == .keyboard || self == .screen }

    /// 该分类对应的结果 id（用于聚合状态与详情展示）。
    var resultIDs: [String] {
        switch self {
        case .overview, .specs: return []
        case .battery: return [
            "battery.cycleCount", "battery.health",
            "battery.cycleCount.crosscheck", "battery.capacity.crosscheck", "battery.capacity.integrity",
        ]
        case .security: return [
            "hardware.serial", "hardware.componentSerials", "hardware.modelIdentity",
            "hardware.securityChip", "management.mdm", "management.appleID", "management.activationLock",
        ]
        case .storage: return ["storage"]
        case .network: return ["network.wifi", "network.bluetooth"]
        case .ports: return ["ports"]
        case .keyboard: return ["keyboard"]
        case .screen: return ["screen"]
        case .audio: return ["audio"]
        case .microphone: return ["microphone"]
        case .camera: return ["camera"]
        case .touchID: return ["touchID"]
        case .trackpad: return ["trackpad"]
        case .performance: return ["performance"]
        case .diskSpeed: return ["diskSpeed"]
        case .portsLive: return ["portsLive"]
        case .aiModels: return []
        case .settings: return []
        }
    }

    static let autoCategories: [SidebarItem] = [.specs, .battery, .security, .storage, .network, .ports]
    static let interactiveTests: [SidebarItem] = [.keyboard, .screen, .audio, .microphone, .camera, .touchID, .trackpad, .performance, .diskSpeed, .portsLive]
}

enum FullscreenTest: Identifiable {
    case keyboard, screen
    var id: String { self == .keyboard ? "keyboard" : "screen" }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var selection: SidebarItem? = .overview
    @Published var fullscreenTest: FullscreenTest?
    @Published var isScanning = true
    @Published var profile: DeviceProfile?
    @Published private(set) var autoResults: [String: CheckResult] = [:]
    @Published private(set) var testResults: [String: CheckResult] = [:]
    @Published var generatedAt = Date()

    private var hasScanned = false

    private static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.0"
    }

    func scanIfNeeded() async {
        guard !hasScanned else { return }
        await rescan()
    }

    func rescan() async {
        isScanning = true
        let (profile, results) = await Task.detached(priority: .userInitiated) { () -> (DeviceProfile, [CheckResult]) in
            let p = HardwareProbe.buildProfile()
            var all: [CheckResult] = []
            all.append(contentsOf: HardwareProbe.runAll())
            all.append(contentsOf: SecurityChipService.runAll())
            all.append(contentsOf: BatteryService.runAll())
            all.append(contentsOf: ManagementService.runAll())
            all.append(contentsOf: StorageService.runAll())
            all.append(contentsOf: NetworkService.runAll())
            all.append(contentsOf: PortService.runAll())
            return (p, all)
        }.value
        self.profile = profile
        self.autoResults = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })
        self.generatedAt = Date()
        self.isScanning = false
        self.hasScanned = true
    }

    func recordTest(_ result: CheckResult) {
        testResults[result.id] = result
        generatedAt = Date()
    }

    func result(id: String) -> CheckResult? {
        autoResults[id] ?? testResults[id]
    }

    func results(for item: SidebarItem) -> [CheckResult] {
        item.resultIDs.compactMap { result(id: $0) }
    }

    /// 分类聚合状态：取该分类下最严重的一项；无结果返回 nil（交互测试尚未进行）。
    func status(for item: SidebarItem) -> CheckStatus? {
        let statuses = results(for: item).map(\.status)
        guard !statuses.isEmpty else { return nil }
        if statuses.contains(.redFlag) { return .redFlag }
        if statuses.contains(.warning) { return .warning }
        if statuses.allSatisfy({ $0 == .skipped || $0 == .unsupported }) { return statuses.first }
        return .pass
    }

    var allResults: [CheckResult] {
        var ordered: [CheckResult] = []
        for item in SidebarItem.autoCategories + SidebarItem.interactiveTests {
            ordered.append(contentsOf: results(for: item))
        }
        return ordered
    }

    var report: MacInspectReport {
        var rep = MacInspectReport(generatedAt: generatedAt, appVersion: Self.appVersion)
        rep.results = allResults
        return rep
    }

    var completedTestCount: Int { SidebarItem.interactiveTests.filter { status(for: $0) != nil }.count }
}
