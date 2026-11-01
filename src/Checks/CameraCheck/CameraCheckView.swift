import SwiftUI
import AVFoundation

/// B6: Camera preview — user checks focus / dead pixels / color blotches.
@MainActor
final class CameraCheckModel: ObservableObject {
    @Published var permissionDenied = false
    @Published var isRunning = false
    @Published var errorText: String?

    let session = AVCaptureSession()
    /// All AVCaptureSession mutate/start/stop go through this queue (not MainActor).
    private let sessionQueue = DispatchQueue(label: "MacInspect.CameraCheck.session")
    private var startGeneration = 0

    func start() {
        errorText = nil
        permissionDenied = false

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            enqueueConfigureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted {
                        self.enqueueConfigureAndStart()
                    } else {
                        self.permissionDenied = true
                    }
                }
            }
        case .denied, .restricted:
            permissionDenied = true
        @unknown default:
            permissionDenied = true
        }
    }

    func stop() {
        startGeneration += 1
        let generation = startGeneration
        nonisolated(unsafe) let session = self.session
        sessionQueue.async { [weak self] in
            if session.isRunning {
                session.stopRunning()
            }
            DispatchQueue.main.async {
                guard let self, self.startGeneration == generation else { return }
                self.isRunning = false
            }
        }
    }

    func retry() {
        stop()
        permissionDenied = false
        errorText = nil
        // Let stopRunning finish on sessionQueue before reconfigure.
        sessionQueue.async { [weak self] in
            DispatchQueue.main.async { self?.start() }
        }
    }

    private func enqueueConfigureAndStart() {
        startGeneration += 1
        let generation = startGeneration
        nonisolated(unsafe) let session = self.session
        sessionQueue.async { [weak self] in
            let outcome = Self.configure(session: session)
            DispatchQueue.main.async {
                guard let self, self.startGeneration == generation else { return }
                switch outcome {
                case .ready:
                    break
                case .noDevice:
                    self.permissionDenied = true
                    self.errorText = L10n.t("check.camera.no_device")
                    return
                case .failed(let message):
                    self.permissionDenied = true
                    self.errorText = message
                    return
                }
            }
            guard case .ready = outcome else { return }
            session.startRunning()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.startGeneration == generation else { return }
                self.isRunning = session.isRunning
                if !session.isRunning {
                    self.errorText = L10n.t("check.camera.start_failed")
                }
            }
        }
    }

    private enum ConfigureOutcome: Sendable {
        case ready
        case noDevice
        case failed(String)
    }

    /// Runs on `sessionQueue` only.
    nonisolated private static func configure(session: AVCaptureSession) -> ConfigureOutcome {
        if session.isRunning {
            session.stopRunning()
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        for input in session.inputs {
            session.removeInput(input)
        }
        for output in session.outputs {
            session.removeOutput(output)
        }

        // `.high` is not supported on every Mac / Continuity Camera; fall back.
        let presets: [AVCaptureSession.Preset] = [.high, .medium, .low, .vga640x480, .cif352x288]
        if let preset = presets.first(where: { session.canSetSessionPreset($0) }) {
            session.sessionPreset = preset
        }

        guard let device = AVCaptureDevice.default(for: .video) else {
            return .noDevice
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            return .failed(error.localizedDescription)
        }

        guard session.canAddInput(input) else {
            return .noDevice
        }
        session.addInput(input)
        return .ready
    }
}

/// SwiftUI wrapper around AVCaptureVideoPreviewLayer.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {
        if nsView.previewLayer.session !== session {
            nsView.previewLayer.session = session
        }
    }

    final class PreviewView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            previewLayer.videoGravity = .resizeAspectFill
            layer = previewLayer
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            previewLayer.frame = bounds
        }
    }
}

struct CameraCheckView: View {
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var model = CameraCheckModel()
    @State private var sessionActive = false
    let onComplete: (CheckResult) -> Void

    private var existingResult: CheckResult? { appModel.result(id: "camera") }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            CheckHeader(
                icon: "camera.fill",
                title: L10n.t("check.camera.title"),
                subtitle: L10n.t("check.camera.subtitle")
            )

            if sessionActive {
                activeSession
            } else if let result = existingResult {
                PreviousResultCard(result: result, showDetails: false)
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
                    id: "camera",
                    title: L10n.t("check.camera.item"),
                    status: .skipped,
                    summary: L10n.t("check.camera.skip_summary")
                ))
            }
            .buttonStyle(.bordered)
        }
        .padding(DS.Spacing.xl)
        .checkPane(L10n.t("check.camera.item"))
        .onAppear {
            if existingResult == nil { beginSession() }
        }
        .onDisappear {
            model.stop()
            sessionActive = false
        }
    }

    @ViewBuilder
    private var activeSession: some View {
        if model.permissionDenied {
            InlineNotice(
                icon: "exclamationmark.triangle.fill",
                tint: .orange,
                text: model.errorText ?? L10n.t("check.camera.denied", AppBrand.name)
            )
        } else {
            CameraPreview(session: model.session)
                .frame(height: 320)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.hairline))
            if let error = model.errorText {
                InlineNotice(icon: "exclamationmark.triangle.fill", tint: .orange, text: error)
            }
        }

        DS.Divider()

        HStack(spacing: DS.Spacing.md) {
            Text(L10n.t("result.label")).font(DS.Font.body).foregroundStyle(.secondary)
            Button(L10n.t("result.ok_clear")) {
                finish(CheckResult(
                    id: "camera",
                    title: L10n.t("check.camera.item"),
                    status: .pass,
                    summary: L10n.t("check.camera.result_ok")
                ))
            }
            .buttonStyle(.borderedProminent)
            Button(L10n.t("result.abnormal")) {
                finish(CheckResult(
                    id: "camera",
                    title: L10n.t("check.camera.item"),
                    status: .warning,
                    summary: L10n.t("check.camera.result_bad")
                ))
            }
            .buttonStyle(.bordered)
        }
    }

    private func beginSession() {
        sessionActive = true
        model.retry()
    }

    private func finish(_ result: CheckResult) {
        model.stop()
        sessionActive = false
        onComplete(result)
    }
}
