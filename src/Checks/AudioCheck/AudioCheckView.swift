import SwiftUI
import AVFoundation

/// B3：扬声器/耳机口测试。分别播放左右声道扫频音，用户确认左右是否都正常。
@MainActor
final class AudioCheckModel: ObservableObject {
    @Published var playingChannel: Int? = nil   // 0 = 左, 1 = 右, nil = 停止

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var started = false

    private func makeBuffer(channel: Int) -> AVAudioPCMBuffer? {
        let sampleRate = 44_100.0
        let duration = 1.0
        let frames = AVAudioFrameCount(sampleRate * duration)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { return nil }
        buffer.frameLength = frames
        let freq = 440.0
        for frame in 0..<Int(frames) {
            let value = Float(sin(2.0 * Double.pi * freq * Double(frame) / sampleRate)) * 0.25
            buffer.floatChannelData?[0][frame] = channel == 0 ? value : 0
            buffer.floatChannelData?[1][frame] = channel == 1 ? value : 0
        }
        return buffer
    }

    func play(channel: Int) {
        guard let buffer = makeBuffer(channel: channel) else { return }
        if !started {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
            do { try engine.start(); started = true } catch { return }
        }
        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()
        playingChannel = channel
    }

    func stop() {
        player.stop()
        playingChannel = nil
    }

    func teardown() {
        stop()
        if started { engine.stop() }
    }
}

struct AudioCheckView: View {
    @StateObject private var model = AudioCheckModel()
    let onComplete: (CheckResult) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            CheckHeader(
                icon: "speaker.wave.3.fill",
                title: L10n.t("check.audio.title"),
                subtitle: L10n.t("check.audio.subtitle")
            )

            HStack(spacing: DS.Spacing.md) {
                channelButton(title: L10n.t("check.audio.left"), channel: 0, icon: "l.circle.fill")
                channelButton(title: L10n.t("check.audio.right"), channel: 1, icon: "r.circle.fill")
                Button {
                    model.stop()
                } label: {
                    Label(L10n.t("common.stop"), systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            DS.Divider()

            HStack(spacing: DS.Spacing.md) {
                Text(L10n.t("result.label")).font(DS.Font.body).foregroundStyle(.secondary)
                Button(L10n.t("check.audio.ok_btn")) {
                    model.teardown()
                    onComplete(CheckResult(id: "audio", title: L10n.t("check.audio.item"), status: .pass,
                        summary: L10n.t("check.audio.ok"),
                        rawDetails: [L10n.t("check.audio.ch_left"): L10n.t("check.audio.normal"),
                                     L10n.t("check.audio.ch_right"): L10n.t("check.audio.normal")]))
                }
                .buttonStyle(.borderedProminent)
                Button(L10n.t("check.audio.bad_btn")) {
                    model.teardown()
                    onComplete(CheckResult(id: "audio", title: L10n.t("check.audio.item"), status: .warning,
                        summary: L10n.t("check.audio.bad"),
                        rawDetails: [L10n.t("check.audio.user_judge"): L10n.t("check.audio.abnormal")]))
                }
                .buttonStyle(.bordered)
            }

            Button(L10n.t("common.skip")) {
                model.teardown()
                onComplete(CheckResult(id: "audio", title: L10n.t("check.audio.item"), status: .skipped,
                    summary: L10n.t("check.audio.skip_summary")))
            }
            .buttonStyle(.bordered)
        }
        .padding(DS.Spacing.xl)
        .checkPane(L10n.t("check.audio.item"))
        .onDisappear { model.teardown() }
    }

    private func channelButton(title: String, channel: Int, icon: String) -> some View {
        Button {
            model.play(channel: channel)
        } label: {
            Label(title, systemImage: icon)
                .frame(minWidth: 130)
        }
        .buttonStyle(.borderedProminent)
        .tint(model.playingChannel == channel ? .accentColor : .gray)
        .controlSize(.large)
    }
}
