//
//  AcceleratorBenchViewModel.swift
//  RunAnywhereAI
//
//  State for the Accelerator Bench. Every knob the bench has is here and is
//  user-settable — which contenders run, how long, how hard, and which metrics
//  are shown — so shooting a different comparison is a settings change rather
//  than a code change.
//

import Foundation
import RunAnywhere
import SwiftUI
import os

@MainActor
@Observable
final class AcceleratorBenchViewModel {
    // MARK: - Mode

    var mode: BenchMode = .prompt

    // MARK: - Contenders

    /// Every downloaded LLM, whatever its engine.
    var available: [BenchContender] = []
    var selectedIds: Set<String> = []

    var selected: [BenchContender] {
        available.filter { selectedIds.contains($0.modelId) }
    }

    var acceleratorsPresent: Set<BenchAccelerator> {
        Set(available.map(\.accelerator))
    }

    // MARK: - Prompt inputs

    var prompt: String = ""
    /// Default system prompt, written to stop preamble.
    ///
    /// LFM2.5-2.6B opens with commentary about the request — "The user is
    /// asking for a concise explanation in two sentences about why on-device
    /// models are more private…" — before answering. `ReasoningOptions(mode:
    /// .off)` does NOT fix it: the model emits no thinking tags for the SDK to
    /// strip, it simply writes preamble as ordinary prose. Only the prompt can
    /// stop that, and on camera it is the difference between a model answering
    /// and a model narrating.
    ///
    /// Measured caveat: on the LFM2.5-2.6B ANE bundle this prompt did not help
    /// either, and the reason looks like the system prompt never arriving —
    /// growing it from ~6 tokens to ~35 left the reported `inputTokens`
    /// unchanged at 33. Not confirmed at the engine level, but strong enough
    /// that any shot showing answer TEXT should use the 230M or 350M, which
    /// answer cleanly. The 2.6B is still right for the contention shot, where
    /// no answer is on screen.
    var systemPrompt: String = "Answer the question directly. Do not restate the question, "
        + "describe what is being asked, or explain your approach. Begin with the answer itself."
    var maxTokens: Int = 200
    let maxTokenOptions = [64, 128, 200, 400, 800]

    /// Ready-made prompts, so a demo does not depend on typing well on camera.
    /// These are suggestions the user can ignore or replace.
    static let promptSuggestions = [
        "Explain why a neural accelerator can be slower than a GPU and still be the right choice.",
        "Draft a two-sentence release note for an on-device speech feature.",
        "Summarise the trade-off between 8-bit and fp16 weights in one paragraph.",
        "Write a haiku about running a model on a phone in airplane mode."
    ]

    // MARK: - Contention settings

    var loadThreads: Int = CpuLoadGenerator.defaultThreadCount
    var contentionMaxTokens: Int = 128

    /// How many times each condition is measured.
    ///
    /// Not a nicety. One pass each cannot measure contention on a phone: the
    /// quiet pass runs first on a down-clocked SoC and the load itself boosts
    /// the package, so the handicapped condition gets better hardware. Three
    /// alternating repetitions compared on medians is the floor for a number
    /// worth showing.
    var contentionRepetitions: Int = 3
    let contentionRepetitionOptions = [1, 3, 5]

    var loadThreadRange: ClosedRange<Double> {
        1...Double(CpuLoadGenerator.maximumThreadCount)
    }

    // MARK: - Endurance settings

    /// Minutes. 15 is the default because battery drain is only honest once the
    /// run has crossed several whole-percent steps of `UIDevice.batteryLevel`.
    var enduranceMinutes: Int = 15
    let enduranceMinuteOptions = [2, 5, 15, 30]
    var enduranceMaxTokens: Int = 128

    /// Independent prompts, cycled round-robin. Independent on purpose: a
    /// single growing context would measure ANE fp16 accumulation error
    /// deepening with the KV cache instead of sustained throughput.
    var endurancePrompts: [String] = [
        "Name three uses for on-device speech recognition.",
        "What is the difference between prefill and decode?",
        "Give one reason to quantize a model to 8 bits.",
        "Describe a smartphone camera pipeline in two sentences.",
        "Why does battery life matter more than peak speed on a phone?",
        "List two risks of sending user prompts to a server."
    ]
    var newEndurancePrompt: String = ""

    // MARK: - Display settings

    /// The ranked, side-by-side throughput comparison.
    ///
    /// Off by default, and that is a presentation choice with a measurement
    /// reason behind it: at matched quantization the ANE is not the fastest
    /// path on Apple silicon, and a raw tok/s ranking would make the bench a
    /// story about peak speed. The claims this bench is built to show —
    /// behaviour under contention, host cost, sustained throughput — are on by
    /// default. Turn this on to see the throughput ranking too.
    var showsThroughputRanking = false

    /// Time to first token. Meaningful for a bundle with a real prefill graph;
    /// on a depth-chunked bundle the prompt goes through the chunk chain one
    /// token at a time and this number is seconds, not milliseconds. Shown
    /// with that explanation rather than hidden.
    var showsTimeToFirstToken = true

    var showsHostCpu = true
    var showsThermal = true

    /// Ask the engine to suppress chain of thought. On by default.
    ///
    /// Where a model emits real thinking tags this keeps thought tokens out of
    /// the token total, so throughput does not partly measure how much the
    /// model deliberated. Measured caveat: it had **no effect** on
    /// LFM2.5-2.6B through NeuRT, which writes its preamble as plain prose
    /// with no tags to strip — that one needs the system prompt above.
    var suppressThinking = true

    // MARK: - Results

    var passResults: [BenchPassResult] = []
    var contentionResults: [BenchContentionResult] = []
    var enduranceResults: [BenchEnduranceResult] = []

    var streamingAnswer: String = ""
    var liveSamples: [BenchSample] = []
    var progress: BenchProgress = .idle
    var isRunning = false
    var errorMessage: String?

    /// Wall-clock start of the active run, for the elapsed readout.
    var runStartedAt: Date?

    // MARK: - Private

    private let runner = AcceleratorBenchRunner()
    private let logger = Logger(subsystem: "com.runanywhere.RunAnywhereAI", category: "AcceleratorBench")
    private var runTask: Task<Void, Never>?

    init() {
        runner.onPartialAnswer = { [weak self] text in
            self?.streamingAnswer = text
        }
        runner.onSample = { [weak self] sample in
            guard let self else { return }
            self.liveSamples.append(sample)
            // Bound the live series so a 30-minute run does not grow the chart
            // without limit. The full series still lives on the result.
            if self.liveSamples.count > 900 {
                self.liveSamples.removeFirst(self.liveSamples.count - 900)
            }
        }
        runner.onProgress = { [weak self] progress in
            self?.progress = progress
        }
    }

    // MARK: - Catalog

    func refresh() {
        Task { await reload() }
    }

    private func reload() async {
        await RunAnywhere.models.refresh()
        guard let models = try? await RunAnywhere.models.list() else {
            available = []
            return
        }
        available = BenchCatalog.availableContenders(from: models)

        let ids = Set(available.map(\.modelId))
        selectedIds = selectedIds.intersection(ids)
        if selectedIds.isEmpty {
            selectedIds = Self.defaultSelection(from: available, mode: mode)
        }
    }

    /// What a fresh screen benches before the user changes anything.
    ///
    /// `prompt` mode picks the single Neural Engine model, because that panel
    /// is a demonstration rather than a comparison. The comparison modes pick
    /// the ANE model plus one rival, since a contention or endurance result
    /// means nothing without something to contend against.
    private static func defaultSelection(
        from contenders: [BenchContender],
        mode: BenchMode
    ) -> Set<String> {
        let ane = contenders.filter { $0.accelerator == .ane }
        switch mode {
        case .prompt:
            if let first = ane.first { return [first.modelId] }
            return Set(contenders.prefix(1).map(\.modelId))
        case .contention, .endurance:
            var picked = Set(ane.prefix(1).map(\.modelId))
            // Prefer a CPU rival: it is the comparison the claim is about, and
            // the one whose behaviour under contention differs most.
            if let rival = contenders.first(where: { $0.accelerator == .cpu })
                ?? contenders.first(where: { $0.accelerator == .gpu }) {
                picked.insert(rival.modelId)
            }
            if picked.isEmpty { picked = Set(contenders.prefix(2).map(\.modelId)) }
            return picked
        }
    }

    func resetSelectionForCurrentMode() {
        selectedIds = Self.defaultSelection(from: available, mode: mode)
    }

    func toggle(_ contender: BenchContender) {
        if selectedIds.contains(contender.modelId) {
            selectedIds.remove(contender.modelId)
        } else {
            selectedIds.insert(contender.modelId)
        }
    }

    // MARK: - Endurance prompt editing

    func addEndurancePrompt() {
        let trimmed = newEndurancePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        endurancePrompts.append(trimmed)
        newEndurancePrompt = ""
    }

    func removeEndurancePrompts(at offsets: IndexSet) {
        endurancePrompts.remove(atOffsets: offsets)
    }

    // MARK: - Run

    var canRun: Bool {
        guard !isRunning, !selected.isEmpty else { return false }
        switch mode {
        case .prompt, .contention:
            return !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .endurance:
            return !endurancePrompts.isEmpty
        }
    }

    func run() {
        guard canRun else { return }
        isRunning = true
        errorMessage = nil
        streamingAnswer = ""
        liveSamples = []
        runStartedAt = Date()

        let contenders = selected
        let effectiveSystemPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let system = effectiveSystemPrompt.isEmpty ? nil : effectiveSystemPrompt

        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.execute(contenders: contenders, systemPrompt: system)
            } catch is CancellationError {
                self.runner.stopSyntheticLoad()
            } catch {
                self.runner.stopSyntheticLoad()
                self.errorMessage = error.localizedDescription
                self.logger.error("AcceleratorBench run failed: \(error, privacy: .public)")
            }
            self.isRunning = false
            self.progress = .idle
            self.runStartedAt = nil
        }
    }

    /// Dispatch to the active mode. Split out of `run()` so that function stays
    /// about lifecycle — resetting state, owning the task, clearing it — rather
    /// than also carrying three call signatures.
    private func execute(contenders: [BenchContender], systemPrompt: String?) async throws {
        switch mode {
        case .prompt:
            passResults = try await runner.runPromptPass(
                contenders: contenders,
                prompt: prompt,
                maxTokens: maxTokens,
                systemPrompt: systemPrompt,
                suppressThinking: suppressThinking
            )
        case .contention:
            contentionResults = try await runner.runContention(
                contenders: contenders,
                prompt: prompt,
                maxTokens: contentionMaxTokens,
                systemPrompt: systemPrompt,
                loadThreads: loadThreads,
                repetitions: contentionRepetitions,
                suppressThinking: suppressThinking
            )
        case .endurance:
            enduranceResults = try await runner.runEndurance(
                contenders: contenders,
                prompts: endurancePrompts,
                duration: TimeInterval(enduranceMinutes * 60),
                maxTokens: enduranceMaxTokens,
                systemPrompt: systemPrompt,
                suppressThinking: suppressThinking
            )
        }
    }

    func cancel() {
        runTask?.cancel()
        runner.stopSyntheticLoad()
        isRunning = false
        progress = .idle
        runStartedAt = nil
    }

    /// The results for the active mode, bundled for the formatter and the
    /// screen's "anything to show yet?" check.
    var resultSet: BenchResultSet {
        BenchResultSet(
            mode: mode,
            passes: passResults,
            contention: contentionResults,
            endurance: enduranceResults
        )
    }

    // MARK: - Report

    /// A plain-text summary of the last run, for pasting straight into a post.
    /// Includes the device and the caveats, because a number without its
    /// fingerprint is not a measurement.
    func report(deviceInfo: SystemDeviceInfo?) -> String {
        AcceleratorBenchReport.text(
            results: resultSet,
            deviceInfo: deviceInfo,
            coreCount: HostCostSampler.coreCount
        )
    }
}
