import Charts
import Foundation
import SwiftUI

/// Formal stress duration options (seconds). Default 60; 30 for a quick pass, longer for thermals.
enum PerformanceDuration: Int, CaseIterable, Identifiable {
    case s30 = 30
    case s60 = 60
    case s120 = 120
    case s300 = 300

    var id: Int { rawValue }
    var label: String { L10n.t("common.seconds_format", rawValue) }
    var pickerLabel: String { "\(rawValue)s" }

    static let warmupSeconds = 4
}

enum PerformancePhase: Equatable {
    case idle
    case warming(current: Int, total: Int)
    case measuring(current: Int, total: Int)
}

/// One chart point (seconds since stress start).
struct LoadHistoryPoint: Identifiable, Equatable {
    let id: Int
    let second: Int
    let cpu: Double
    let gpu: Double?
}

/// B12: Multi-core (+ Metal GPU) stress; thermal / SMC; CPU/GPU load charts.
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

    @Published var currentReading: SMCReading?
    @Published var peakTemp: Double?
    @Published var peakRPM: Double?
    @Published var idleReading: SMCReading?

    @Published var cpuPercent: Double = 0
    @Published var gpuPercent: Double?
    @Published var loadHistory: [LoadHistoryPoint] = []
    @Published var peakCPU: Double = 0
    @Published var peakGPU: Double?
    @Published var gpuStressEnabled = false
    @Published var gpuDeviceName: String?

    private var runTask: Task<Void, Never>?
    private var tickTimer: Timer?
    private var phaseContinuation: CheckedContinuation<Void, Never>?
    private var phaseSecond = 0
    private var phaseTotal = 0
    private var phaseRecordMetrics = false
    private var phaseOnTick: ((Int, Int) -> Void)?
    private let cancelFlag = CancelFlag()
    private let opsCounter = OpsCounter()
    private let loadSampler = LoadSampler()
    private let metalStress = MetalStressEngine()
    private var historyIndex = 0
    private var opsWindowStart: DispatchTime = .now()

    /// Stress all logical CPUs; workers briefly yield so RunLoop timers still fire.
    var coreCount: Int { ProcessInfo.processInfo.processorCount }
    var hardwareCoreCount: Int { ProcessInfo.processInfo.processorCount }
    var smcAvailable: Bool { idleReading != nil || currentReading != nil }
    var hasGPUSeries: Bool { loadHistory.contains { $0.gpu != nil } || gpuPercent != nil }

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
        gpuStressEnabled = metalStress.isAvailable
        gpuDeviceName = metalStress.deviceName
        cancelFlag.value = false
        loadSampler.reset()
        runTask = Task { await run() }
    }

    func cancel() {
        cancelFlag.value = true
        metalStress.cancel()
        stopTickTimer()
        runTask?.cancel()
        runTask = nil
        isRunning = false
        phase = .idle
    }

    /// Leave the in-session “finished” UI so the detail pane can show the saved result card.
    func leaveFinishedSession() {
        finished = false
        isRunning = false
        phase = .idle
    }

    private func reset() {
        progress = 0
        elapsed = 0
        opsPerSecond = 0
        thermalSamples = []
        finished = false
        currentReading = nil
        peakTemp = nil
        peakRPM = nil
        phase = .idle
        cpuPercent = 0
        gpuPercent = nil
        loadHistory = []
        peakCPU = 0
        peakGPU = nil
        historyIndex = 0
        opsCounter.reset()
        opsWindowStart = .now()
        gpuStressEnabled = false
        gpuDeviceName = nil
    }

    private func run() async {
        let measureTotal = selectedDuration.rawValue
        idleReading = await Task.detached { SMCService.snapshot() }.value

        startWorkers()
        if gpuStressEnabled {
            metalStress.start()
        }

        let warmupTotal = PerformanceDuration.warmupSeconds
        await runTimedPhase(durationSeconds: warmupTotal, recordMetrics: false) { [weak self] current, total in
            self?.phase = .warming(current: current, total: total)
        }

        guard !Task.isCancelled, !cancelFlag.value else {
            tearDownWorkers()
            isRunning = false
            phase = .idle
            return
        }

        await runTimedPhase(durationSeconds: measureTotal, recordMetrics: true) { [weak self] current, total in
            guard let self else { return }
            self.phase = .measuring(current: current, total: total)
            self.elapsed = current
            self.progress = Double(current) / Double(total)
        }

        // Capture completion before tearDown — tearDown sets cancelFlag to stop workers.
        let completedNormally = !Task.isCancelled && !cancelFlag.value
        tearDownWorkers()
        isRunning = false
        phase = .idle
        finished = completedNormally
    }

    private func startWorkers() {
        let cores = coreCount
        let flag = cancelFlag
        let counter = opsCounter
        opsCounter.reset()
        opsWindowStart = .now()

        // High load on all cores; short yield every few batches keeps UI/timer alive.
        for _ in 0..<cores {
            DispatchQueue.global(qos: .userInitiated).async {
                var batches = 0
                while !flag.value {
                    _ = PerformanceCheckModel.busyCompute(iterations: 250_000)
                    counter.add(250_000)
                    batches += 1
                    if batches & 7 == 0 {
                        usleep(300) // ~0.3 ms — enough for Main RunLoop, still near-full load
                    }
                }
            }
        }
    }

    private func tearDownWorkers() {
        cancelFlag.value = true
        metalStress.cancel()
        stopTickTimer()
    }

    private func stopTickTimer() {
        tickTimer?.invalidate()
        tickTimer = nil
        if let cont = phaseContinuation {
            phaseContinuation = nil
            cont.resume()
        }
    }

    /// Drive phase ticks from a RunLoop timer (not Task.sleep) so UI isn't starved by workers.
    private func runTimedPhase(
        durationSeconds: Int,
        recordMetrics: Bool,
        onTick: @escaping (Int, Int) -> Void
    ) async {
        phaseSecond = 0
        phaseTotal = durationSeconds
        phaseRecordMetrics = recordMetrics
        phaseOnTick = onTick
        onTick(0, durationSeconds)
        sampleSensors(recordMetrics: recordMetrics)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            // Clear any prior timer without resuming (we're about to replace the continuation).
            tickTimer?.invalidate()
            tickTimer = nil
            phaseContinuation = cont

            let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                // Timer is on the main RunLoop — safe to hop onto MainActor without Task.sleep.
                MainActor.assumeIsolated {
                    self?.phaseTickFired()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            tickTimer = timer
        }
        phaseOnTick = nil
    }

    private func phaseTickFired() {
        if Task.isCancelled || cancelFlag.value {
            stopTickTimer()
            return
        }
        phaseSecond += 1
        sampleSensors(recordMetrics: phaseRecordMetrics)
        phaseOnTick?(min(phaseSecond, phaseTotal), phaseTotal)
        if phaseSecond >= phaseTotal {
            stopTickTimer()
        }
    }

    private func sampleSensors(recordMetrics: Bool) {
        // Fast path on main — host_statistics / IOKit must not wait on saturated CPU workers.
        let load = loadSampler.sample()
        cpuPercent = load.cpu
        gpuPercent = load.gpu
        peakCPU = max(peakCPU, load.cpu)
        if let g = load.gpu {
            peakGPU = max(peakGPU ?? 0, g)
        }

        if recordMetrics {
            thermalSamples.append(ProcessInfo.processInfo.thermalState)
        }

        let taken = opsCounter.take()
        let dt = Double(DispatchTime.now().uptimeNanoseconds - opsWindowStart.uptimeNanoseconds) / 1e9
        if dt > 0, taken > 0 {
            opsPerSecond = taken / dt
        }
        opsWindowStart = .now()

        historyIndex += 1
        loadHistory.append(LoadHistoryPoint(
            id: historyIndex,
            second: historyIndex,
            cpu: load.cpu,
            gpu: load.gpu
        ))
        if loadHistory.count > 120 {
            loadHistory.removeFirst(loadHistory.count - 120)
        }

        // SMC can be slower; refresh off the hot path.
        let captureMetrics = recordMetrics
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let reading = SMCService.snapshot()
            DispatchQueue.main.async {
                guard let self, self.isRunning, let reading else { return }
                self.currentReading = reading
                if captureMetrics {
                    if let t = reading.maxTemp { self.peakTemp = max(self.peakTemp ?? 0, t) }
                    if let r = reading.fanRPMs.max() { self.peakRPM = max(self.peakRPM ?? 0, r) }
                }
            }
        }
    }

    /// Pure compute (nonisolated). Return a result-dependent value so it isn't optimized away.
    nonisolated static func busyCompute(iterations: Int) -> Double {
        var acc = 0.0
        var x = 1.000001
        for _ in 0..<iterations {
            x = x * 1.0000001 + 0.0000001
            acc += x.squareRoot()
        }
        return acc
    }

    func buildResult(userReportedIssue: Bool = false) -> CheckResult {
        let worst = worstThermal
        let throttled = worst.severity >= ProcessInfo.ThermalState.serious.severity
        let mops = opsPerSecond / 1_000_000
        var details: [String: String] = [
            "cores": "\(hardwareCoreCount)",
            "duration": L10n.t("check.perf.detail.duration", elapsed, PerformanceDuration.warmupSeconds),
            "throughput": String(format: "%.0f M ops/s", mops),
            "peakThermal": worst.label,
            "samples": thermalSamples.map(\.label).joined(separator: " → "),
            "peakCPU": String(format: "%.0f%%", peakCPU),
        ]
        if gpuStressEnabled {
            details["gpuStress"] = gpuDeviceName ?? L10n.t("common.yes")
        }
        if let peakGPU {
            details["peakGPU"] = String(format: "%.0f%%", peakGPU)
        }
        if let peakTemp {
            details["peakTemp"] = String(format: "%.1f °C", peakTemp)
        }
        if let idle = idleReading?.maxTemp {
            details["idleTemp"] = String(format: "%.1f °C", idle)
        }
        if let peakRPM {
            details["peakFan"] = String(format: "%.0f RPM", peakRPM)
        }
        if userReportedIssue {
            details["userJudge"] = L10n.t("check.perf.user_bad")
        }
        let localizedDetails = RawDetails.localize(details, using: [
            "cores": "check.perf.detail.cores",
            "duration": "check.perf.detail.duration_key",
            "throughput": "check.perf.detail.throughput",
            "peakThermal": "check.perf.detail.peak_thermal",
            "samples": "check.perf.detail.samples",
            "peakTemp": "check.perf.detail.peak_temp",
            "idleTemp": "check.perf.detail.idle_temp",
            "peakFan": "check.perf.detail.peak_fan",
            "peakCPU": "check.perf.detail.peak_cpu",
            "peakGPU": "check.perf.detail.peak_gpu",
            "gpuStress": "check.perf.detail.gpu_stress",
            "userJudge": "check.perf.detail.user_judge",
        ])

        let tempSuffix: String = {
            guard let peakTemp else { return "" }
            let rpm = peakRPM.map { L10n.t("check.perf.fan_suffix", $0) } ?? ""
            return L10n.t("check.perf.temp_suffix", peakTemp, rpm)
        }()

        if userReportedIssue {
            return CheckResult(
                id: "performance",
                title: L10n.t("check.perf.result.title"),
                status: .warning,
                summary: L10n.t("check.perf.result.user_bad", elapsed, worst.label),
                rawDetails: localizedDetails
            )
        }
        if throttled {
            return CheckResult(
                id: "performance",
                title: L10n.t("check.perf.result.title"),
                status: .warning,
                summary: L10n.t("check.perf.result.hot", worst.label, tempSuffix),
                rawDetails: localizedDetails
            )
        }
        return CheckResult(
            id: "performance",
            title: L10n.t("check.perf.result.title"),
            status: .pass,
            summary: L10n.t("check.perf.result.ok", elapsed, worst.label, tempSuffix),
            rawDetails: localizedDetails
        )
    }
}

/// Shared cancel flag for CPU workers (lock-based; safe across concurrency domains).
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

final class OpsCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count: Double = 0
    func add(_ n: Double) {
        lock.lock(); count += n; lock.unlock()
    }
    func take() -> Double {
        lock.lock(); defer { lock.unlock() }
        let v = count; count = 0; return v
    }
    func reset() {
        lock.lock(); count = 0; lock.unlock()
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
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var model = PerformanceCheckModel()
    @State private var sessionActive = false
    let onComplete: (CheckResult) -> Void

    private var existingResult: CheckResult? { appModel.result(id: "performance") }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            CheckHeader(
                icon: "gauge.with.dots.needle.67percent",
                title: L10n.t("check.perf.title"),
                subtitle: L10n.t(
                    "check.perf.subtitle",
                    PerformanceDuration.warmupSeconds,
                    model.hardwareCoreCount
                )
            )

            if sessionActive || model.isRunning || model.finished {
                activeSession
            } else if let result = existingResult {
                PreviousResultCard(result: result)
                Button {
                    beginSession()
                } label: {
                    Label(L10n.t("detail.retest"), systemImage: "arrow.clockwise")
                        .frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                durationPicker
                Button {
                    beginSession()
                } label: {
                    Label(L10n.t("detail.start_test"), systemImage: "play.fill")
                        .frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Button(L10n.t("common.skip")) {
                model.cancel()
                sessionActive = false
                onComplete(CheckResult(
                    id: "performance",
                    title: L10n.t("check.perf.result.title"),
                    status: .skipped,
                    summary: L10n.t("check.perf.skip_summary")
                ))
            }
            .buttonStyle(.bordered)
        }
        .padding(DS.Spacing.xl)
        .checkPane(L10n.t("sidebar.performance"))
        .onDisappear {
            model.cancel()
            sessionActive = false
        }
    }

    @ViewBuilder
    private var activeSession: some View {
        durationPicker
        gauge

        if model.finished {
            InlineNotice(
                icon: model.worstThermal.severity >= 2
                    ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                tint: model.worstThermal.tint,
                text: L10n.t(
                    model.worstThermal.severity >= 2 ? "check.perf.notice.hot" : "check.perf.notice.ok",
                    model.worstThermal.label
                )
            )
        }

        DS.Divider()

        if model.isRunning {
            HStack(spacing: DS.Spacing.md) {
                Button(L10n.t("common.stop")) {
                    model.cancel()
                    sessionActive = false
                }
                .buttonStyle(.bordered)
                ProgressView().controlSize(.small)
                Text(model.phaseCaption).font(DS.Font.caption).foregroundStyle(.secondary)
            }
        } else if model.finished {
            HStack(spacing: DS.Spacing.md) {
                Text(L10n.t("result.label")).font(DS.Font.body).foregroundStyle(.secondary)
                Button(L10n.t("check.perf.ok_btn")) {
                    finish(userReportedIssue: false)
                }
                .buttonStyle(.borderedProminent)
                Button(L10n.t("check.perf.bad_btn")) {
                    finish(userReportedIssue: true)
                }
                .buttonStyle(.bordered)
                Button(L10n.t("check.perf.restart")) {
                    model.start()
                }
                .buttonStyle(.bordered)
            }
        } else {
            Button(L10n.t("check.perf.start")) {
                model.start()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func beginSession() {
        sessionActive = true
        model.start()
    }

    private func finish(userReportedIssue: Bool) {
        onComplete(model.buildResult(userReportedIssue: userReportedIssue))
        model.leaveFinishedSession()
        sessionActive = false
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
                stat(
                    title: L10n.t("check.perf.stat.throughput"),
                    value: model.opsPerSecond > 0
                        ? String(format: "%.0f M/s", model.opsPerSecond / 1_000_000) : "—"
                )
                stat(
                    title: L10n.t("check.perf.stat.thermal"),
                    value: (model.thermalSamples.last ?? .nominal).label,
                    tint: (model.thermalSamples.last ?? .nominal).tint
                )
                Spacer()
            }
            ProgressView(value: model.progress)

            loadChart

            if model.smcAvailable {
                DS.Divider()
                HStack(spacing: DS.Spacing.xl) {
                    stat(
                        title: L10n.t("check.perf.stat.soc"),
                        value: model.currentReading?.maxTemp.map { String(format: "%.0f °C", $0) } ?? "—",
                        tint: tempTint(model.currentReading?.maxTemp)
                    )
                    if let rpm = model.currentReading?.fanRPMs, !rpm.isEmpty {
                        stat(
                            title: rpm.count > 1 ? L10n.t("check.perf.stat.fans") : L10n.t("check.perf.stat.fan"),
                            value: rpm.map { String(format: "%.0f", $0) }.joined(separator: " / ") + " RPM"
                        )
                    }
                    if let peak = model.peakTemp {
                        stat(
                            title: L10n.t("check.perf.stat.peak_temp"),
                            value: String(format: "%.0f °C", peak),
                            tint: tempTint(peak)
                        )
                    }
                    Spacer()
                }
            } else if model.isRunning {
                Text(L10n.t("check.perf.smc_unavailable"))
                    .font(DS.Font.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private var loadChart: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xl) {
                loadPercentLabel(
                    title: L10n.t("check.perf.stat.cpu"),
                    value: model.cpuPercent,
                    tint: .accentColor
                )
                if model.gpuStressEnabled || model.hasGPUSeries {
                    loadPercentLabel(
                        title: L10n.t("check.perf.stat.gpu"),
                        value: model.gpuPercent,
                        tint: .green
                    )
                }
                Spacer()
                if model.gpuStressEnabled, let name = model.gpuDeviceName {
                    Text(name)
                        .font(DS.Font.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Chart {
                ForEach(model.loadHistory) { point in
                    AreaMark(
                        x: .value("t", point.second),
                        yStart: .value("base", 0),
                        yEnd: .value("CPU", point.cpu),
                        series: .value("series", "CPU")
                    )
                    .foregroundStyle(Color.accentColor.opacity(0.22))
                    .interpolationMethod(.linear)

                    LineMark(
                        x: .value("t", point.second),
                        y: .value("CPU", point.cpu),
                        series: .value("series", "CPU")
                    )
                    .foregroundStyle(Color.accentColor)
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                }

                ForEach(model.loadHistory.filter { $0.gpu != nil }) { point in
                    LineMark(
                        x: .value("t", point.second),
                        y: .value("GPU", point.gpu ?? 0),
                        series: .value("series", "GPU")
                    )
                    .foregroundStyle(Color.green)
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(values: [0, 50, 100]) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text("\(Int(v))%")
                                .font(.system(size: 9))
                        }
                    }
                }
            }
            .chartXAxis(.hidden)
            .frame(height: 120)
            .padding(.top, DS.Spacing.xs)
        }
        .padding(.top, DS.Spacing.sm)
    }

    private func loadPercentLabel(title: String, value: Double?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(DS.Font.caption).foregroundStyle(.secondary)
            Text(value.map { String(format: "%.0f%%", $0) } ?? "—")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .monospacedDigit()
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
