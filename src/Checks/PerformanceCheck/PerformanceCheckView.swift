import SwiftUI
import Foundation

/// Formal stress duration options (seconds). Default 60; 30 for a quick pass, longer for thermals.
enum PerformanceDuration: Int, CaseIterable, Identifiable {
    case s30 = 30
    case s60 = 60
    case s120 = 120
    case s300 = 300

    var id: Int { rawValue }
    /// Full label for reports / detail rows.
    var label: String { L10n.t("common.seconds_format", rawValue) }
    /// Compact segmented-control label (4 segments need short text).
    var pickerLabel: String { "\(rawValue)s" }

    /// Warmup seconds (not counted in formal measurement).
    static let warmupSeconds = 4
}

/// 压测阶段：预热满载但不计入正式时长与结果采样。
enum PerformancePhase: Equatable {
    case idle
    case warming(current: Int, total: Int)
    case measuring(current: Int, total: Int)
}

/// B12：性能压力测试。多核满载计算若干秒，监测热状态（ProcessInfo.thermalState 公开 API，
/// 无需 SMC 私有 key），识别散热异常/降频。给出相对吞吐评分。
@MainActor
final class PerformanceCheckModel: ObservableObject {
    @Published var isRunning = false
    @Published var progress: Double = 0
    @Published var elapsed: Int = 0
    @Published var opsPerSecond: Double = 0
    @Published var thermalSamples: [ProcessInfo.ThermalState] = []
    @Published var finished = false
    @Published var selectedDuration: PerformanceDuration = .s60
    @Published var phase: PerformancePhase = .idle

    // SMC 精确温度/风扇
    @Published var currentReading: SMCReading?
    @Published var peakTemp: Double?
    @Published var peakRPM: Double?
    @Published var idleReading: SMCReading?   // 压测前的静置读数，用于对比升温

    private var task: Task<Void, Never>?

    var coreCount: Int { ProcessInfo.processInfo.activeProcessorCount }
    var smcAvailable: Bool { idleReading != nil || currentReading != nil }

    var worstThermal: ProcessInfo.ThermalState {
        thermalSamples.max(by: { $0.severity < $1.severity }) ?? .nominal
    }

    var phaseCaption: String {
        switch phase {
        case .idle:
            return ""
        case .warming(let current, let total):
            return L10n.t("check.perf.warming", current, total)
        case .measuring(let current, let total):
            return L10n.t("check.perf.measuring", current, total)
        }
    }

    func start() {
        guard !isRunning else { return }
        reset()
        isRunning = true
        task = Task { await run() }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
        phase = .idle
    }

    private func reset() {
        progress = 0; elapsed = 0; opsPerSecond = 0; thermalSamples = []; finished = false
        currentReading = nil; peakTemp = nil; peakRPM = nil
        phase = .idle
    }

    private func run() async {
        let measureTotal = selectedDuration.rawValue
        // 记录静置基线温度
        idleReading = await Task.detached { SMCService.snapshot() }.value

        // —— 预热：墙钟时间满载，不计入正式时长与结果采样 ——
        let warmupTotal = PerformanceDuration.warmupSeconds
        await runTimedPhase(durationSeconds: warmupTotal, recordMetrics: false) { current, total in
            phase = .warming(current: current, total: total)
        }

        guard !Task.isCancelled else {
            isRunning = false
            phase = .idle
            return
        }

        // —— 正式测量：按墙钟跑满所选秒数（高性能机也会真实跑满，而非按轮次提前结束）——
        await runTimedPhase(durationSeconds: measureTotal, recordMetrics: true) { current, total in
            phase = .measuring(current: current, total: total)
            elapsed = current
            progress = Double(current) / Double(total)
        }

        isRunning = false
        phase = .idle
        finished = !Task.isCancelled
    }

    /// 按墙钟持续满载 `durationSeconds` 秒；约每秒采样一次传感器。
    private func runTimedPhase(
        durationSeconds: Int,
        recordMetrics: Bool,
        onTick: (Int, Int) -> Void
    ) async {
        let cores = coreCount
        let start = DispatchTime.now()
        let deadline = start + .seconds(durationSeconds)
        var lastSampleSecond = -1

        onTick(0, durationSeconds)

        while DispatchTime.now() < deadline {
            if Task.isCancelled { break }
            await runLoadBatch(cores: cores)

            let wallElapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
            let second = min(durationSeconds, Int(wallElapsed))
            if second > lastSampleSecond {
                lastSampleSecond = second
                await sampleSensors(recordMetrics: recordMetrics)
                onTick(second, durationSeconds)
            }
        }

        guard !Task.isCancelled else { return }
        if lastSampleSecond < durationSeconds {
            await sampleSensors(recordMetrics: recordMetrics)
        }
        onTick(durationSeconds, durationSeconds)
    }

    /// 一轮全核计算负载，更新吞吐显示。
    private func runLoadBatch(cores: Int) async {
        let start = DispatchTime.now()
        let ops = await withTaskGroup(of: Double.self) { group -> Double in
            for _ in 0..<cores {
                group.addTask { PerformanceCheckModel.busyCompute(iterations: 4_000_000) }
            }
            var sum = 0.0
            for await r in group { sum += r }
            return sum
        }
        let dt = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
        _ = ops
        let opsCount = Double(cores) * 4_000_000
        self.opsPerSecond = dt > 0 ? opsCount / dt : 0
    }

    /// 读取热状态与 SMC；正式阶段写入峰值与热采样，预热仅刷新当前读数。
    private func sampleSensors(recordMetrics: Bool) async {
        let reading = await Task.detached { SMCService.snapshot() }.value
        if let reading {
            self.currentReading = reading
            if recordMetrics {
                if let t = reading.maxTemp { self.peakTemp = max(self.peakTemp ?? 0, t) }
                if let r = reading.fanRPMs.max() { self.peakRPM = max(self.peakRPM ?? 0, r) }
            }
        }
        if recordMetrics {
            self.thermalSamples.append(ProcessInfo.processInfo.thermalState)
        }
    }

    /// 纯计算负载（nonisolated，跑在后台线程）。返回一个依赖结果的值防止被优化掉。
    nonisolated static func busyCompute(iterations: Int) -> Double {
        var acc = 0.0
        var x = 1.000001
        for _ in 0..<iterations {
            x = x * 1.0000001 + 0.0000001
            acc += x.squareRoot()
        }
        return acc
    }

    func buildResult() -> CheckResult {
        let worst = worstThermal
        let throttled = worst.severity >= ProcessInfo.ThermalState.serious.severity
        let mops = opsPerSecond / 1_000_000
        var details: [String: String] = [
            L10n.t("check.perf.detail.cores"): "\(coreCount)",
            L10n.t("check.perf.detail.duration_key"):
                L10n.t("check.perf.detail.duration", elapsed, PerformanceDuration.warmupSeconds),
            L10n.t("check.perf.detail.throughput"): String(format: "%.0f M ops/s", mops),
            L10n.t("check.perf.detail.peak_thermal"): worst.label,
        ]
        details[L10n.t("check.perf.detail.samples")] = thermalSamples.map(\.label).joined(separator: " → ")
        if let peakTemp {
            details[L10n.t("check.perf.detail.peak_temp")] = String(format: "%.1f °C", peakTemp)
        }
        if let idle = idleReading?.maxTemp {
            details[L10n.t("check.perf.detail.idle_temp")] = String(format: "%.1f °C", idle)
        }
        if let peakRPM {
            details[L10n.t("check.perf.detail.peak_fan")] = String(format: "%.0f RPM", peakRPM)
        }

        let tempSuffix: String = {
            guard let peakTemp else { return "" }
            let rpm = peakRPM.map { L10n.t("check.perf.fan_suffix", $0) } ?? ""
            return L10n.t("check.perf.temp_suffix", peakTemp, rpm)
        }()

        if throttled {
            return CheckResult(
                id: "performance",
                title: L10n.t("check.perf.result.title"),
                status: .warning,
                summary: L10n.t("check.perf.result.hot", worst.label, tempSuffix),
                rawDetails: details
            )
        }
        return CheckResult(
            id: "performance",
            title: L10n.t("check.perf.result.title"),
            status: .pass,
            summary: L10n.t("check.perf.result.ok", elapsed, worst.label, tempSuffix),
            rawDetails: details
        )
    }
}

extension ProcessInfo.ThermalState {
    var severity: Int {
        switch self {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        @unknown default: return 0
        }
    }
    var label: String {
        switch self {
        case .nominal: return L10n.t("thermal.nominal")
        case .fair: return L10n.t("thermal.fair")
        case .serious: return L10n.t("thermal.serious")
        case .critical: return L10n.t("thermal.critical")
        @unknown default: return L10n.t("thermal.unknown")
        }
    }
    var tint: Color {
        switch self {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        @unknown default: return .secondary
        }
    }
}

struct PerformanceCheckView: View {
    @StateObject private var model = PerformanceCheckModel()
    let onComplete: (CheckResult) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            CheckHeader(
                icon: "gauge.with.dots.needle.67percent",
                title: L10n.t("check.perf.title"),
                subtitle: L10n.t("check.perf.subtitle", PerformanceDuration.warmupSeconds, model.coreCount)
            )

            durationPicker

            gauge

            if model.finished {
                InlineNotice(icon: model.worstThermal.severity >= 2 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                             tint: model.worstThermal.tint,
                             text: L10n.t(model.worstThermal.severity >= 2 ? "check.perf.notice.hot" : "check.perf.notice.ok",
                                          model.worstThermal.label))
            }

            DS.Divider()

            HStack(spacing: DS.Spacing.md) {
                if model.isRunning {
                    Button(L10n.t("common.stop")) { model.cancel() }.buttonStyle(.bordered)
                    ProgressView().controlSize(.small)
                    Text(model.phaseCaption).font(DS.Font.caption).foregroundStyle(.secondary)
                } else {
                    Button(model.finished ? L10n.t("check.perf.restart") : L10n.t("check.perf.start")) { model.start() }
                        .buttonStyle(.borderedProminent)
                    if model.finished {
                        Button(L10n.t("check.perf.save")) { onComplete(model.buildResult()) }
                            .buttonStyle(.bordered)
                    }
                }
            }

            Button(L10n.t("common.skip")) {
                model.cancel()
                onComplete(CheckResult(id: "performance", title: L10n.t("check.perf.result.title"), status: .skipped,
                    summary: L10n.t("check.perf.skip_summary")))
            }
            .buttonStyle(.bordered)
        }
        .padding(DS.Spacing.xl)
        .checkPane(L10n.t("sidebar.performance"))
        .onDisappear { model.cancel() }
    }

    private var durationPicker: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text(L10n.t("check.perf.duration")).font(DS.Font.caption).foregroundStyle(.secondary)
            Picker(L10n.t("check.perf.duration"), selection: $model.selectedDuration) {
                ForEach(PerformanceDuration.allCases) { option in
                    Text(option.pickerLabel).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            .disabled(model.isRunning)
        }
    }

    private var gauge: some View {
        Card {
            HStack(spacing: DS.Spacing.xl) {
                stat(title: L10n.t("check.perf.stat.progress"), value: progressLabel)
                stat(title: L10n.t("check.perf.stat.throughput"),
                     value: model.opsPerSecond > 0 ? String(format: "%.0f M/s", model.opsPerSecond / 1_000_000) : "—")
                stat(title: L10n.t("check.perf.stat.thermal"),
                     value: (model.thermalSamples.last ?? .nominal).label,
                     tint: (model.thermalSamples.last ?? .nominal).tint)
                Spacer()
            }
            ProgressView(value: model.progress)

            // SMC 精确温度 / 风扇
            if model.smcAvailable {
                DS.Divider()
                HStack(spacing: DS.Spacing.xl) {
                    stat(title: L10n.t("check.perf.stat.soc"),
                         value: model.currentReading?.maxTemp.map { String(format: "%.0f °C", $0) } ?? "—",
                         tint: tempTint(model.currentReading?.maxTemp))
                    if let rpm = model.currentReading?.fanRPMs, !rpm.isEmpty {
                        stat(title: rpm.count > 1 ? L10n.t("check.perf.stat.fans") : L10n.t("check.perf.stat.fan"),
                             value: rpm.map { String(format: "%.0f", $0) }.joined(separator: " / ") + " RPM")
                    }
                    if let peak = model.peakTemp {
                        stat(title: L10n.t("check.perf.stat.peak_temp"),
                             value: String(format: "%.0f °C", peak), tint: tempTint(peak))
                    }
                    Spacer()
                }
            } else if model.isRunning {
                Text(L10n.t("check.perf.smc_unavailable"))
                    .font(DS.Font.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private var progressLabel: String {
        if case .warming = model.phase { return L10n.t("check.perf.warmup_short") }
        return "\(Int(model.progress * 100))%"
    }

    private func tempTint(_ t: Double?) -> Color {
        guard let t else { return .primary }
        if t >= 95 { return .red }
        if t >= 85 { return .orange }
        return .green
    }

    private func stat(title: String, value: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(DS.Font.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 18, weight: .semibold)).foregroundStyle(tint)
        }
    }
}
