import Foundation

/// 单个大模型的可跑性判定。
enum AIVerdict: String, Sendable {
    case smooth   // 流畅
    case runnable // 可跑
    case tight    // 勉强
    case no       // 不建议

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
    let params: Double        // 十亿参数
    let footprintGB: Double    // Q4 量化 + 少量上下文的显存/内存占用估算
    let verdict: AIVerdict
}

/// 评估所用的本机算力上下文。
struct AIHardwareContext: Sendable {
    var ramGB: Double
    var appleSilicon: Bool
    /// 独显专用显存（GB）；无独显为 0。
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

/// 本地大模型可跑性顾问。
///
/// - Apple Silicon：统一内存，GPU/ANE 可共享大部分内存做推理。
/// - Intel + 独显：系统内存与显存分离，**优先按独显 VRAM** 判断能否 GPU 加速；
///   超出显存但仍在系统内存 offload 范围内 → 降为「勉强」。
/// - Intel 仅核显：有效预算走系统内存的一小部分，并强力降档。
enum AIModelAdvisor {

    /// 展示用的主预算（GB）：统一内存 / 独显显存 / 无独显时的 CPU 有效预算。
    static func budgetGB(_ ctx: AIHardwareContext) -> Double {
        if ctx.appleSilicon {
            return max(2, ctx.ramGB - 8)
        }
        if ctx.hasDiscreteGPU {
            // 独显：权重优先放进 VRAM，预留约 1GB 给运行时/驱动。
            return max(1.5, ctx.discreteVramGB - 1)
        }
        // 仅核显 / 无可用独显：不能把整机 RAM 当显存。
        return max(1.5, (ctx.ramGB - 10) * 0.4)
    }

    /// Intel 独显场景下，允许部分层 offload 到系统内存的上限（仍很慢）。
    private static func offloadCeilingGB(_ ctx: AIHardwareContext) -> Double {
        guard !ctx.appleSilicon, ctx.hasDiscreteGPU else { return budgetGB(ctx) }
        let vram = max(0, ctx.discreteVramGB - 1)
        let ramPart = max(0, (ctx.ramGB - 10) * 0.35)
        return vram + ramPart
    }

    /// Q4_K_M 量化经验值：约 0.55 GB / 十亿参数，再加 ~1.5GB 上下文与运行时开销。
    static func footprintGB(params: Double) -> Double {
        params * 0.55 + 1.5
    }

    /// 主流开源模型目录（2026，覆盖从小到大的常见档位）。
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
                // 能放进独显 → 按显存余量分档；略超显存但可 offload → 最多勉强。
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

    /// Intel 算力降档：有较大独显时放宽，仅核显时收紧。
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
        // 无独显 / 核显：大模型即使塞进内存也极慢
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
