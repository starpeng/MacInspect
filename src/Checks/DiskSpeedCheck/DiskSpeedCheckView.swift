import SwiftUI
import Foundation

/// A3+: Sequential write then read 1 GB, repeated 3 times; report the average MB/s.
/// Reads use `F_NOCACHE` so we measure disk, not page cache.
@MainActor
final class DiskSpeedCheckModel: ObservableObject {
    @Published var isRunning = false
    @Published var phase = ""
    @Published var progress = 0.0
    @Published var writeMBps: Double?
    @Published var readMBps: Double?
    @Published var finished = false
    @Published var errorText: String?
    @Published var currentRound = 0

    static let runCount = 3
    private let totalBytes = 1024 * 1024 * 1024
    private let chunkBytes = 32 * 1024 * 1024
    private var task: Task<Void, Never>?
    private(set) var writeSamples: [Double] = []
    private(set) var readSamples: [Double] = []

    private struct ProgressEvent: Sendable {
        let writing: Bool
        let fraction: Double
    }

    func start() {
        guard !isRunning else { return }
        writeMBps = nil
        readMBps = nil
        progress = 0
        finished = false
        errorText = nil
        currentRound = 0
        writeSamples = []
        readSamples = []
        isRunning = true
        task = Task { await run() }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    /// Leave the in-session “finished” UI so the detail pane can show the saved result card.
    func leaveFinishedSession() {
        finished = false
        isRunning = false
        phase = ""
        progress = 0
    }

    private func run() async {
        let runs = Self.runCount
        var writes: [Double] = []
        var reads: [Double] = []

        for round in 1...runs {
            if Task.isCancelled { break }
            currentRound = round

            let path = NSTemporaryDirectory() + "macinspect_speedtest_\(UUID().uuidString).bin"
            let total = totalBytes
            let chunk = chunkBytes
            let roundIndex = round - 1
            let writeLabel = L10n.t("check.disk.writing_round", round, runs)
            let readLabel = L10n.t("check.disk.reading_round", round, runs)

            let (stream, cont) = AsyncStream.makeStream(of: ProgressEvent.self)
            let work = Task.detached { () -> Result<(Double, Double), DiskError> in
                defer { cont.finish() }
                do {
                    let w = try DiskSpeedCheckModel.measure(path: path, total: total, chunk: chunk, writing: true) {
                        cont.yield(ProgressEvent(writing: true, fraction: $0))
                    }
                    let r = try DiskSpeedCheckModel.measure(path: path, total: total, chunk: chunk, writing: false) {
                        cont.yield(ProgressEvent(writing: false, fraction: $0))
                    }
                    try? FileManager.default.removeItem(atPath: path)
                    return .success((w, r))
                } catch let e as DiskError {
                    try? FileManager.default.removeItem(atPath: path)
                    return .failure(e)
                } catch {
                    try? FileManager.default.removeItem(atPath: path)
                    return .failure(.io)
                }
            }

            for await event in stream {
                if Task.isCancelled {
                    work.cancel()
                    break
                }
                phase = event.writing ? writeLabel : readLabel
                let base = Double(roundIndex) / Double(runs)
                let half = 0.5 / Double(runs)
                progress = event.writing
                    ? base + event.fraction * half
                    : base + half + event.fraction * half
            }

            switch await work.value {
            case .success(let (w, r)):
                writes.append(w)
                reads.append(r)
                writeSamples = writes
                readSamples = reads
                writeMBps = writes.reduce(0, +) / Double(writes.count)
                readMBps = reads.reduce(0, +) / Double(reads.count)
            case .failure(let e):
                errorText = e.description
                isRunning = false
                return
            }
        }

        if !Task.isCancelled, !writes.isEmpty, !reads.isEmpty {
            writeMBps = writes.reduce(0, +) / Double(writes.count)
            readMBps = reads.reduce(0, +) / Double(reads.count)
            writeSamples = writes
            readSamples = reads
            finished = true
            progress = 1
            phase = L10n.t("check.disk.done_avg", runs)
        }
        isRunning = false
    }

    enum DiskError: Error, CustomStringConvertible {
        case open, io
        var description: String {
            switch self {
            case .open: return L10n.t("check.disk.err.open")
            case .io: return L10n.t("check.disk.err.io")
            }
        }
    }

    nonisolated static func measure(
        path: String,
        total: Int,
        chunk: Int,
        writing: Bool,
        progress: (Double) -> Void
    ) throws -> Double {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 4096)
        defer { buffer.deallocate() }
        if writing { memset(buffer, 0xA5, chunk) }

        let flags = writing ? (O_WRONLY | O_CREAT | O_TRUNC) : O_RDONLY
        let fd = open(path, flags, 0o644)
        guard fd >= 0 else { throw DiskError.open }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)

        let start = DispatchTime.now()
        var done = 0
        while done < total {
            if Task.isCancelled { break }
            let n = min(chunk, total - done)
            let moved = writing ? write(fd, buffer, n) : read(fd, buffer, n)
            if moved <= 0 { break }
            done += moved
            progress(Double(done) / Double(total))
        }
        if writing { fsync(fd) }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
        let mb = Double(done) / (1024 * 1024)
        return elapsed > 0 ? mb / elapsed : 0
    }

    func buildResult() -> CheckResult {
        let w = writeMBps ?? 0, r = readMBps ?? 0
        let low = (w > 0 && w < 200) || (r > 0 && r < 200)
        var raw: [String: String] = [
            "write": String(format: "%.0f MB/s", w),
            "read": String(format: "%.0f MB/s", r),
            "size": L10n.t("check.disk.size_val"),
            "method": L10n.t("check.disk.method_val"),
            "runs": "\(Self.runCount)",
        ]
        if writeSamples.count == Self.runCount {
            raw["writeRuns"] = writeSamples.map { String(format: "%.0f", $0) }.joined(separator: " / ")
        }
        if readSamples.count == Self.runCount {
            raw["readRuns"] = readSamples.map { String(format: "%.0f", $0) }.joined(separator: " / ")
        }
        let details = RawDetails.localize(raw, using: [
            "write": "check.disk.write",
            "read": "check.disk.read",
            "size": "check.disk.size",
            "method": "check.disk.method",
            "runs": "check.disk.runs",
            "writeRuns": "check.disk.write_runs",
            "readRuns": "check.disk.read_runs",
        ])
        return CheckResult(
            id: "diskSpeed",
            title: L10n.t("check.disk.title"),
            status: low ? .warning : .pass,
            summary: L10n.t(low ? "check.disk.summary.low" : "check.disk.summary.ok", w, r),
            rawDetails: details
        )
    }
}

struct DiskSpeedCheckView: View {
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var model = DiskSpeedCheckModel()
    @State private var sessionActive = false
    let onComplete: (CheckResult) -> Void

    private var existingResult: CheckResult? { appModel.result(id: "diskSpeed") }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            CheckHeader(
                icon: "speedometer",
                title: L10n.t("check.disk.title_full"),
                subtitle: L10n.t("check.disk.subtitle")
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
                model.leaveFinishedSession()
                sessionActive = false
                onComplete(CheckResult(
                    id: "diskSpeed",
                    title: L10n.t("check.disk.title"),
                    status: .skipped,
                    summary: L10n.t("check.disk.skip_summary")
                ))
            }
            .buttonStyle(.bordered)
        }
        .padding(DS.Spacing.xl)
        .checkPane(L10n.t("check.disk.title"))
        .onDisappear {
            model.cancel()
            sessionActive = false
        }
    }

    @ViewBuilder
    private var activeSession: some View {
        Card {
            HStack(spacing: DS.Spacing.xl) {
                speedStat(title: L10n.t("check.disk.write"), value: model.writeMBps)
                speedStat(title: L10n.t("check.disk.read"), value: model.readMBps)
                Spacer()
            }
            if model.isRunning {
                ProgressView(value: model.progress) {
                    Text("\(model.phase) \(Int(model.progress * 100))%")
                        .font(DS.Font.caption).foregroundStyle(.secondary)
                }
            } else if model.finished {
                Text(L10n.t("check.disk.done_avg", DiskSpeedCheckModel.runCount))
                    .font(DS.Font.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if let err = model.errorText {
            InlineNotice(icon: "exclamationmark.triangle.fill", tint: .orange, text: err)
        }

        DS.Divider()

        HStack(spacing: DS.Spacing.md) {
            if model.isRunning {
                Button(L10n.t("common.stop")) {
                    model.cancel()
                    sessionActive = false
                }
                .buttonStyle(.bordered)
            } else if model.finished {
                Button(L10n.t("check.disk.save")) {
                    onComplete(model.buildResult())
                    model.leaveFinishedSession()
                    sessionActive = false
                }
                .buttonStyle(.borderedProminent)
                Button(L10n.t("detail.retest")) {
                    beginSession()
                }
                .buttonStyle(.bordered)
            } else {
                Button(L10n.t("check.disk.start")) { model.start() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func beginSession() {
        sessionActive = true
        model.start()
    }

    private func speedStat(title: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(DS.Font.caption).foregroundStyle(.secondary)
            Text(value.map { String(format: "%.0f", $0) } ?? "—")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.primary)
            + Text(value != nil ? " MB/s" : "")
                .font(DS.Font.caption).foregroundStyle(.secondary)
        }
    }
}
