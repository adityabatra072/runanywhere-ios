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
    /// Suppress the model's chain of thought.
    ///
    /// Two reasons, and the second is the one that matters. A thinking model
    /// answers the camera with meta-commentary — the 2.6B's first measured
    /// answer opened "The user is asking for a concise explanation in two
    /// sentences about why on-device models are more private…" instead of
    /// answering. And thought tokens count toward `outputTokens`, so leaving
    /// them on means the reported tok/s is partly a measure of how much the
    /// model deliberated, which is not a property of the accelerator.
    let suppressThinking: Bool

    func withPrompt(_ prompt: String) -> BenchPassSpec {
        BenchPassSpec(
            prompt: prompt,
            maxTokens: maxTokens,
            systemPrompt: systemPrompt,
            streamsAnswer: streamsAnswer,
            suppressThinking: suppressThinking
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

    /// Models brought up at least once in this PROCESS.
    ///
    /// Static, not per-instance: two screens each holding their own runner
    /// would otherwise both call their first load "first", when the second one
    /// hits a cache the first one populated.
    ///
    /// And the label says "first this session", not "cold", deliberately.
    /// NeuRT's content-addressed `.mlmodelc` cache lives on disk and survives
    /// app launches, so the first load of a second launch is already warm. From
    /// inside the process there is no way to tell which, and claiming "cold"
    /// would be asserting something unmeasured.
    private static var loadedThisSession: Set<String> = []

    private let loadGenerator = CpuLoadGenerator()

    /// Live token text as it streams, so the prompt panel can show the answer
    /// being written rather than a spinner.
    var onPartialAnswer: (@MainActor (String) -> Void)?
    var onSample: (@MainActor (BenchSample) -> Void)?
    var onProgress: (@MainActor (BenchProgress) -> Void)?

    // MARK: Mode 1 — one prompt, one or more contenders

    func runPromptPass(
        contenders: [BenchContender],
        prompt: String,
        maxTokens: Int,
        systemPrompt: String?,
        suppressThinking: Bool = true
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
                    streamsAnswer: true,
                    suppressThinking: suppressThinking
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
    /// Measure each contender with and without competing load, repeatedly, in
    /// alternating order.
    ///
    /// One quiet pass followed by one loaded pass cannot measure contention on
    /// a phone. Frequency scaling confounds it: the quiet pass runs first on a
    /// cool idle SoC with the cores clocked down, and starting the load threads
    /// boosts the package and migrates work to performance cores — so the
    /// supposedly handicapped condition runs on better hardware. Measured on an
    /// iPhone 15, that artifact made a llama.cpp contender come out 81% FASTER
    /// with three of six cores stolen, which is impossible.
    ///
    /// Two things fix it. A warm-up that visits BOTH power states before
    /// anything is timed, so the first timed pass is not the one paying for
    /// DVFS settling. And repetitions in alternating order, compared on
    /// medians, so any monotonic drift biases both conditions about equally
    /// instead of landing entirely on whichever ran first.
    func runContention(
        contenders: [BenchContender],
        prompt: String,
        maxTokens: Int,
        systemPrompt: String?,
        loadThreads: Int,
        repetitions: Int = 3,
        suppressThinking: Bool = true
    ) async throws -> [BenchContentionResult] {
        guard !contenders.isEmpty else { throw AcceleratorBenchError.noContenders }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AcceleratorBenchError.emptyPrompt }

        let reps = max(1, repetitions)
        var results: [BenchContentionResult] = []
        // Both conditions get the identical spec — same prompt, same seed, same
        // token budget. Only the machine's load differs.
        let spec = BenchPassSpec(
            prompt: trimmed,
            maxTokens: maxTokens,
            systemPrompt: systemPrompt,
            streamsAnswer: false,
            suppressThinking: suppressThinking
        )
        let totalSteps = Double(contenders.count * reps * 2)
        var step = 0.0

        for contender in contenders {
            let load = try await bringUp(contender)

            // Warm-up visits both power states and is entirely discarded.
            report(
                phase: "Settling",
                contender: contender.displayName,
                detail: "warming both power states before timing",
                fraction: step / totalSteps
            )
            try await warmUp()
            loadGenerator.start(threadCount: loadThreads)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            try await warmUp()
            loadGenerator.stop()
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            var quietPasses: [BenchPassResult] = []
            var loadedPasses: [BenchPassResult] = []

            for rep in 0..<reps {
                // Alternate which condition goes first, so a monotonic ramp
                // cannot accumulate entirely on one of them.
                let quietFirst = rep.isMultiple(of: 2)
                for isQuietTurn in (quietFirst ? [true, false] : [false, true]) {
                    try Task.checkCancellation()
                    report(
                        phase: isQuietTurn ? "Quiet pass" : "Loaded pass",
                        contender: contender.displayName,
                        detail: isQuietTurn
                            ? "no competing load · run \(rep + 1) of \(reps)"
                            : "\(loadThreads) threads spinning · run \(rep + 1) of \(reps)",
                        fraction: step / totalSteps
                    )

                    if !isQuietTurn {
                        loadGenerator.start(threadCount: loadThreads)
                        // Let the scheduler actually place the load before
                        // timing starts, or the first tokens are measured on a
                        // still-quiet machine.
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                    }

                    do {
                        let pass = try await measure(contender: contender, spec: spec, load: load)
                        if isQuietTurn { quietPasses.append(pass) } else { loadedPasses.append(pass) }
                    } catch {
                        loadGenerator.stop()
                        await tearDown()
                        throw error
                    }

                    if !isQuietTurn {
                        loadGenerator.stop()
                        // Let clocks come back down before the next quiet pass,
                        // otherwise the boost leaks across the boundary.
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                    }
                    step += 1
                }
            }

            results.append(
                BenchContentionResult(
                    contender: contender,
                    quietPasses: quietPasses,
                    loadedPasses: loadedPasses,
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
        systemPrompt: String?,
        suppressThinking: Bool = true
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
            streamsAnswer: false,
            suppressThinking: suppressThinking
        )

        for contender in contenders {
            let load = try await bringUp(contender)
            try await warmUp()

            let collector = BenchSampleCollector()
            let started = Date()
            var totalTokens = 0
            // The live series is driven purely by text deltas, never by the
            // engine's token count. Mixing them made the series jump by the
            // difference between the two across a near-zero window, which
            // produced a first-minute median of 223,365 tok/s. The engine's
            // count is still what `totalTokens` reports — it is authoritative
            // for "how much work happened", just not for instantaneous rate.
            var deltaTotal = 0
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

                // Each prompt has its own prefill; re-anchor so the gap is not
                // charged to decode.
                collector.beginSegment(atTokens: deltaTotal)
                let produced = try await streamCountingTokens(
                    spec: baseSpec.withPrompt(prompt),
                    modelName: contender.displayName
                ) { deltaCount in
                    if let sample = collector.record(tokens: deltaTotal + deltaCount) {
                        self.onSample?(sample)
                    }
                }

                deltaTotal += produced.deltaCount
                totalTokens += produced.outputTokens
                promptsDone += 1
                collector.finalize(tokens: deltaTotal)
            }

            let elapsed = Date().timeIntervalSince(started)
            let samples = collector.samples
            results.append(
                BenchEnduranceResult(
                    contender: contender,
                    placement: load.placement,
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
        let placement: BenchPlacement
    }

    private func bringUp(_ contender: BenchContender) async throws -> LoadOutcome {
        // Unload first: Chat or a previous contender may still hold an LLM,
        // and two resident models would contend for memory bandwidth.
        try? await RunAnywhere.models.unload(category: .language)

        let wasWarm = Self.loadedThisSession.contains(contender.modelId)
        report(
            phase: wasWarm ? "Loading (repeat)" : "Loading (first this session)",
            contender: contender.displayName,
            detail: wasWarm
                ? "the compiled graph is already cached"
                : "may compile and specialize the graph, if the on-disk cache is empty",
            fraction: nil
        )

        let start = Date()
        let loaded: LoadedModel
        do {
            // No `accelerator:` here on purpose — see
            // BenchCatalog.acceleratorPolicyIsUnavailable. Passing it throws
            // `invalidConfiguration` on SDK 0.20.35, so placement is whatever
            // the engine chooses and the result is labelled from what it
            // reports rather than from what we would have liked.
            loaded = try await RunAnywhere.models.load(
                id: contender.modelId,
                options: LoadOptions(forceReload: true)
            )
        } catch {
            throw AcceleratorBenchError.loadFailed(model: contender.displayName, underlying: error)
        }
        let ms = Date().timeIntervalSince(start) * 1000
        let placement = BenchPlacement(
            requested: contender.requested,
            actual: BenchAccelerator(
                deviceKind: loaded.actualDevice.deviceKind,
                framework: loaded.actualBackend
            ),
            actualBackend: loaded.actualBackend,
            deviceName: loaded.actualDevice.deviceName,
            deviceKind: loaded.actualDevice.deviceKind,
            fallbackReason: loaded.fallbackReason
        )
        Self.loadedThisSession.insert(contender.modelId)
        let msText = String(format: "%.0f", ms)
        logger.info(
            """
            AcceleratorBench loaded \(contender.modelId, privacy: .public) \
            in \(msText, privacy: .public)ms warm=\(wasWarm, privacy: .public)
            """
        )
        return LoadOutcome(ms: ms, wasWarm: wasWarm, placement: placement)
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
        // The load generator, when running, burns CPU inside THIS process, and
        // getrusage(RUSAGE_SELF) counts every thread. Capture its own tally so
        // the generation is not charged for it: on a 6-core phone an unadjusted
        // reading showed an ANE inference "holding 4.36 cores" while the
        // accelerator was doing the arithmetic.
        let loadCpuAtStart = loadGenerator.consumedCpuSeconds
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
        let loadCpuBurned = max(0, loadGenerator.consumedCpuSeconds - loadCpuAtStart)
        let cpuSeconds = max(0, collector.totalCpuSeconds - loadCpuBurned)
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
            placement: load.placement,
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
                    systemPrompt: spec.systemPrompt,
                    reasoning: ReasoningOptions(mode: spec.suppressThinking ? .off : .on)
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
