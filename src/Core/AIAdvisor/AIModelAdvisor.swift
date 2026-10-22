import Foundation

/// Whether a given LLM can run on this machine.
enum AIVerdict: String, Sendable {
    case smooth   // Comfortable
    case runnable // Runnable
    case tight    // Tight / slow
    case no       // Not recommended

    var label: String {
        switch self {
        case .smooth: return L10n.t("ai.verdict.smooth")
        case .runnable: return L10n.t("ai.verdict.runnable")
        case .tight: return L10n.t("ai.verdict.tight")
        case .no: return L10n.t("ai.verdict.no")
        }
    }
    var rank: Int {
        switch self {
        case .smooth: return 3
        case .runnable: return 2
        case .tight: return 1
        case .no: return 0
        }
    }
}

struct AIModelSuggestion: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let params: Double        // Billions of parameters
    let footprintGB: Double    // Est. VRAM/RAM for Q4 + light context
    let verdict: AIVerdict
}

/// Local hardware context for the advisor.
struct AIHardwareContext: Sendable {
    var ramGB: Double
    var appleSilicon: Bool
    /// Discrete VRAM (GB); 0 if none.
    var discreteVramGB: Double
    var discreteGPUName: String?

    var hasDiscreteGPU: Bool { discreteVramGB > 0 }

    static func current(ramGB: Double, appleSilicon: Bool) -> AIHardwareContext {
        let gpu = GraphicsProbe.primaryDiscreteGPU()
        return AIHardwareContext(
            ramGB: ramGB,
            appleSilicon: appleSilicon,
            discreteVramGB: gpu?.vramGB ?? 0,
            discreteGPUName: gpu?.name
        )
    }
}

/// Local LLM fit advisor.
///
/// - Apple Silicon: unified memory shared by GPU/ANE.
/// - Intel + discrete GPU: prefer discrete VRAM; over VRAM but within offload → tight.
/// - Intel iGPU-only: small fraction of system RAM, heavily demoted.
enum AIModelAdvisor {

    /// Primary budget (GB): unified / discrete VRAM / CPU-only effective.
    static func budgetGB(_ ctx: AIHardwareContext) -> Double {
        if ctx.appleSilicon {
            return max(2, ctx.ramGB - 8)
        }
        if ctx.hasDiscreteGPU {
            // Discrete: keep weights in VRAM; reserve ~1GB for runtime/driver.
            return max(1.5, ctx.discreteVramGB - 1)
        }
        // iGPU / no discrete: don't treat whole-system RAM as VRAM.
        return max(1.5, (ctx.ramGB - 10) * 0.4)
    }

    /// Intel discrete: max footprint if some layers offload to system RAM (still slow).
    private static func offloadCeilingGB(_ ctx: AIHardwareContext) -> Double {
        guard !ctx.appleSilicon, ctx.hasDiscreteGPU else { return budgetGB(ctx) }
        let vram = max(0, ctx.discreteVramGB - 1)
        let ramPart = max(0, (ctx.ramGB - 10) * 0.35)
        return vram + ramPart
    }

    /// Q4_K_M rule of thumb: ~0.55 GB / B params + ~1.5 GB context/runtime.
    static func footprintGB(params: Double) -> Double {
        params * 0.55 + 1.5
    }

    /// Common open models (2026), small → large.
    static let catalog: [(name: String, params: Double)] = [
        ("Llama 3.2 3B", 3),
        ("Gemma 3 4B", 4),
        ("Qwen3 4B", 4),
        ("Llama 3.1 8B", 8),
        ("Qwen3 8B", 8),
        ("DeepSeek-R1 Distill 8B", 8),
        ("Gemma 3 12B", 12),
        ("Phi-4 14B", 14),
        ("Qwen3 14B", 14),
        ("Mistral Small 24B", 24),
        ("Gemma 3 27B", 27),
        ("Qwen3 32B", 32),
        ("Llama 3.3 70B", 70),
        ("Qwen3 72B", 72),
    ]

    static func suggestions(_ ctx: AIHardwareContext) -> [AIModelSuggestion] {
        let primary = budgetGB(ctx)
        let offload = offloadCeilingGB(ctx)

        return catalog.map { m in
            let fp = footprintGB(params: m.params)
            var verdict: AIVerdict

            if ctx.appleSilicon {
                if fp <= primary * 0.6 { verdict = .smooth }
                else if fp <= primary * 0.9 { verdict = .runnable }
                else if fp <= primary * 1.1 { verdict = .tight }
                else { verdict = .no }
            } else if ctx.hasDiscreteGPU {
                // Fits VRAM → tier by headroom; slight over + offload → at most tight.
                if fp <= primary * 0.6 { verdict = .smooth }
                else if fp <= primary * 0.9 { verdict = .runnable }
                else if fp <= primary * 1.05 { verdict = .tight }
                else if fp <= offload * 0.95 { verdict = .tight }
                else { verdict = .no }
                verdict = demoteForIntel(verdict: verdict, params: m.params, vramGB: ctx.discreteVramGB)
            } else {
                if fp <= primary * 0.6 { verdict = .smooth }
                else if fp <= primary * 0.9 { verdict = .runnable }
                else if fp <= primary * 1.1 { verdict = .tight }
                else { verdict = .no }
                verdict = demoteForIntel(verdict: verdict, params: m.params, vramGB: 0)
            }

            return AIModelSuggestion(name: m.name, params: m.params, footprintGB: fp, verdict: verdict)
        }
    }

    /// Extra demotion on Intel: looser with big dGPU, tighter on iGPU.
    private static func demoteForIntel(verdict: AIVerdict, params: Double, vramGB: Double) -> AIVerdict {
        if vramGB >= 8 {
            if params > 32 { return .no }
            if params > 14 { return min(verdict, .tight) }
            return verdict
        }
        if vramGB >= 4 {
            if params > 14 { return .no }
            if params > 8 { return min(verdict, .tight) }
            if params > 4 { return min(verdict, .runnable) }
            return verdict
        }
        // No discrete / iGPU: large models are glacial even in RAM
        if params > 14 { return .no }
        if params > 8 { return min(verdict, .tight) }
        if params > 4 { return min(verdict, .runnable) }
        return verdict
    }

    private static func min(_ a: AIVerdict, _ b: AIVerdict) -> AIVerdict {
        a.rank <= b.rank ? a : b
    }

    static func sweetSpot(_ ctx: AIHardwareContext) -> AIModelSuggestion? {
        suggestions(ctx)
            .filter { $0.verdict.rank >= AIVerdict.runnable.rank }
            .max { $0.params < $1.params }
    }

    static var references: [(title: String, subtitle: String, url: String)] {
        [
            (L10n.t("ai.ref.ollama.title"), L10n.t("ai.ref.ollama.sub"), "https://ollama.com/library"),
            (L10n.t("ai.ref.lm.title"), L10n.t("ai.ref.lm.sub"), "https://lmstudio.ai"),
            (L10n.t("ai.ref.hf.title"), L10n.t("ai.ref.hf.sub"), "https://huggingface.co/models"),
            (L10n.t("ai.ref.mlx.title"), L10n.t("ai.ref.mlx.sub"), "https://github.com/ml-explore/mlx"),
        ]
    }
}
