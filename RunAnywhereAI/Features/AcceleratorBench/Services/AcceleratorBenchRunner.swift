//
//  AcceleratorBenchRunner.swift
//  RunAnywhereAI
//
//  Executes the three bench modes. Model-agnostic throughout: everything it
//  needs about a contender comes from `RAModelInfo`, so a model added to the
//  catalog later is benchable with no change here.
//
//  Measurement rules this file holds to:
//   * Every pass gets a discarded warm-up generation first, so first-call
//     specialization and cache population are never charged to the number.
//   * Only one model is resident at a time. Two LLMs in memory would have them
//     competing for bandwidth, and the loser would look like the accelerator's
//     fault.
//   * Final token counts and tok/s come from the engine's own
//     `GenerationResult`. The per-token stream is used for the live chart and
//     the host-CPU windows only, because a text delta is not guaranteed to be
//     exactly one token.
//

import Foundation
import RunAnywhere
import os

// MARK: - Errors

enum AcceleratorBenchError: LocalizedError {
    case noContenders
    case emptyPrompt
    case loadFailed(model: String, underlying: Error)
    case generationFailed(model: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .noContenders:
            return "Pick at least one model to bench. Models must be downloaded first — "
                + "the picker only lists what is on disk."
        case .emptyPrompt:
            return "Type a prompt first. This bench measures real generations, not synthetic ones."
        case let .loadFailed(model, error):
            return "Could not load \(model): \(error.localizedDescription)"
        case let .generationFailed(model, error):
            return "Generation failed on \(model): \(error.localizedDescription)"
        }
    }
}

// MARK: - Pass spec

/// The generation settings one measured pass uses.
///
/// Grouped rather than passed loose so the quiet and loaded halves of a
/// contention run cannot drift apart: they are handed the same value.
struct BenchPassSpec: Sendable {
    let prompt: String
    let maxTokens: Int
    let systemPrompt: String?
    /// Whether to publish partial text as it streams. Off for the comparison
    /// modes, where nobody reads the answer and the callback is pure overhead.
    let streamsAnswer: Bool

    func withPrompt(_ prompt: String) -> BenchPassSpec {
        BenchPassSpec(
            prompt: prompt,
            maxTokens: maxTokens,
            systemPrompt: systemPrompt,
            streamsAnswer: streamsAnswer
        )
    }
}

// MARK: - Progress

/// What the runner is doing right now, for the status line.
struct BenchProgress: Sendable {
    var phase: String
    var contender: String
    var detail: String
    /// 0…1 where the runner can compute one, nil for open-ended phases.
    var fraction: Double?

    static let idle = BenchProgress(phase: "", contender: "", detail: "", fraction: nil)
}

// MARK: - Runner

@MainActor
final class AcceleratorBenchRunner {
    private let logger = Logger(subsystem: "com.runanywhere.RunAnywhereAI", category: "AcceleratorBench")

    /// Models this app session has already brought up once. A second load hits
    /// NeuRT's content-addressed `.mlmodelc` cache, which is a different — and
    /// much better — number than the first, so the two are labelled apart
    /// rather than averaged into a meaningless middle.
    private var everLoaded: Set<String> = []

    private let loadGenerator = CpuLoadGenerator()

    /// Live token text as it streams, so the prompt panel can show the answer
    /// being written rather than a spinner.
    var onPartialAnswer: (@MainActor (String) -> Void)?
    var onSample: (@MainActor (BenchSample) -> Void)?
    var onProgress: (@MainActor (BenchProgress) -> Void)?

    // MARK: Catalog

    /// Every downloaded language model, as contenders.
    ///
    /// Built-ins are excluded: Apple's Foundation Models path is not a
    /// RunAnywhere engine and its numbers would not be ours to publish.
    nonisolated static func availableContenders(from models: [RAModelInfo]) -> [BenchContender] {
        models
            .filter { model in
                guard model.category == .language, !model.isBuiltIn else { return false }
                if model.isDownloadedOnDisk { return true }
                // The registry marks a model downloaded before the artifact
                // probe catches up, so a non-empty local path counts too.
                return !model.localPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .map(BenchContender.init(model:))
            .sorted { lhs, rhs in
                if lhs.accelerator == rhs.accelerator {
                    return lhs.displayName < rhs.displayName
                }
                // ANE first — it is the subject of the bench.
                return lhs.accelerator.sortRank < rhs.accelerator.sortRank
            }
    }

    // MARK: Mode 1 — one prompt, one or more contenders

    func runPromptPass(
        contenders: [BenchContender],
        prompt: String,
        maxTokens: Int,
        systemPrompt: String?
    ) async throws -> [BenchPassResult] {
        guard !contenders.isEmpty else { throw AcceleratorBenchError.noContenders }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AcceleratorBenchError.emptyPrompt }

        var results: [BenchPassResult] = []
        for (index, contender) in contenders.enumerated() {
            report(
                phase: "Generating",
                contender: contender.displayName,
                detail: "\(index + 1) of \(contenders.count)",
                fraction: Double(index) / Double(contenders.count)
            )
            let load = try await bringUp(contender)
            try await warmUp()
            let result = try await measure(
                contender: contender,
                spec: BenchPassSpec(
                    prompt: trimmed,
                    maxTokens: maxTokens,
                    systemPrompt: systemPrompt,
                    streamsAnswer: true
                ),
                load: load
            )
            results.append(result)
            await tearDown()
        }
        report(phase: "", contender: "", detail: "", fraction: nil)
        return results
    }

    // MARK: Mode 2 — contention

    // swiftlint:disable function_body_length
    /// Quiet pass, then the identical pass with `loadThreads` cores stolen.
    ///
    /// The order is fixed rather than randomised on purpose: the quiet pass
    /// must run on a machine this bench has not already heated up.
    func runContention(
        contenders: [BenchContender],
        prompt: String,
        maxTokens: Int,
        systemPrompt: String?,
        loadThreads: Int
    ) async throws -> [BenchContentionResult] {
        guard !contenders.isEmpty else { throw AcceleratorBenchError.noContenders }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AcceleratorBenchError.emptyPrompt }

        var results: [BenchContentionResult] = []
        let steps = Double(contenders.count * 2)
        var step = 0.0
        // Both halves get the identical spec — same prompt, same seed, same
        // token budget. Only the machine's load differs between them.
        let spec = BenchPassSpec(
            prompt: trimmed,
            maxTokens: maxTokens,
            systemPrompt: systemPrompt,
            streamsAnswer: false
        )

        for contender in contenders {
            let load = try await bringUp(contender)

            report(
                phase: "Quiet pass",
                contender: contender.displayName,
                detail: "no competing load",
                fraction: step / steps
            )
            try await warmUp()
            let quiet = try await measure(contender: contender, spec: spec, load: load)
            step += 1

            report(
                phase: "Loaded pass",
                contender: contender.displayName,
                detail: "\(loadThreads) threads spinning",
                fraction: step / steps
            )
            loadGenerator.start(threadCount: loadThreads)
            // Let the scheduler actually place the load before timing starts,
            // otherwise the first tokens are measured on a still-quiet machine.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let loaded: BenchPassResult
            do {
                loaded = try await measure(contender: contender, spec: spec, load: load)
            } catch {
                loadGenerator.stop()
                await tearDown()
                throw error
            }
            loadGenerator.stop()
            step += 1

            results.append(
                BenchContentionResult(
                    contender: contender,
                    quiet: quiet,
                    loaded: loaded,
                    loadThreads: loadThreads
                )
            )
            await tearDown()
        }
        report(phase: "", contender: "", detail: "", fraction: nil)
        return results
    }

    // MARK: Mode 3 — endurance

    /// Cycle independent prompts for `duration`, sampling throughout.
    func runEndurance(
        contenders: [BenchContender],
        prompts: [String],
        duration: TimeInterval,
        maxTokens: Int,
        systemPrompt: String?
    ) async throws -> [BenchEnduranceResult] {
        guard !contenders.isEmpty else { throw AcceleratorBenchError.noContenders }
        let pool = prompts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !pool.isEmpty else { throw AcceleratorBenchError.emptyPrompt }

        HostCostSampler.startBatteryMonitoring()
        var results: [BenchEnduranceResult] = []
        let baseSpec = BenchPassSpec(
            prompt: "",
            maxTokens: maxTokens,
            systemPrompt: systemPrompt,
            streamsAnswer: false
        )

        for contender in contenders {
            _ = try await bringUp(contender)
            try await warmUp()

            let collector = BenchSampleCollector()
            let started = Date()
            var totalTokens = 0
            var promptsDone = 0
            var promptIndex = 0

            while Date().timeIntervalSince(started) < duration {
                try Task.checkCancellation()
                let prompt = pool[promptIndex % pool.count]
                promptIndex += 1

                let remaining = duration - Date().timeIntervalSince(started)
                report(
                    phase: "Endurance",
                    contender: contender.displayName,
                    detail: "\(promptsDone) prompts · \(Self.clock(remaining)) left",
                    fraction: Date().timeIntervalSince(started) / duration
                )

                let produced = try await streamCountingTokens(
                    spec: baseSpec.withPrompt(prompt),
                    modelName: contender.displayName
                ) { deltaCount in
                    if let sample = collector.record(tokens: totalTokens + deltaCount) {
                        self.onSample?(sample)
                    }
                }

                totalTokens += produced.outputTokens
                promptsDone += 1
                collector.finalize(tokens: totalTokens)
            }

            let elapsed = Date().timeIntervalSince(started)
            let samples = collector.samples
            results.append(
                BenchEnduranceResult(
                    contender: contender,
                    samples: samples,
                    totalTokens: totalTokens,
                    promptsCompleted: promptsDone,
                    duration: elapsed,
                    hostCpuSeconds: collector.totalCpuSeconds,
                    peakThermal: collector.peakThermal,
                    startBattery: collector.startBattery,
                    endBattery: HostCostSampler.batteryLevel(),
                    startedAt: started,
                    firstMinuteTokensPerSecond: BenchStats.medianRate(
                        in: samples,
                        elapsedRange: 0...min(60, elapsed)
                    ),
                    lastMinuteTokensPerSecond: BenchStats.medianRate(
                        in: samples,
                        elapsedRange: max(0, elapsed - 60)...elapsed
                    )
                )
            )
            await tearDown()
        }
        report(phase: "", contender: "", detail: "", fraction: nil)
        return results
    }

    // swiftlint:enable function_body_length

    func stopSyntheticLoad() {
        loadGenerator.stop()
    }

    // MARK: - Model lifecycle

    private struct LoadOutcome {
        let ms: Double
        let wasWarm: Bool
    }

    private func bringUp(_ contender: BenchContender) async throws -> LoadOutcome {
        // Unload first: Chat or a previous contender may still hold an LLM,
        // and two resident models would contend for memory bandwidth.
        try? await RunAnywhere.models.unload(category: .language)

        let wasWarm = everLoaded.contains(contender.modelId)
        report(
            phase: wasWarm ? "Loading (warm)" : "Loading (cold)",
            contender: contender.displayName,
            detail: wasWarm ? "from the compiled-graph cache" : "first load compiles and specializes",
            fraction: nil
        )

        let start = Date()
        do {
            _ = try await RunAnywhere.models.load(id: contender.modelId)
        } catch {
            throw AcceleratorBenchError.loadFailed(model: contender.displayName, underlying: error)
        }
        let ms = Date().timeIntervalSince(start) * 1000
        everLoaded.insert(contender.modelId)
        let msText = String(format: "%.0f", ms)
        logger.info(
            """
            AcceleratorBench loaded \(contender.modelId, privacy: .public) \
            in \(msText, privacy: .public)ms warm=\(wasWarm, privacy: .public)
            """
        )
        return LoadOutcome(ms: ms, wasWarm: wasWarm)
    }

    private func tearDown() async {
        try? await RunAnywhere.models.unload(category: .language)
    }

    /// A short discarded generation. Charging first-call cost to the measured
    /// pass would make every cold number look like an accelerator problem.
    private func warmUp() async throws {
        let events = try await RunAnywhere.llm.generateStream(
            prompt: "Hi",
            options: LlmOptions(maxOutputTokens: 4, temperature: 0.0)
        )
        for try await event in events {
            if case .completed = event { break }
        }
    }

    // MARK: - Measurement

    private func measure(
        contender: BenchContender,
        spec: BenchPassSpec,
        load: LoadOutcome
    ) async throws -> BenchPassResult {
        let collector = BenchSampleCollector()
        let wallStart = Date()

        let produced = try await streamCountingTokens(
            spec: spec,
            modelName: contender.displayName
        ) { deltaCount in
            if let sample = collector.record(tokens: deltaCount) {
                self.onSample?(sample)
            }
        }

        let wallMs = Date().timeIntervalSince(wallStart) * 1000
        let cpuSeconds = collector.totalCpuSeconds
        collector.finalize(tokens: produced.deltaCount)

        // Prefer the engine's own rate. Fall back to wall-clock only when the
        // engine reported nothing, and say so by deriving it the same way.
        let engineRate = Double(produced.result?.tokensPerSecond ?? 0)
        let outputTokens = produced.outputTokens
        let derivedRate = wallMs > 0 ? Double(outputTokens) / (wallMs / 1000) : 0
        let rate = engineRate > 0 ? engineRate : derivedRate

        let ttft = produced.result.map { Double($0.timeToFirstTokenMs) }.flatMap { $0 > 0 ? $0 : nil }

        return BenchPassResult(
            contender: contender,
            prompt: spec.prompt,
            answer: produced.text,
            ttftMs: ttft,
            tokensPerSecond: rate,
            medianTokensPerSecond: BenchStats.median(collector.samples.map(\.tokensPerSecond)) ?? rate,
            inputTokens: produced.result?.inputTokens ?? 0,
            outputTokens: outputTokens,
            wallMs: wallMs,
            loadMs: load.ms,
            wasWarmLoad: load.wasWarm,
            hostCpuSeconds: cpuSeconds,
            hostCoresHeld: wallMs > 0 ? cpuSeconds / (wallMs / 1000) : 0,
            peakThermal: collector.peakThermal,
            samples: collector.samples,
            finishedAt: Date()
        )
    }

    private struct StreamOutcome {
        let text: String
        let deltaCount: Int
        let result: GenerationResult?

        /// The engine's count where it gave one; the delta count otherwise. A
        /// text delta is usually one token but that is not contractual, so the
        /// engine's number wins whenever it exists.
        var outputTokens: Int {
            if let engine = result?.outputTokens, engine > 0 { return engine }
            return deltaCount
        }
    }

    private func streamCountingTokens(
        spec: BenchPassSpec,
        modelName: String,
        onDelta: (Int) -> Void
    ) async throws -> StreamOutcome {
        var text = ""
        var deltaCount = 0
        var final: GenerationResult?

        do {
            let events = try await RunAnywhere.llm.generateStream(
                prompt: spec.prompt,
                options: LlmOptions(
                    maxOutputTokens: spec.maxTokens,
                    // Greedy. A sampled run would change the token count between
                    // the quiet and loaded passes and contaminate the delta.
                    temperature: 0.0,
                    seed: 0,
                    systemPrompt: spec.systemPrompt
                )
            )

            for try await event in events {
                try Task.checkCancellation()
                switch event {
                case .textDelta(_, _, _, _, let delta):
                    text += delta
                    deltaCount += 1
                    if spec.streamsAnswer { onPartialAnswer?(text) }
                    onDelta(deltaCount)
                case .completed(_, let result):
                    final = result
                    if spec.streamsAnswer, !result.text.isEmpty { onPartialAnswer?(result.text) }
                case .failed(_, _, let error):
                    throw AcceleratorBenchError.generationFailed(model: modelName, underlying: error)
                default:
                    break
                }
            }
        } catch let error as AcceleratorBenchError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AcceleratorBenchError.generationFailed(model: modelName, underlying: error)
        }

        return StreamOutcome(
            text: final?.text.isEmpty == false ? (final?.text ?? text) : text,
            deltaCount: deltaCount,
            result: final
        )
    }

    // MARK: - Helpers

    private func report(phase: String, contender: String, detail: String, fraction: Double?) {
        onProgress?(BenchProgress(phase: phase, contender: contender, detail: detail, fraction: fraction))
    }

    nonisolated static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Ordering

extension BenchAccelerator {
    var sortRank: Int {
        switch self {
        case .ane: return 0
        case .gpu: return 1
        case .cpu: return 2
        case .other: return 3
        }
    }
}
