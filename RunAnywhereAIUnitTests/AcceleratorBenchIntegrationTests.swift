//
//  AcceleratorBenchIntegrationTests.swift
//  RunAnywhereAIUnitTests
//
//  Drives the Accelerator Bench against the real SDK, real engines and the real
//  Neural Engine on whatever machine runs it. It downloads models and takes
//  minutes, so it is opt-in:
//
//      RA_BENCH_INTEGRATION=1 xcodebuild test \
//        -only-testing:RunAnywhereAITests/AcceleratorBenchIntegrationTests …
//
//  Optional overrides:
//      RA_BENCH_ANE_MODEL   catalog id for the accelerator contender
//      RA_BENCH_CPU_MODEL   catalog id for the rival
//      RA_BENCH_ENDURANCE_SECONDS  shorten the endurance leg (default 60)
//
//  It asserts the invariants a demo depends on and prints every measurement, so
//  the run doubles as the QA record for a capture session.
//

import XCTest
@testable import RunAnywhereAI
import RunAnywhere
#if canImport(LlamaCPPRuntime)
import LlamaCPPRuntime
#endif
#if canImport(MLXRuntime)
import MLXRuntime
#endif
#if canImport(ONNXRuntime)
import ONNXRuntime
#endif
#if canImport(NeuRTRuntime)
import NeuRTRuntime
#endif

@MainActor
final class AcceleratorBenchIntegrationTests: XCTestCase {
    private static var didBootstrap = false

    private var isEnabled: Bool {
        ProcessInfo.processInfo.environment["RA_BENCH_INTEGRATION"] == "1"
    }

    private var aneModelId: String {
        ProcessInfo.processInfo.environment["RA_BENCH_ANE_MODEL"] ?? "lfm2.5-350m-ane"
    }

    private var cpuModelId: String? {
        ProcessInfo.processInfo.environment["RA_BENCH_CPU_MODEL"]
    }

    private var enduranceSeconds: TimeInterval {
        TimeInterval(ProcessInfo.processInfo.environment["RA_BENCH_ENDURANCE_SECONDS"] ?? "") ?? 60
    }

    // MARK: - Bootstrap

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(isEnabled, "set RA_BENCH_INTEGRATION=1 to run the on-device bench")
        guard !Self.didBootstrap else { return }

        // Engines must be registered before anything asks the SDK to load a
        // model, exactly as the app does it — otherwise the first load fails
        // with "no provider could handle the request".
        #if canImport(LlamaCPPRuntime)
        LlamaCPP.register(priority: 100)
        #endif
        let mlxRegistered = MLX.register(priority: 100)
        #if canImport(ONNXRuntime)
        ONNX.register(priority: 100)
        #endif
        #if canImport(NeuRTRuntime)
        NeuRT.register(priority: 100)
        #endif

        try RunAnywhere.initialize(environment: .development)
        await ModelCatalogBootstrap.registerAll(mlxRegistered: mlxRegistered)
        Self.didBootstrap = true

        let info = DeviceInfoFactory.current
        log("device: \(info.deviceModel) · \(info.chipName) · \(HostCostSampler.coreCount) cores "
            + "· ANE \(info.hasNpu_p ? "present" : "absent")")
    }

    // MARK: - 1. The catalog surfaces what the bench needs

    func test1_ContendersAppearOnceDownloaded() async throws {
        try await ensureDownloaded(aneModelId)

        let contenders = try await currentContenders()
        log("contenders: " + contenders.map { "\($0.modelId) [\($0.accelerator.shortLabel)]" }
            .joined(separator: ", "))

        let ane = contenders.first { $0.modelId == aneModelId }
        let unwrapped = try XCTUnwrap(ane, "\(aneModelId) did not appear as a contender after download")
        XCTAssertEqual(
            unwrapped.accelerator, .ane,
            "a coreml/NeuRT model must be classified as the Neural Engine, not as CPU"
        )
    }

    // MARK: - 2. A real prompt produces real numbers

    func test2_PromptPassMeasuresARealGeneration() async throws {
        try await ensureDownloaded(aneModelId)
        let contender = try await contender(id: aneModelId)
        let runner = AcceleratorBenchRunner()

        let results = try await runner.runPromptPass(
            contenders: [contender],
            prompt: "In two sentences, why does an on-device model beat a cloud one for privacy?",
            maxTokens: 96,
            systemPrompt: "You are a concise assistant."
        )

        let pass = try XCTUnwrap(results.first)
        log("""
        prompt pass — \(pass.contender.displayName) [\(pass.contender.accelerator.shortLabel)]
          throughput      \(f(pass.tokensPerSecond, 2)) tok/s   (median window \(f(pass.medianTokensPerSecond, 2)))
          first token     \(pass.ttftMs.map { f($0, 1) + " ms" } ?? "not reported")
          tokens          \(pass.outputTokens) out / \(pass.inputTokens) in
          wall            \(f(pass.wallMs, 0)) ms
          host CPU        \(f(pass.hostCpuSeconds, 3)) s = \(f(pass.hostCoresHeld, 3)) cores held
          host per token  \(pass.hostCpuMsPerToken.map { f($0, 2) + " core-ms" } ?? "—")
          load            \(f(pass.loadMs, 0)) ms (\(pass.wasWarmLoad ? "warm" : "cold"))
          peak thermal    \(pass.peakThermal.benchLabel)
          answer          \(pass.answer.prefix(160))
        """)

        XCTAssertGreaterThan(pass.outputTokens, 0, "the engine produced no tokens")
        XCTAssertFalse(pass.answer.isEmpty, "no text came back, so nothing was really generated")
        XCTAssertGreaterThan(pass.tokensPerSecond, 0)
        XCTAssertGreaterThan(pass.wallMs, 0)
        // Host CPU must be a real, non-zero reading — a zero would mean the
        // rusage differencing is broken and every host-cost claim is void.
        XCTAssertGreaterThan(pass.hostCpuSeconds, 0, "no host CPU recorded; the sampler is not working")
    }

    // MARK: - 3. Warm loads beat cold ones

    func test3_SecondLoadIsWarmAndFaster() async throws {
        try await ensureDownloaded(aneModelId)
        let contender = try await contender(id: aneModelId)
        let runner = AcceleratorBenchRunner()
        let prompt = "Say hello."

        let firstRun = try await runner.runPromptPass(
            contenders: [contender], prompt: prompt, maxTokens: 16, systemPrompt: nil
        )
        let first = try XCTUnwrap(firstRun.first)
        let secondRun = try await runner.runPromptPass(
            contenders: [contender], prompt: prompt, maxTokens: 16, systemPrompt: nil
        )
        let second = try XCTUnwrap(secondRun.first)

        log("load: first \(f(first.loadMs, 0)) ms (\(first.wasWarmLoad ? "warm" : "cold")) → "
            + "second \(f(second.loadMs, 0)) ms (\(second.wasWarmLoad ? "warm" : "cold"))")

        XCTAssertFalse(first.wasWarmLoad, "the first load of a session must be labelled cold")
        XCTAssertTrue(second.wasWarmLoad, "the second load must be labelled warm")
    }

    // MARK: - 4. Contention — the claim the bench exists for

    func test4_ContentionSeparatesTheAcceleratorFromTheCpu() async throws {
        try await ensureDownloaded(aneModelId)
        var contenders = [try await contender(id: aneModelId)]
        if let cpuModelId {
            try await ensureDownloaded(cpuModelId)
            contenders.append(try await contender(id: cpuModelId))
        }

        let runner = AcceleratorBenchRunner()
        let threads = CpuLoadGenerator.defaultThreadCount
        let results = try await runner.runContention(
            contenders: contenders,
            prompt: "List three reasons to run inference locally.",
            maxTokens: 96,
            systemPrompt: nil,
            loadThreads: threads
        )

        for result in results {
            log("""
            contention — \(result.contender.displayName) [\(result.contender.accelerator.shortLabel)]
              quiet    \(f(result.quiet.tokensPerSecond, 2)) tok/s  \
            (\(f(result.quiet.msPerToken ?? 0, 3)) ms/token, \(f(result.quiet.hostCoresHeld, 2)) cores)
              loaded   \(f(result.loaded.tokensPerSecond, 2)) tok/s  \
            (\(f(result.loaded.msPerToken ?? 0, 3)) ms/token, \(f(result.loaded.hostCoresHeld, 2)) cores)
              with \(threads) competing threads on \(HostCostSampler.coreCount) cores
              latency delta   \(result.latencyDeltaPercent.map { f($0, 2) + "%" } ?? "—")
              retained        \(result.throughputRetentionPercent.map { f($0, 1) + "%" } ?? "—")
            """)

            XCTAssertGreaterThan(result.quiet.outputTokens, 0)
            XCTAssertGreaterThan(result.loaded.outputTokens, 0)
            XCTAssertNotNil(
                result.latencyDeltaPercent,
                "both passes produced tokens, so a delta must be computable"
            )
        }

        // The load generator must actually have cost something. If the loaded
        // pass held no more host CPU than the quiet one on the CPU contender,
        // the contention leg proved nothing.
        if let cpuResult = results.first(where: { $0.contender.accelerator == .cpu }),
           let delta = cpuResult.latencyDeltaPercent {
            log("CPU contender moved \(f(delta, 2))% under load")
        }
    }

    // MARK: - 5. Endurance — sustained throughput and thermals

    func test5_EnduranceHoldsAndReportsSustain() async throws {
        try await ensureDownloaded(aneModelId)
        let contender = try await contender(id: aneModelId)
        let runner = AcceleratorBenchRunner()

        let results = try await runner.runEndurance(
            contenders: [contender],
            prompts: [
                "Name three uses for on-device speech recognition.",
                "What is the difference between prefill and decode?",
                "Give one reason to quantize a model to 8 bits."
            ],
            duration: enduranceSeconds,
            maxTokens: 64,
            systemPrompt: nil
        )

        let result = try XCTUnwrap(results.first)
        log("""
        endurance — \(result.contender.displayName) [\(result.contender.accelerator.shortLabel)]
          ran             \(AcceleratorBenchRunner.clock(result.duration)) \
        (\(result.promptsCompleted) prompts, \(result.totalTokens) tokens)
          average         \(f(result.averageTokensPerSecond, 2)) tok/s
          first minute    \(result.firstMinuteTokensPerSecond.map { f($0, 2) } ?? "—") tok/s
          final minute    \(result.lastMinuteTokensPerSecond.map { f($0, 2) } ?? "—") tok/s
          sustain         \(result.sustainPercent.map { f($0, 1) + "%" } ?? "needs a longer run")
          host CPU        \(f(result.hostCpuSeconds, 2)) s = \(f(result.hostCoresHeld, 3)) cores held
          peak thermal    \(result.peakThermal.benchLabel)
          battery         \(result.batteryPointsPerThousandTokens.map { f($0, 3) + "% per 1k tokens" }
            ?? (HostCostSampler.batteryUnavailableReason ?? "below the API's resolution"))
          samples         \(result.samples.count)
        """)

        XCTAssertGreaterThan(result.promptsCompleted, 0, "the endurance loop completed no prompts")
        XCTAssertGreaterThan(result.totalTokens, 0)
        XCTAssertGreaterThan(result.samples.count, 0, "no samples collected over the run")
        XCTAssertGreaterThanOrEqual(
            result.duration, enduranceSeconds * 0.9,
            "the loop exited early"
        )
    }

    // MARK: - 6. The report is pasteable and carries its caveats

    func test6_ReportIsCompleteForEveryMode() async throws {
        try await ensureDownloaded(aneModelId)
        let contender = try await contender(id: aneModelId)
        let runner = AcceleratorBenchRunner()

        let passes = try await runner.runPromptPass(
            contenders: [contender], prompt: "One sentence on edge AI.", maxTokens: 48, systemPrompt: nil
        )
        let text = AcceleratorBenchReport.text(
            results: BenchResultSet(mode: .prompt, passes: passes, contention: [], endurance: []),
            deviceInfo: DeviceInfoService.shared.deviceInfo,
            coreCount: HostCostSampler.coreCount
        )
        log("---- report ----\n\(text)\n----------------")

        XCTAssertTrue(text.contains("Accelerator Bench"))
        XCTAssertTrue(text.contains("tok/s"))
        XCTAssertTrue(text.contains("not accelerator energy"), "the host-CPU caveat must survive")
    }

    // MARK: - Helpers

    private func currentContenders() async throws -> [BenchContender] {
        await RunAnywhere.models.refresh()
        let models = try await RunAnywhere.models.list()
        return AcceleratorBenchRunner.availableContenders(from: models)
    }

    private func contender(id: String) async throws -> BenchContender {
        let all = try await currentContenders()
        let found = all.first { $0.modelId == id }
        return try XCTUnwrap(found, "\(id) is not an available contender")
    }

    /// Download `id` unless it is already on disk. Streams progress to the log
    /// so a multi-gigabyte pull does not look like a hang.
    private func ensureDownloaded(_ id: String) async throws {
        if try await currentContenders().contains(where: { $0.modelId == id }) { return }

        log("downloading \(id) …")
        let events = try await RunAnywhere.models.download(id: id)
        var lastLoggedPercent = -10.0
        for try await event in events {
            switch event {
            case .progress(let snapshot):
                guard let reported = snapshot.percent else { break }
                let percent = Double(reported)
                if percent - lastLoggedPercent >= 10 {
                    lastLoggedPercent = percent
                    log("  \(id) \(f(percent, 0))%")
                }
            case .completed:
                log("  \(id) downloaded")
            case .failed(_, _, let error):
                XCTFail("download of \(id) failed: \(error)")
                return
            default:
                break
            }
        }
        await RunAnywhere.models.refresh()
    }

    private func f(_ value: Double, _ places: Int) -> String {
        guard value.isFinite else { return "—" }
        return String(format: "%.\(places)f", value)
    }

    private func log(_ message: String) {
        print("[bench] \(message)")
    }
}
