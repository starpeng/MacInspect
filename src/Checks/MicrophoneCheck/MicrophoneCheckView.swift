import SwiftUI
import AVFoundation
import AppKit

/// B4: Mic test — live input level; user speaks and watches the meter.
@MainActor
final class MicrophoneCheckModel: ObservableObject {
    @Published var level: Double = 0        // 0...1
    @Published var peak: Double = 0
    @Published var isRunning = false
    @Published var permissionDenied = false
    @Published var statusText = L10n.t("check.mic.status.ready")
    @Published var errorText: String?

    private let engine = AVAudioEngine()

    func start() {
        guard !isRunning else { return }
        permissionDenied = false
        errorText = nil

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginTap()
        case .notDetermined:
            statusText = L10n.t("check.mic.status.wait_auth")
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted {
                        self.beginTap()
                    } else {
                        self.showPermissionDenied()
                    }
                }
            }
        case .denied, .restricted:
            showPermissionDenied()
        @unknown default:
            showPermissionDenied()
        }
    }

    private func showPermissionDenied() {
        permissionDenied = true
        isRunning = false
        statusText = L10n.t("check.mic.status.denied")
        errorText = L10n.t("check.mic.need_permission", AppBrand.name)
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    func retry() {
        stop()
        start()
    }

    private func beginTap() {
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            errorText = L10n.t("check.mic.err.no_device")
            statusText = L10n.t("check.mic.status.fail")
            return
        }

        input.removeTap(onBus: 0)
        let block: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { [weak self] buffer, _ in
            let normalized = MicrophoneCheckModel.level(from: buffer)
            DispatchQueue.main.async {
                self?.updateLevel(normalized)
            }
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: block)
        do {
            engine.prepare()
            try engine.start()
            isRunning = true
            statusText = L10n.t("check.mic.status.listening")
        } catch {
            input.removeTap(onBus: 0)
            isRunning = false
            statusText = L10n.t("check.mic.status.fail")
            errorText = L10n.t("check.mic.err.start", error.localizedDescription)
        }
    }

    /// Pure / nonisolated RMS level — safe on the audio thread.
    nonisolated private static func level(from buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let frames = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<frames { sum += channel[i] * channel[i] }
        let rms = frames > 0 ? sqrt(sum / Float(frames)) : 0
        return min(1.0, Double(rms) * 8)
    }

    private func updateLevel(_ value: Double) {
        level = value
        peak = max(peak * 0.92, value)
    }

    func stop() {
        if isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            isRunning = false
        }
    }
}

struct MicrophoneCheckView: View {
    @StateObject private var model = MicrophoneCheckModel()
    let onComplete: (CheckResult) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            CheckHeader(
                icon: "mic.fill",
                title: L10n.t("check.mic.title"),
                subtitle: L10n.t("check.mic.subtitle")
            )

            if model.permissionDenied {
                VStack(alignment: .leading, spacing: DS.Spacing.md) {
                    InlineNotice(icon: "exclamationmark.triangle.fill", tint: .orange,
                        text: model.errorText ?? L10n.t("check.mic.denied", AppBrand.name))
                    HStack(spacing: DS.Spacing.md) {
                        Button {
                            model.openPrivacySettings()
                        } label: {
                            Label(L10n.t("check.mic.open_settings"), systemImage: "gearshape")
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            model.retry()
                        } label: {
                            Label(L10n.t("common.recheck"), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } else {
                levelMeter
                if let error = model.errorText {
                    InlineNotice(icon: "exclamationmark.triangle.fill", tint: .orange, text: error)
                }
            }

            DS.Divider()

            HStack(spacing: DS.Spacing.md) {
                Text(L10n.t("result.label")).font(DS.Font.body).foregroundStyle(.secondary)
                Button(L10n.t("check.mic.result_ok_btn")) {
                    model.stop()
                    onComplete(CheckResult(id: "microphone", title: L10n.t("check.mic.item"), status: .pass,
                        summary: L10n.t("check.mic.result_ok")))
                }
                .buttonStyle(.borderedProminent)
                Button(L10n.t("check.mic.result_bad_btn")) {
                    model.stop()
                    onComplete(CheckResult(id: "microphone", title: L10n.t("check.mic.item"), status: .warning,
                        summary: L10n.t("check.mic.result_bad")))
                }
                .buttonStyle(.bordered)
            }

            Button(L10n.t("common.skip")) {
                model.stop()
                onComplete(CheckResult(id: "microphone", title: L10n.t("check.mic.item"), status: .skipped,
                    summary: L10n.t("check.mic.skip_summary")))
            }
            .buttonStyle(.bordered)
        }
        .padding(DS.Spacing.xl)
        .checkPane(L10n.t("check.mic.item"))
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var levelMeter: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12))
                    RoundedRectangle(cornerRadius: 8)
                        .fill(LinearGradient(colors: [.green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * model.level)
                        .animation(.easeOut(duration: 0.08), value: model.level)
                }
            }
            .frame(height: 28)
            Text(model.statusText)
                .font(DS.Font.caption).foregroundStyle(.secondary)
        }
    }
}
