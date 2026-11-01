import SwiftUI
import AppKit

/// B9: Trackpad — path drawing, multi-finger gestures, Force Touch pressure.
@MainActor
final class TrackpadCheckModel: ObservableObject {
    @Published var trail: [CGPoint] = []
    @Published var pressure: Double = 0
    @Published var didForceClick = false
    /// "magnify" / "rotate" / "scroll"
    @Published var gesturesSeen: Set<String> = []

    static let requiredGestures = ["magnify", "rotate", "scroll"]

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

/// NSView captures pressure / magnify / rotate / scroll (SwiftUI gestures don't).
private struct TrackpadCapture: NSViewRepresentable {
    @ObservedObject var model: TrackpadCheckModel

    func makeNSView(context: Context) -> CaptureView {
        let v = CaptureView()
        v.model = model
        return v
    }

    func updateNSView(_ nsView: CaptureView, context: Context) {
        nsView.model = model
    }

    final class CaptureView: NSView {
        weak var model: TrackpadCheckModel?
        private var monitor: Any?

        override var acceptsFirstResponder: Bool { true }
        override var isOpaque: Bool { false }

        override func viewDidMoveToWindow() {
            if window != nil {
                window?.makeFirstResponder(self)
                installMonitor()
            } else {
                removeMonitor()
            }
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            record(event)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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

        override func magnify(with event: NSEvent) {
            if abs(event.magnification) > 0.001 { model?.note(gesture: "magnify") }
        }

        override func smartMagnify(with event: NSEvent) {
            model?.note(gesture: "magnify")
        }

        override func rotate(with event: NSEvent) {
            if abs(event.rotation) > 0.01 { model?.note(gesture: "rotate") }
        }

        /// System swipe (3-finger) is usually stolen by Mission Control — use two-finger scroll instead.
        override func scrollWheel(with event: NSEvent) {
            noteScroll(event)
            // Do not forward — parent SwiftUI ScrollView would otherwise swallow the gesture.
        }

        private func noteScroll(_ event: NSEvent) {
            let dx = abs(event.scrollingDeltaX)
            let dy = abs(event.scrollingDeltaY)
            guard dx + dy > 0.5 else { return }
            model?.note(gesture: "scroll")
        }

        private func installMonitor() {
            removeMonitor()
            // Local monitor catches gestures even when ScrollView / another view is first responder.
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.scrollWheel, .magnify, .rotate]
            ) { [weak self] event in
                guard let self, let window = self.window, event.window == window else {
                    return event
                }
                let loc = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.insetBy(dx: -12, dy: -12).contains(loc) else {
                    return event
                }
                switch event.type {
                case .magnify:
                    if abs(event.magnification) > 0.001 { self.model?.note(gesture: "magnify") }
                    return nil
                case .rotate:
                    if abs(event.rotation) > 0.01 { self.model?.note(gesture: "rotate") }
                    return nil
                case .scrollWheel:
                    self.noteScroll(event)
                    return nil
                default:
                    return event
                }
            }
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}

struct TrackpadCheckView: View {
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var model = TrackpadCheckModel()
    @State private var sessionActive = false
    let onComplete: (CheckResult) -> Void

    private var existingResult: CheckResult? { appModel.result(id: "trackpad") }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            CheckHeader(
                icon: "rectangle.and.hand.point.up.left.fill",
                title: L10n.t("check.trackpad.title"),
                subtitle: L10n.t("check.trackpad.subtitle")
            )

            if sessionActive {
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
                finish(CheckResult(
                    id: "trackpad",
                    title: L10n.t("check.trackpad.item"),
                    status: .skipped,
                    summary: L10n.t("check.trackpad.skip_summary")
                ))
            }
            .buttonStyle(.bordered)
        }
        .padding(DS.Spacing.xl)
        .checkPane(L10n.t("check.trackpad.item"))
        .onAppear {
            if existingResult == nil { beginSession() }
        }
    }

    @ViewBuilder
    private var activeSession: some View {
        canvas

        gestureChecklist

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
                finish(CheckResult(
                    id: "trackpad",
                    title: L10n.t("check.trackpad.item"),
                    status: .pass,
                    summary: L10n.t("check.trackpad.ok"),
                    rawDetails: RawDetails.localize([
                        "trail": "\(model.trail.count)",
                        "gestures": model.gesturesSeen.sorted().joined(separator: ", "),
                        "force": model.didForceClick ? L10n.t("check.trackpad.force_yes") : L10n.t("check.trackpad.force_no"),
                    ], using: [
                        "trail": "check.trackpad.detail.trail",
                        "gestures": "check.trackpad.detail.gestures",
                        "force": "check.trackpad.force",
                    ])
                ))
            }
            .buttonStyle(.borderedProminent)
            Button(L10n.t("check.trackpad.bad_btn")) {
                finish(CheckResult(
                    id: "trackpad",
                    title: L10n.t("check.trackpad.item"),
                    status: .warning,
                    summary: L10n.t("check.trackpad.bad")
                ))
            }
            .buttonStyle(.bordered)
        }
    }

    private func beginSession() {
        model.reset()
        sessionActive = true
    }

    private func finish(_ result: CheckResult) {
        sessionActive = false
        onComplete(result)
    }

    private var gestureChecklist: some View {
        HStack(spacing: DS.Spacing.md) {
            gestureChip("magnify", L10n.t("check.trackpad.gesture.pinch"))
            gestureChip("rotate", L10n.t("check.trackpad.gesture.rotate"))
            gestureChip("scroll", L10n.t("check.trackpad.gesture.scroll"))
            Spacer(minLength: 0)
        }
    }

    private func gestureChip(_ key: String, _ label: String) -> some View {
        let done = model.gesturesSeen.contains(key)
        return HStack(spacing: 4) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Color.green : Color.secondary)
            Text(label)
                .font(DS.Font.caption)
                .foregroundStyle(done ? Color.primary : Color.secondary)
        }
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
                Text(L10n.t("check.trackpad.draw_here"))
                    .font(DS.Font.body)
                    .foregroundStyle(.tertiary)
                    .allowsHitTesting(false)
            }
            if model.pressure > 0 {
                Circle().stroke(Color.orange, lineWidth: 3)
                    .frame(width: 30 + model.pressure * 60, height: 30 + model.pressure * 60)
                    .opacity(0.6)
                    .allowsHitTesting(false)
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
