import SwiftUI

/// 屏幕坏点/色带/残影测试：真正的全屏轮播纯色与图案。
/// 提示面板可按住拖动，避免长时间遮挡同一块屏幕区域影响判断。
struct ScreenCheckView: View {
    @StateObject private var model = ScreenCheckModel()
    let onFinish: (CheckResult) -> Void

    @State private var panelOffset: CGSize = .zero
    @State private var panelSize = CGSize(width: 520, height: 160)
    @State private var dragStartOffset: CGSize?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                stageBackground(for: model.currentStage)
                    .ignoresSafeArea()
                    .onTapGesture { model.advance() }

                overlayBar(in: geo.size)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: PanelSizeKey.self, value: proxy.size)
                        }
                    )
                    // 只改 offset（渲染层位移），不每帧重算 position（触发布局），拖动才跟手。
                    .position(defaultPanelCenter(in: geo.size))
                    .offset(panelOffset)
            }
            .coordinateSpace(.named("screenTest"))
            .onPreferenceChange(PanelSizeKey.self) { size in
                // 忽略布局初期的零尺寸，避免把默认位置算到屏幕外。
                if size.width > 0 && size.height > 0 { panelSize = size }
            }
        }
        .ignoresSafeArea()
        .onAppear {
            model.onEscape = { finish(exitedEarly: !model.isLastStage) }
            model.startKeyHandling()
        }
        .onDisappear { model.stopKeyHandling() }
    }

    @ViewBuilder
    private func stageBackground(for stage: ScreenStage) -> some View {
        switch stage {
        case .black: Color.black
        case .white: Color.white
        case .red: Color.red
        case .green: Color.green
        case .blue: Color.blue
        case .grayGradient:
            LinearGradient(colors: [.black, .white], startPoint: .leading, endPoint: .trailing)
        case .checkerboard:
            CheckerboardView()
        }
    }

    private func overlayBar(in containerSize: CGSize) -> some View {
        VStack(spacing: 10) {
            VStack(spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "line.3.horizontal")
                    Text(L10n.t("check.screen.drag"))
                }
                .font(.system(size: 11, weight: .medium))
                .opacity(0.7)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.12)))
                .help(L10n.t("check.screen.drag_help"))

                Text(model.currentStage.title)
                    .font(.system(size: 16, weight: .semibold))
                Text(L10n.t("check.screen.hint", model.currentIndex + 1, model.stages.count))
                    .font(.system(size: 12))
                    .opacity(0.75)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .contentShape(Rectangle())
            .gesture(panelDragGesture(in: containerSize))

            HStack(spacing: 12) {
                Button(L10n.t("check.screen.prev")) { model.goBack() }
                    .disabled(model.isFirstStage)
                Button(L10n.t("check.screen.flag")) { model.flagCurrent() }
                Button(model.isLastStage ? L10n.t("check.screen.done") : L10n.t("check.screen.next")) {
                    if model.isLastStage {
                        finish(exitedEarly: false)
                    } else {
                        model.advance()
                    }
                }
                Button(L10n.t("common.skip")) { skip() }
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .frame(width: min(560, max(320, containerSize.width - 48)))
        // 固定深色面板 + 白字：无论当前是纯白、纯绿还是棋盘格，对比度都稳定。
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.72)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.16)))
        .foregroundStyle(.white)
    }

    // MARK: - 面板拖动

    private func panelDragGesture(in containerSize: CGSize) -> some Gesture {
        // 用固定的容器坐标系取 translation：面板自身移动不会反过来影响手势数值。
        DragGesture(minimumDistance: 1, coordinateSpace: .named("screenTest"))
            .onChanged { value in
                let start = dragStartOffset ?? panelOffset
                if dragStartOffset == nil { dragStartOffset = start }
                let proposed = CGSize(
                    width: start.width + value.translation.width,
                    height: start.height + value.translation.height
                )
                panelOffset = clampedPanelOffset(proposed, in: containerSize)
            }
            .onEnded { _ in dragStartOffset = nil }
    }

    private func defaultPanelCenter(in size: CGSize) -> CGPoint {
        let bottomMargin: CGFloat = 40
        return CGPoint(
            x: size.width / 2,
            y: max(panelSize.height / 2 + 12, size.height - bottomMargin - panelSize.height / 2)
        )
    }

    private func clampedPanelOffset(_ offset: CGSize, in size: CGSize) -> CGSize {
        let defaultCenter = defaultPanelCenter(in: size)
        let desired = CGPoint(
            x: defaultCenter.x + offset.width,
            y: defaultCenter.y + offset.height
        )
        let clamped = clampedPanelCenter(desired, in: size)
        return CGSize(
            width: clamped.x - defaultCenter.x,
            height: clamped.y - defaultCenter.y
        )
    }

    private func clampedPanelCenter(_ center: CGPoint, in size: CGSize) -> CGPoint {
        let margin: CGFloat = 12
        let halfW = panelSize.width / 2
        let halfH = panelSize.height / 2
        let minX = halfW + margin
        let maxX = max(minX, size.width - halfW - margin)
        let minY = halfH + margin
        let maxY = max(minY, size.height - halfH - margin)
        return CGPoint(
            x: min(max(center.x, minX), maxX),
            y: min(max(center.y, minY), maxY)
        )
    }

    private func finish(exitedEarly: Bool) {
        onFinish(model.buildResult(exitedEarly: exitedEarly))
    }

    private func skip() {
        model.stopKeyHandling()
        onFinish(CheckResult(
            id: "screen",
            title: L10n.t("check.screen.title"),
            status: .skipped,
            summary: L10n.t("check.screen.skip_summary")
        ))
    }
}

private struct PanelSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

private struct CheckerboardView: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 40
            let cols = Int((size.width / cell).rounded(.up))
            let rows = Int((size.height / cell).rounded(.up))
            for r in 0..<rows {
                for c in 0..<cols {
                    let isBlack = (r + c).isMultiple(of: 2)
                    let rect = CGRect(x: CGFloat(c) * cell, y: CGFloat(r) * cell, width: cell, height: cell)
                    context.fill(Path(rect), with: .color(isBlack ? .black : .white))
                }
            }
        }
    }
}
