import SwiftUI
import AVFoundation

/// B6：摄像头测试。打开预览画面，用户确认画面清晰、无坏点/色斑。
@MainActor
final class CameraCheckModel: ObservableObject {
    @Published var permissionDenied = false
    @Published var isRunning = false
    let session = AVCaptureSession()

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                if granted { self.configure() } else { self.permissionDenied = true }
            }
        }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .high
        if let device = AVCaptureDevice.default(for: .video),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        } else {
            permissionDenied = true
            session.commitConfiguration()
            return
        }
        session.commitConfiguration()
        nonisolated(unsafe) let session = self.session
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
            DispatchQueue.main.async { [weak self] in self?.isRunning = true }
        }
    }

    func stop() {
        if session.isRunning { session.stopRunning() }
        isRunning = false
    }
}

/// AVCaptureVideoPreviewLayer 的 SwiftUI 包装。
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer = preview
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct CameraCheckView: View {
    @StateObject private var model = CameraCheckModel()
    let onComplete: (CheckResult) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            CheckHeader(
                icon: "camera.fill",
                title: L10n.t("check.camera.title"),
                subtitle: L10n.t("check.camera.subtitle")
            )

            if model.permissionDenied {
                InlineNotice(icon: "exclamationmark.triangle.fill", tint: .orange,
                    text: L10n.t("check.camera.denied", AppBrand.name))
            } else {
                CameraPreview(session: model.session)
                    .frame(height: 320)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.hairline))
            }

            DS.Divider()

            HStack(spacing: DS.Spacing.md) {
                Text(L10n.t("result.label")).font(DS.Font.body).foregroundStyle(.secondary)
                Button(L10n.t("result.ok_clear")) {
                    model.stop()
                    onComplete(CheckResult(id: "camera", title: L10n.t("check.camera.item"), status: .pass,
                        summary: L10n.t("check.camera.result_ok")))
                }
                .buttonStyle(.borderedProminent)
                Button(L10n.t("result.abnormal")) {
                    model.stop()
                    onComplete(CheckResult(id: "camera", title: L10n.t("check.camera.item"), status: .warning,
                        summary: L10n.t("check.camera.result_bad")))
                }
                .buttonStyle(.bordered)
            }

            Button(L10n.t("common.skip")) {
                model.stop()
                onComplete(CheckResult(id: "camera", title: L10n.t("check.camera.item"), status: .skipped,
                    summary: L10n.t("check.camera.skip_summary")))
            }
            .buttonStyle(.bordered)
        }
        .padding(DS.Spacing.xl)
        .checkPane(L10n.t("check.camera.item"))
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}
