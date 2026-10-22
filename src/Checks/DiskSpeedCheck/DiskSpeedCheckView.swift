import SwiftUI
import Foundation

/// A3+：硬盘读写测速。顺序写入再读取 512MB，测 MB/s。
/// 读取用 `F_NOCACHE` 绕过系统页缓存，测的是真实盘速而非内存缓存。
@MainActor
final class DiskSpeedCheckModel: ObservableObject {
    @Published var isRunning = false
    @Published var phase = ""
    @Published var progress = 0.0
    @Published var writeMBps: Double?
    @Published var readMBps: Double?
    @Published var finished = false
    @Published var errorText: String?

    private let totalBytes = 1024 * 1024 * 1024   // 1 GB
    private let chunkBytes = 32 * 1024 * 1024      // 32 MB（较大块吞吐更稳）
    private var task: Task<Void, Never>?

    func start() {
        guard !isRunning else { return }
        writeMBps = nil; readMBps = nil; progress = 0; finished = false; errorText = nil
        isRunning = true
        task = Task { await run() }
    }

    func cancel() {
        task?.cancel(); task = nil
        isRunning = false
    }

    private func run() async {
        let path = NSTemporaryDirectory() + "macinspect_speedtest_\(UUID().uuidString).bin"
        let total = totalBytes, chunk = chunkBytes

        // 进度用 AsyncStream 回传，detached 任务不捕获 self（避免 Swift 6 数据竞争）。
        let (stream, cont) = AsyncStream.makeStream(of: (String, Double).self)

        let work = Task.detached { () -> Result<(Double, Double), DiskError> in
            defer { cont.finish() }
            do {
                let w = try DiskSpeedCheckModel.measure(path: path, total: total, chunk: chunk, writing: true) {
                    cont.yield((L10n.t("check.disk.writing"), $0))
                }
                let r = try DiskSpeedCheckModel.measure(path: path, total: total, chunk: chunk, writing: false) {
                    cont.yield((L10n.t("check.disk.reading"), $0))
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

        for await (ph, p) in stream {
            phase = ph
            progress = p
        }

        switch await work.value {
        case .success(let (w, r)):
            writeMBps = w
            readMBps = r
            finished = true
        case .failure(let e):
            errorText = e.description
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

    /// 阻塞式 POSIX 读写，返回 MB/s。nonisolated：在后台线程执行。
    nonisolated static func measure(path: String, total: Int, chunk: Int, writing: Bool, progress: (Double) -> Void) throws -> Double {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 4096)
        defer { buffer.deallocate() }
        if writing { memset(buffer, 0xA5, chunk) }

        let flags = writing ? (O_WRONLY | O_CREAT | O_TRUNC) : O_RDONLY
        let fd = open(path, flags, 0o644)
        guard fd >= 0 else { throw DiskError.open }
        defer { close(fd) }
        // 读写都绕过页缓存：否则读会命中刚写入的缓存，测出虚高的"内存速度"而非真实盘速。
        _ = fcntl(fd, F_NOCACHE, 1)

        let start = DispatchTime.now()
        var done = 0
        while done < total {
            let n = min(chunk, total - done)
            let moved = writing ? write(fd, buffer, n) : read(fd, buffer, n)
            if moved <= 0 { break }
            done += moved
            progress(Double(done) / Double(total))
        }
        if writing { fsync(fd) }   // 确保真正落盘再停表
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
        let mb = Double(done) / (1024 * 1024)
        return elapsed > 0 ? mb / elapsed : 0
    }

    func buildResult() -> CheckResult {
        let w = writeMBps ?? 0, r = readMBps ?? 0
        let low = (w > 0 && w < 200) || (r > 0 && r < 200)
        let details: [String: String] = [
            L10n.t("check.disk.write"): String(format: "%.0f MB/s", w),
            L10n.t("check.disk.read"): String(format: "%.0f MB/s", r),
            L10n.t("check.disk.size"): L10n.t("check.disk.size_val"),
            L10n.t("check.disk.method"): L10n.t("check.disk.method_val"),
        ]
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
    @StateObject private var model = DiskSpeedCheckModel()
    let onComplete: (CheckResult) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            CheckHeader(
                icon: "speedometer",
                title: L10n.t("check.disk.title_full"),
                subtitle: L10n.t("check.disk.subtitle")
            )

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
                }
            }

            if let err = model.errorText {
                InlineNotice(icon: "exclamationmark.triangle.fill", tint: .orange, text: err)
            }

            DS.Divider()

            HStack(spacing: DS.Spacing.md) {
                if model.isRunning {
                    Button(L10n.t("common.stop")) { model.cancel() }.buttonStyle(.bordered)
                } else {
                    Button(model.finished ? L10n.t("check.disk.restart") : L10n.t("check.disk.start")) { model.start() }
                        .buttonStyle(.borderedProminent)
                    if model.finished {
                        Button(L10n.t("check.disk.save")) { onComplete(model.buildResult()) }
                            .buttonStyle(.bordered)
                    }
                }
            }

            Button(L10n.t("common.skip")) {
                model.cancel()
                onComplete(CheckResult(id: "diskSpeed", title: L10n.t("check.disk.title"), status: .skipped,
                    summary: L10n.t("check.disk.skip_summary")))
            }
            .buttonStyle(.bordered)
        }
        .padding(DS.Spacing.xl)
        .checkPane(L10n.t("check.disk.title"))
        .onDisappear { model.cancel() }
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
