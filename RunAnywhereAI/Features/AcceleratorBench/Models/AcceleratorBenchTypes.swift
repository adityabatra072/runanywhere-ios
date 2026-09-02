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

    init(framework: InferenceFramework) {
        switch framework {
        case .coreml:
            // The `.coreml` wire value is NeuRT, which pins compute units to
            // cpuAndNeuralEngine. See ModelPresentation.consumerBackendBadgeLabel.
            self = .ane
        case .mlx:
            self = .gpu
        case .llamaCpp, .onnx, .executorch, .tflite, .mediapipe, .mlc, .swiftTransformers:
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

// MARK: - Contender

/// One model-on-one-accelerator entry in the bench.
struct BenchContender: Identifiable, Hashable, Sendable {
    let modelId: String
    let displayName: String
    let framework: InferenceFramework
    let accelerator: BenchAccelerator
    /// Registry size hint, for the picker subtitle only.
    let sizeBytes: Int64

    var id: String { modelId }

    init(model: RAModelInfo) {
        self.modelId = model.id
        self.displayName = model.name.isEmpty ? model.id : model.name
        self.framework = model.framework
        self.accelerator = BenchAccelerator(framework: model.framework)
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

/// The same contender measured on a quiet machine and then under load.
///
/// This is the bench's headline: a path really executing on the Neural Engine
/// is a separate block of silicon and barely notices competing CPU work, while
/// a path on the general-purpose cores contends for them directly.
struct BenchContentionResult: Identifiable, Sendable {
    let id = UUID()
    let contender: BenchContender
    let quiet: BenchPassResult
    let loaded: BenchPassResult
    /// How many synthetic load threads ran during `loaded`.
    let loadThreads: Int

    /// Signed change in per-token latency, in percent. Near zero is the win.
    var latencyDeltaPercent: Double? {
        guard let quietMs = quiet.msPerToken,
              let loadedMs = loaded.msPerToken,
              quietMs > 0 else { return nil }
        return (loadedMs - quietMs) / quietMs * 100
    }

    var throughputRetentionPercent: Double? {
        guard quiet.tokensPerSecond > 0 else { return nil }
        return loaded.tokensPerSecond / quiet.tokensPerSecond * 100
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

    /// Sustained throughput as a fraction of the opening minute. A flat line
    /// is the claim; a declining one is thermal throttling.
    var sustainPercent: Double? {
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
