import SwiftUI
import AppKit

/// AI model fit suggestions; GPU probe runs off the main thread.
struct AIModelsView: View {
    @EnvironmentObject private var model: AppModel

    @State private var ctx: AIHardwareContext?
    @State private var suggestions: [AIModelSuggestion] = []
    @State private var sweetSpot: AIModelSuggestion?
    @State private var isLoading = false

    private var ramGB: Double {
        guard let mem = model.profile?.memory else { return 0 }
        let digits = mem.filter { $0.isNumber }
        return Double(digits) ?? 0
    }
    private var appleSilicon: Bool {
        model.profile?.architecture.contains("Apple Silicon") ?? false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                CheckHeader(
                    icon: "sparkles",
                    title: L10n.t("check.ai.title"),
                    subtitle: subtitleText
                )

                if ramGB <= 0 {
                    InlineNotice(icon: "hourglass", tint: .secondary, text: L10n.t("check.ai.loading_ram"))
                } else if isLoading, ctx == nil {
                    loadingCard
                    referencesCard
                } else if let ctx {
                    summaryCard(ctx)
                    if !appleSilicon { intelNotice(ctx) }
                    modelListCard
                    referencesCard
                    disclaimer(ctx)
                }
            }
            .padding(DS.Spacing.xl)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle(L10n.t("sidebar.ai"))
        .task(id: "\(ramGB)-\(appleSilicon)") {
            await loadEvaluation()
        }
    }

    private var subtitleText: String {
        if appleSilicon {
            return L10n.t("check.ai.sub.apple")
        }
        if let ctx, ctx.hasDiscreteGPU {
            return L10n.t("check.ai.sub.intel_dgpu")
        }
        if ctx == nil {
            return L10n.t("check.ai.sub.loading")
        }
        return L10n.t("check.ai.sub.intel_igpu")
    }

    private var loadingCard: some View {
        Card {
            HStack(spacing: DS.Spacing.md) {
                ProgressView().controlSize(.small)
                Text(L10n.t("check.ai.loading"))
                    .font(DS.Font.body).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private func summaryCard(_ ctx: AIHardwareContext) -> some View {
        let budget = AIModelAdvisor.budgetGB(ctx)
        return Card {
            HStack(spacing: DS.Spacing.xl) {
                stat(appleSilicon ? L10n.t("check.ai.unified_memory") : L10n.t("check.ai.system_memory"), String(format: "%.0f GB", ramGB))
                if appleSilicon {
                    stat(L10n.t("check.ai.chip"), model.profile?.chip ?? "—")
                } else if ctx.hasDiscreteGPU {
                    stat(L10n.t("check.ai.vram"), String(format: "%.0f GB", ctx.discreteVramGB))
                } else {
                    stat(L10n.t("check.ai.vram"), L10n.t("check.ai.vram_none"))
                }
                stat(
                    appleSilicon ? L10n.t("check.ai.budget_unified") : (ctx.hasDiscreteGPU ? L10n.t("check.ai.budget_vram") : L10n.t("check.ai.budget_effective")),
                    String(format: "≈ %.0f GB", budget)
                )
            }
            if !appleSilicon, let gpuName = ctx.discreteGPUName {
                DS.Divider()
                Text(L10n.t("check.ai.gpu_line", gpuName))
                    .font(DS.Font.caption).foregroundStyle(.secondary)
            }
            if let sweet = sweetSpot {
                DS.Divider()
                HStack(spacing: DS.Spacing.sm) {
                    Image(systemName: "star.fill").foregroundStyle(.orange)
                    Text(L10n.t("check.ai.sweet")).font(DS.Font.bodyEmphasis)
                    Text(L10n.t("check.ai.sweet_fmt", sweet.name, Int(sweet.footprintGB)))
                        .font(DS.Font.body).foregroundStyle(.secondary)
                }
            } else if !appleSilicon {
                DS.Divider()
                Text(L10n.t("check.ai.no_fit"))
                    .font(DS.Font.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func intelNotice(_ ctx: AIHardwareContext) -> some View {
        let text: String
        if ctx.hasDiscreteGPU {
            text = L10n.t("check.ai.notice.dgpu", ctx.discreteGPUName ?? L10n.t("check.ai.gpu_fallback"), ctx.discreteVramGB)
        } else {
            text = L10n.t("check.ai.notice.igpu")
        }
        return InlineNotice(icon: "exclamationmark.triangle.fill", tint: .orange, text: text)
    }

    private var modelListCard: some View {
        Card {
            SectionLabel(text: L10n.t("check.ai.section.models"))
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, s in
                HStack(spacing: DS.Spacing.md) {
                    Text(s.name).font(DS.Font.body).frame(maxWidth: .infinity, alignment: .leading)
                    Text("≈ \(Int(s.footprintGB)) GB").font(DS.Font.caption).foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .trailing)
                    verdictBadge(s.verdict)
                }
                .padding(.vertical, DS.Spacing.xs)
                if index < suggestions.count - 1 { DS.Divider() }
            }
        }
    }

    private func verdictBadge(_ v: AIVerdict) -> some View {
        let tint: Color = {
            switch v {
            case .smooth: return .green
            case .runnable: return .blue
            case .tight: return .orange
            case .no: return .secondary
            }
        }()
        return Text(v.label)
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 52)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.15)))
            .foregroundStyle(tint)
    }

    private var referencesCard: some View {
        Card {
            SectionLabel(text: L10n.t("check.ai.section.refs"))
            ForEach(Array(AIModelAdvisor.references.enumerated()), id: \.offset) { index, ref in
                Button {
                    if let url = URL(string: ref.url) { NSWorkspace.shared.open(url) }
                } label: {
                    HStack(spacing: DS.Spacing.md) {
                        Image(systemName: "arrow.up.forward.square.fill").foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ref.title).font(DS.Font.bodyEmphasis).foregroundStyle(.primary)
                            Text(ref.subtitle).font(DS.Font.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, DS.Spacing.xs)
                if index < AIModelAdvisor.references.count - 1 { DS.Divider() }
            }
        }
    }

    private func disclaimer(_ ctx: AIHardwareContext) -> some View {
        let text: String
        if appleSilicon {
            text = L10n.t("check.ai.disc.apple")
        } else if ctx.hasDiscreteGPU {
            text = L10n.t("check.ai.disc.dgpu")
        } else {
            text = L10n.t("check.ai.disc.igpu")
        }
        return Text(text)
            .font(DS.Font.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(DS.Font.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 16, weight: .semibold))
        }
    }

    @MainActor
    private func loadEvaluation() async {
        // Keep cached UI; refresh quietly in the background.
        let showLoading = ctx == nil
        if showLoading { isLoading = true }

        let ram = ramGB
        let isApple = appleSilicon
        guard ram > 0 else {
            isLoading = false
            return
        }

        let result = await Task.detached(priority: .userInitiated) { () -> (AIHardwareContext, [AIModelSuggestion], AIModelSuggestion?) in
            let context = AIHardwareContext.current(ramGB: ram, appleSilicon: isApple)
            let list = AIModelAdvisor.suggestions(context)
            let sweet = AIModelAdvisor.sweetSpot(context)
            return (context, list, sweet)
        }.value

        guard !Task.isCancelled else { return }
        ctx = result.0
        suggestions = result.1
        sweetSpot = result.2
        isLoading = false
    }
}
