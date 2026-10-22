import SwiftUI
import AppKit

/// B9：触控板测试。跟手轨迹绘制 + 多指手势识别 + Force Touch 压感检测。
@MainActor
final class TrackpadCheckModel: ObservableObject {
    @Published var trail: [CGPoint] = []
    @Published var pressure: Double = 0
    @Published var didForceClick = false
    @Published var gesturesSeen: Set<String> = []      // "magnify" / "rotate" / "swipe"

    func addPoint(_ p: CGPoint) {
        trail.append(p)
        if trail.count > 400 { trail.removeFirst(trail.count - 400) }
    }

    func note(gesture: String) { gesturesSeen.insert(gesture) }

    func reset() {
        trail.removeAll()
        pressure = 0
        didForceClick = false
        gesturesSeen.removeAll()
    }

    var coverageHint: String {
        var parts: [String] = []
        parts.append(L10n.t("check.trackpad.meta.trail", trail.count))
        if !gesturesSeen.isEmpty { parts.append(L10n.t("check.trackpad.meta.gestures", gesturesSeen.count)) }
        if didForceClick { parts.append("Force Touch ✓") }
        return parts.joined(separator: " · ")
    }
}

/// 用 NSView 捕获触控板压力与手势事件（SwiftUI 手势拿不到 pressure 与精确 magnify/rotate）。
private struct TrackpadCapture: NSViewRepresentable {
    @ObservedObject var model: TrackpadCheckModel

    func makeNSView(context: Context) -> CaptureView {
        let v = CaptureView()
        v.model = model
        return v
    }
    func updateNSView(_ nsView: CaptureView, context: Context) {}

    final class CaptureView: NSView {
        weak var model: TrackpadCheckModel?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }

        override func mouseDragged(with event: NSEvent) { record(event) }
        override func mouseMoved(with event: NSEvent) { record(event) }

        private func record(_ event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            let flipped = CGPoint(x: p.x, y: bounds.height - p.y)
            model?.addPoint(flipped)
        }

        override func pressureChange(with event: NSEvent) {
            model?.pressure = Double(event.pressure)
            if event.stage >= 2 { model?.didForceClick = true }
        }
        override func magnify(with event: NSEvent) { model?.note(gesture: "magnify") }
        override func rotate(with event: NSEvent) { model?.note(gesture: "rotate") }
        override func swipe(with event: NSEvent) { model?.note(gesture: "swipe") }
        override func scrollWheel(with event: NSEvent) {
            // 双指滚动也算一种确认（很多触控板问题表现为滚动失灵）
            model?.note(gesture: "swipe")
        }
    }
}

struct TrackpadCheckView: View {
    @StateObject private var model = TrackpadCheckModel()
    let onComplete: (CheckResult) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            CheckHeader(
                icon: "rectangle.and.hand.point.up.left.fill",
                title: L10n.t("check.trackpad.title"),
                subtitle: L10n.t("check.trackpad.subtitle")
            )

            canvas

            HStack(spacing: DS.Spacing.lg) {
                metric(L10n.t("check.trackpad.pressure"), String(format: "%.2f", model.pressure), model.pressure > 0)
                metric(L10n.t("check.trackpad.force"), model.didForceClick ? L10n.t("check.trackpad.force_yes") : L10n.t("check.trackpad.force_no"), model.didForceClick)
                metric(L10n.t("check.trackpad.gestures"), "\(model.gesturesSeen.count)/3", !model.gesturesSeen.isEmpty)
                Spacer()
                Button(L10n.t("check.trackpad.clear")) { model.reset() }.buttonStyle(.bordered)
            }

            DS.Divider()

            HStack(spacing: DS.Spacing.md) {
                Text(L10n.t("result.label")).font(DS.Font.body).foregroundStyle(.secondary)
                Button(L10n.t("check.trackpad.ok_btn")) {
                    onComplete(CheckResult(id: "trackpad", title: L10n.t("check.trackpad.item"), status: .pass,
                        summary: L10n.t("check.trackpad.ok"),
                        rawDetails: [L10n.t("check.trackpad.detail.trail"): "\(model.trail.count)",
                                     L10n.t("check.trackpad.detail.gestures"): model.gesturesSeen.sorted().joined(separator: ", "),
                                     L10n.t("check.trackpad.force"): model.didForceClick ? L10n.t("check.trackpad.force_yes") : L10n.t("check.trackpad.force_no")]))
                }
                .buttonStyle(.borderedProminent)
                Button(L10n.t("check.trackpad.bad_btn")) {
                    onComplete(CheckResult(id: "trackpad", title: L10n.t("check.trackpad.item"), status: .warning,
                        summary: L10n.t("check.trackpad.bad")))
                }
                .buttonStyle(.bordered)
            }

            Button(L10n.t("common.skip")) {
                onComplete(CheckResult(id: "trackpad", title: L10n.t("check.trackpad.item"), status: .skipped,
                    summary: L10n.t("check.trackpad.skip_summary")))
            }
            .buttonStyle(.bordered)
        }
        .padding(DS.Spacing.xl)
        .checkPane(L10n.t("check.trackpad.item"))
    }

    private var canvas: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DS.Radius.card).fill(Color.secondary.opacity(0.08))
            TrackpadCapture(model: model).allowsHitTesting(true)
            Canvas { ctx, _ in
                guard model.trail.count > 1 else { return }
                var path = Path()
                path.addLines(model.trail)
                ctx.stroke(path, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }
            .allowsHitTesting(false)
            if model.trail.isEmpty {
                Text(L10n.t("check.trackpad.draw_here")).font(DS.Font.body).foregroundStyle(.tertiary)
            }
            // 压力可视化圆环
            if model.pressure > 0 {
                Circle().stroke(Color.orange, lineWidth: 3)
                    .frame(width: 30 + model.pressure * 60, height: 30 + model.pressure * 60)
                    .opacity(0.6)
            }
        }
        .frame(height: 260)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
    }

    private func metric(_ label: String, _ value: String, _ active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(DS.Font.caption).foregroundStyle(.secondary)
            Text(value).font(DS.Font.bodyEmphasis).foregroundStyle(active ? .green : .primary)
        }
    }
}
