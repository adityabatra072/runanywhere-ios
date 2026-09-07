//
//  AcceleratorBenchTypes.swift
//  RunAnywhereAI
//
//  Value types for the Accelerator Bench: a live, prompt-driven comparison of
//  the same work on the Neural Engine, the CPU and the GPU.
//
//  Nothing here names a model or a family. A contender is any LLM in the
//  catalog that is on disk; its accelerator is read off `RAModelInfo.framework`.
//  Adding a model to the catalog is all it takes to bench it.
//

import Foundation
import RunAnywhere
import SwiftUI

// MARK: - Accelerator

/// Which silicon block executes a contender, derived from its engine.
///
/// This is the axis the bench compares on, so it is deliberately coarser than
/// `InferenceFramework`: `llamaCpp` and `onnx` both mean "general-purpose
/// cores" for our purposes, and what matters is that they contend for the same
/// cores the app's own UI runs on, which the ANE does not.
enum BenchAccelerator: String, CaseIterable, Identifiable, Sendable {
    case ane
    case gpu
    case cpu
    case other

    var id: String { rawValue }

    /// Classify from the placement the SDK actually reports.
    ///
    /// ## Why this does not read the framework
    ///
    /// It used to, and it was wrong. `.llamaCpp` was mapped to `.cpu`, but on
    /// Apple hardware llama.cpp offloads to Metal by default: on an iPhone 15
    /// the log reads `using device MTL0 (Apple A16 GPU)` and
    /// `offloaded 15/15 layers to GPU`. So a contender the bench labelled "CPU"
    /// was running entirely on the GPU, and the screen carried a false claim.
    ///
    /// It also produced an impossible measurement — that contender came out
    /// 83% FASTER with three of six cores stolen, because CPU load drags the
    /// package into a higher power state and the GPU's clocks rise with it.
    ///
    /// `LoadedModel.actualDevice.deviceKind` is what the runtime did. Trust it,
    /// and fall back to the framework only when it says nothing.
    init(deviceKind: String, framework: InferenceFramework) {
        switch deviceKind.lowercased() {
        case let kind where kind.contains("npu") || kind.contains("neural") || kind.contains("ane"):
            self = .ane
        case let kind where kind.contains("gpu") || kind.contains("metal"):
            self = .gpu
        case let kind where kind.contains("cpu"):
            self = .cpu
        default:
            self = BenchAccelerator(assumingFrom: framework)
        }
    }

    /// Best guess before a model has been loaded, for the picker only. Never
    /// used to label a result — a result carries its measured placement.
    init(assumingFrom framework: InferenceFramework) {
        switch framework {
        case .coreml:
            // The `.coreml` wire value is NeuRT, which pins compute units to
            // cpuAndNeuralEngine. See ModelPresentation.consumerBackendBadgeLabel.
            self = .ane
        case .mlx:
            self = .gpu
        case .llamaCpp:
            // Metal by default on Apple hardware. Requesting `.cpu` at load
            // time is what actually produces a CPU arm.
            self = .gpu
        case .onnx, .executorch, .tflite, .mediapipe, .mlc, .swiftTransformers:
            self = .cpu
        default:
            self = .other
        }
    }

    var label: String {
        switch self {
        case .ane: return "Neural Engine"
        case .gpu: return "GPU"
        case .cpu: return "CPU"
        case .other: return "Other"
        }
    }

    var shortLabel: String {
        switch self {
        case .ane: return "ANE"
        case .gpu: return "GPU"
        case .cpu: return "CPU"
        case .other: return "—"
        }
    }

    /// The engine that actually executes it, for the provenance line.
    var engineLabel: String {
        switch self {
        case .ane: return "NeuRT"
        case .gpu: return "MLX"
        case .cpu: return "llama.cpp"
        case .other: return "—"
        }
    }

    var tint: Color {
        switch self {
        case .ane: return AppColors.brand
        case .gpu: return AppColors.primaryPurple
        case .cpu: return AppColors.primaryBlue
        case .other: return AppColors.textTertiary
        }
    }

    var symbol: String {
        switch self {
        case .ane: return "cpu.fill"
        case .gpu: return "square.stack.3d.up.fill"
        case .cpu: return "square.grid.2x2.fill"
        case .other: return "questionmark.square"
        }
    }
}

// MARK: - Placement

/// Where a contender actually ran, as reported by the load handle.
///
/// Kept on every result so a number can never be presented under a backend
/// label that the runtime did not confirm.
struct BenchPlacement: Sendable, Hashable {
    let requested: BenchAccelerator
    let actual: BenchAccelerator
    let actualBackend: InferenceFramework
    let deviceName: String
    let deviceKind: String
    let fallbackReason: String?

    /// The runtime did not honour the request. Worth surfacing: requesting CPU
    /// and silently getting Metal is exactly how a bench ends up publishing a
    /// GPU number as a CPU one.
    var divergedFromRequest: Bool { requested != actual }

    static func unknown(_ accelerator: BenchAccelerator) -> BenchPlacement {
        BenchPlacement(
            requested: accelerator,
            actual: accelerator,
            actualBackend: .unspecified,
            deviceName: "",
            deviceKind: "",
            fallbackReason: nil
        )
    }
}

// MARK: - Contender

/// One model run under one requested accelerator policy.
///
/// The policy is part of the identity, not a setting: the same GGUF is a
/// different contender on the CPU than on the GPU, and on Apple hardware
/// llama.cpp will pick Metal unless CPU is asked for explicitly.
struct BenchContender: Identifiable, Hashable, Sendable {
    let modelId: String
    let modelName: String
    let framework: InferenceFramework
    /// What this contender asks the runtime for.
    let requested: BenchAccelerator
    /// Registry size hint, for the picker subtitle only.
    let sizeBytes: Int64

    var id: String { "\(modelId)#\(requested.rawValue)" }

    /// Expected placement, for grouping in the picker. A measured result uses
    /// `BenchPlacement.actual` instead.
    var accelerator: BenchAccelerator { requested }

    /// Names the policy too, so two rows for one model are distinguishable.
    var displayName: String {
        needsPolicyInName ? "\(modelName) — \(requested.shortLabel)" : modelName
    }

    /// Only frameworks that can genuinely go either way get the suffix.
    private var needsPolicyInName: Bool { framework == .llamaCpp }

    init(model: RAModelInfo, requesting requested: BenchAccelerator? = nil) {
        self.modelId = model.id
        self.modelName = model.name.isEmpty ? model.id : model.name
        self.framework = model.framework
        self.requested = requested ?? BenchAccelerator(assumingFrom: model.framework)
        self.sizeBytes = model.downloadSizeBytes
    }
}

// MARK: - Live samples

/// One reading taken while generation is in flight.
struct BenchSample: Sendable, Identifiable {
    let id = UUID()
    /// Seconds since the run started.
    let elapsed: TimeInterval
    /// Tokens emitted since the run started.
    let tokens: Int
    /// Instantaneous rate over the sampling window.
    let tokensPerSecond: Double
    /// Host CPU cores this process has burned over the sampling window.
    let hostCores: Double
    let thermal: ProcessInfo.ThermalState
    /// 0…1, or nil where the platform exposes no battery.
    let batteryLevel: Double?
}

// MARK: - One measured generation

/// Everything one prompt-and-answer pass produced.
struct BenchPassResult: Identifiable, Sendable {
    let id = UUID()
    let contender: BenchContender
    /// Where this actually ran, straight off the load handle.
    let placement: BenchPlacement
    let prompt: String
    let answer: String

    /// Nil when the engine reported no TTFT, and suppressed for topologies
    /// where it is not a meaningful number — see `ttftIsMeaningful`.
    let ttftMs: Double?
    let tokensPerSecond: Double
    let medianTokensPerSecond: Double
    let inputTokens: Int
    let outputTokens: Int
    let wallMs: Double

    /// Wall time to bring the model up. Cold on first load, warm after
    /// NeuRT's content-addressed `.mlmodelc` cache has the graph.
    let loadMs: Double
    let wasWarmLoad: Bool

    /// Host CPU seconds this process burned during the measured generation —
    /// NOT the accelerator's own energy. On the ANE path this is orchestration
    /// only; on the CPU path it is the inference itself.
    let hostCpuSeconds: Double
    /// `hostCpuSeconds / wall` — how many cores were held, on average.
    let hostCoresHeld: Double
    /// Millicore-seconds of host CPU per generated token.
    var hostCpuMsPerToken: Double? {
        guard outputTokens > 0 else { return nil }
        return hostCpuSeconds * 1000 / Double(outputTokens)
    }

    let peakThermal: ProcessInfo.ThermalState
    let samples: [BenchSample]
    let finishedAt: Date

    var msPerToken: Double? {
        guard tokensPerSecond > 0 else { return nil }
        return 1000 / tokensPerSecond
    }
}

// MARK: - Contention

/// The same contender measured with and without competing CPU load.
///
/// ## Why this holds arrays instead of two passes
///
/// The first version timed one quiet pass then one loaded pass, and produced a
/// result that was physically impossible: on an iPhone 15 a llama.cpp contender
/// came out **81% faster** with three of six cores stolen from it
/// (116.34 -> 210.29 tok/s, "180.8% retained").
///
/// The cause is pass order interacting with frequency scaling. A quiet pass
/// running first sits on a cool, idle SoC where iOS clocks the cores down and
/// will park a lone inference thread on an efficiency core. Starting the load
/// threads then drags the package into a boosted power state and pushes work
/// onto performance cores — so the handicapped condition hands the CPU path
/// better clocks and better cores, and that gain is larger than the contention
/// being measured.
///
/// So conditions are now visited repeatedly with **alternating order** and
/// compared on medians. Monotonic drift — thermal ramp, DVFS settling — biases
/// both conditions about equally and largely cancels, which one pass each
/// cannot do at any level of care.
struct BenchContentionResult: Identifiable, Sendable {
    let id = UUID()
    let contender: BenchContender
    let quietPasses: [BenchPassResult]
    let loadedPasses: [BenchPassResult]
    /// How many synthetic load threads ran during the loaded passes.
    let loadThreads: Int

    var repetitions: Int { min(quietPasses.count, loadedPasses.count) }

    /// Measured placement, taken from the passes rather than the request.
    var placement: BenchPlacement? {
        (quietPasses.first ?? loadedPasses.first)?.placement
    }

    /// A representative pass per condition, for the answer text and host cost.
    var quiet: BenchPassResult? { Self.representative(of: quietPasses) }
    var loaded: BenchPassResult? { Self.representative(of: loadedPasses) }

    var quietMsPerToken: Double? { BenchStats.median(quietPasses.compactMap(\.msPerToken)) }
    var loadedMsPerToken: Double? { BenchStats.median(loadedPasses.compactMap(\.msPerToken)) }

    var quietTokensPerSecond: Double? {
        BenchStats.median(quietPasses.map(\.tokensPerSecond))
    }
    var loadedTokensPerSecond: Double? {
        BenchStats.median(loadedPasses.map(\.tokensPerSecond))
    }

    /// Median host CPU held during the loaded passes, with the load
    /// generator's own burn already excluded by the runner.
    var loadedHostCoresHeld: Double? { BenchStats.median(loadedPasses.map(\.hostCoresHeld)) }
    var quietHostCoresHeld: Double? { BenchStats.median(quietPasses.map(\.hostCoresHeld)) }

    /// Signed change in median per-token latency, in percent. Near zero is the
    /// claim; a large positive number means the work was queueing for cores.
    var latencyDeltaPercent: Double? {
        guard let quietMs = quietMsPerToken,
              let loadedMs = loadedMsPerToken,
              quietMs > 0 else { return nil }
        return (loadedMs - quietMs) / quietMs * 100
    }

    var throughputRetentionPercent: Double? {
        guard let quietRate = quietTokensPerSecond,
              let loadedRate = loadedTokensPerSecond,
              quietRate > 0 else { return nil }
        return loadedRate / quietRate * 100
    }

    /// Spread of the repetitions within one condition, as a percentage of its
    /// median. This is the honesty check on the delta: if run-to-run noise is
    /// the same size as the effect, the effect has not been measured.
    var quietSpreadPercent: Double? { Self.spread(of: quietPasses) }
    var loadedSpreadPercent: Double? { Self.spread(of: loadedPasses) }

    /// The two conditions did not run at a comparable SoC power state, so the
    /// comparison is not a contention measurement at all.
    ///
    /// Contention cannot make work faster. Retention meaningfully above 100%
    /// means something else dominated — and on a phone that something is
    /// frequency scaling: an idle device sits in a low-power state, and the
    /// load threads themselves drag the package up, raising GPU and memory
    /// clocks along with CPU. Measured on an iPhone 15 with 3 of 6 cores
    /// spinning, llama.cpp on Metal retained **183.5%** and then **294.6%**
    /// across separate runs, reproducibly, with alternating pass order.
    ///
    /// When this is true the panel reports the artifact instead of a verdict.
    /// A benchmark that prints a flattering impossible number is worse than
    /// one that admits it measured the wrong thing.
    var isPowerStateArtifact: Bool {
        guard let retention = throughputRetentionPercent else { return false }
        return retention > 110
    }

    /// Whether this result supports any statement about contention.
    var isTrustworthy: Bool {
        !isPowerStateArtifact && repetitions > 1 && (deltaExceedsNoise ?? false)
    }

    /// True when the measured delta is larger than the noise it sits in.
    ///
    /// Without this a viewer cannot tell a real 3% from a 3% that would have
    /// come out either way, and the panel would present both identically.
    var deltaExceedsNoise: Bool? {
        guard let delta = latencyDeltaPercent else { return nil }
        let noise = max(quietSpreadPercent ?? 0, loadedSpreadPercent ?? 0)
        return abs(delta) > noise
    }

    private static func representative(of passes: [BenchPassResult]) -> BenchPassResult? {
        guard !passes.isEmpty else { return nil }
        let sorted = passes.sorted { ($0.msPerToken ?? .infinity) < ($1.msPerToken ?? .infinity) }
        return sorted[sorted.count / 2]
    }

    private static func spread(of passes: [BenchPassResult]) -> Double? {
        let values = passes.compactMap(\.msPerToken).filter { $0 > 0 }
        guard values.count > 1, let median = BenchStats.median(values), median > 0 else { return nil }
        guard let low = values.min(), let high = values.max() else { return nil }
        return (high - low) / median * 100
    }
}

// MARK: - Endurance

/// A long, sustained run: many independent prompts, back to back.
///
/// The prompts are deliberately independent rather than one growing
/// conversation. ANE fp16 does not accumulate in fp32, so next-token agreement
/// with the fp32 reference decays as the KV cache deepens; a long single
/// context would be measuring that decay instead of sustained throughput.
struct BenchEnduranceResult: Identifiable, Sendable {
    let id = UUID()
    let contender: BenchContender
    /// Where this actually ran, straight off the load handle.
    let placement: BenchPlacement
    let samples: [BenchSample]
    let totalTokens: Int
    let promptsCompleted: Int
    let duration: TimeInterval
    let hostCpuSeconds: Double
    let peakThermal: ProcessInfo.ThermalState
    let startBattery: Double?
    let endBattery: Double?
    let startedAt: Date

    /// Median tok/s over the first 60 s of the run.
    let firstMinuteTokensPerSecond: Double?
    /// Median tok/s over the final 60 s.
    let lastMinuteTokensPerSecond: Double?

    /// The per-window rate series disagrees with the run's own wall-clock
    /// average by more than any real workload could.
    ///
    /// Insurance against publishing nonsense. `averageTokensPerSecond` comes
    /// from total tokens over wall time and is hard to get wrong; a minute
    /// median many times larger or smaller means the windows were mis-attributed.
    /// An M4 endurance leg once reported a first-minute median of 223,365 tok/s
    /// against a true average of 17.62, because the series mixed engine token
    /// counts with text-delta counts and jumped by the difference across a
    /// near-zero window.
    var rateSeriesIsSuspect: Bool {
        guard averageTokensPerSecond > 0 else { return false }
        let bounds = (low: averageTokensPerSecond / 5, high: averageTokensPerSecond * 5)
        for rate in [firstMinuteTokensPerSecond, lastMinuteTokensPerSecond].compactMap({ $0 }) {
            if rate > bounds.high || rate < bounds.low { return true }
        }
        return false
    }

    /// Sustained throughput as a fraction of the opening minute. A flat line
    /// is the claim; a declining one is thermal throttling.
    ///
    /// Nil when the series is suspect — better no number than a wrong one.
    var sustainPercent: Double? {
        guard !rateSeriesIsSuspect else { return nil }
        guard let first = firstMinuteTokensPerSecond, first > 0,
              let last = lastMinuteTokensPerSecond else { return nil }
        return last / first * 100
    }

    /// Battery percentage points consumed per 1,000 generated tokens.
    ///
    /// `UIDevice.batteryLevel` moves in whole percent, so this only means
    /// something once the run is long enough to cross several steps — the view
    /// hides it below `minimumBatteryPoints`.
    static let minimumBatteryPoints = 2.0

    var batteryPointsUsed: Double? {
        guard let start = startBattery, let end = endBattery else { return nil }
        let used = (start - end) * 100
        return used > 0 ? used : nil
    }

    var batteryPointsPerThousandTokens: Double? {
        guard let used = batteryPointsUsed, used >= Self.minimumBatteryPoints, totalTokens > 0 else { return nil }
        return used / Double(totalTokens) * 1000
    }

    var averageTokensPerSecond: Double {
        guard duration > 0 else { return 0 }
        return Double(totalTokens) / duration
    }

    var hostCoresHeld: Double {
        guard duration > 0 else { return 0 }
        return hostCpuSeconds / duration
    }
}

// MARK: - Result set

/// Everything a screen has measured, and which mode produced it.
///
/// Grouped so the report formatter takes one value instead of four parallel
/// arrays that could disagree about which mode they belong to.
struct BenchResultSet: Sendable {
    let mode: BenchMode
    let passes: [BenchPassResult]
    let contention: [BenchContentionResult]
    let endurance: [BenchEnduranceResult]

    var isEmpty: Bool {
        switch mode {
        case .prompt: return passes.isEmpty
        case .contention: return contention.isEmpty
        case .endurance: return endurance.isEmpty
        }
    }
}

// MARK: - Thermal presentation

extension ProcessInfo.ThermalState {
    var benchLabel: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    var benchTint: Color {
        switch self {
        case .nominal: return AppColors.success
        case .fair: return AppColors.warning
        case .serious, .critical: return AppColors.danger
        @unknown default: return AppColors.textTertiary
        }
    }

    /// Ordering so a run can report the worst state it reached.
    var benchSeverity: Int {
        switch self {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        @unknown default: return 0
        }
    }
}

// MARK: - Bench mode

enum BenchMode: String, CaseIterable, Identifiable, Sendable {
    case prompt
    case contention
    case endurance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .prompt: return "Ask"
        case .contention: return "Contention"
        case .endurance: return "Endurance"
        }
    }

    var symbol: String {
        switch self {
        case .prompt: return "text.bubble"
        case .contention: return "arrow.left.arrow.right"
        case .endurance: return "timer"
        }
    }

    var blurb: String {
        switch self {
        case .prompt:
            return "Type a real prompt. The numbers under the answer are measured on this device, "
                + "on this run — not read from a table."
        case .contention:
            return "The same prompt twice: once on a quiet machine, once while every core is busy. "
                + "The Neural Engine is separate silicon, so it should barely move."
        case .endurance:
            return "Many independent prompts, back to back, for as long as you set. Watch whether "
                + "throughput holds and where the heat goes."
        }
    }
}
