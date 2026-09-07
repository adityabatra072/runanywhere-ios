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

    // MARK: - 3. Repeat loads are labelled as such

    func test3_RepeatLoadIsLabelledAndMeasured() async throws {
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

        log("load: first \(f(first.loadMs, 0)) ms (\(first.wasWarmLoad ? "repeat" : "first")) → "
            + "second \(f(second.loadMs, 0)) ms (\(second.wasWarmLoad ? "repeat" : "first"))")

        // The label is process-wide, so by the time this test runs test2 has
        // already loaded this model and BOTH loads are repeats. That is the
        // correct answer — asserting "first is cold" here would be asserting a
        // per-instance counter that no longer exists.
        XCTAssertTrue(
            second.wasWarmLoad,
            "a load following an earlier load of the same model must be labelled a repeat"
        )
        XCTAssertGreaterThan(first.loadMs, 0)
        XCTAssertGreaterThan(second.loadMs, 0)
    }

    // MARK: - 4. Contention — the claim the bench exists for

    func test4_ContentionSeparatesTheAcceleratorFromTheCpu() async throws {
        try await ensureDownloaded(aneModelId)
        var contenders = [try await contender(id: aneModelId)]
        if let cpuModelId {
            try await ensureDownloaded(cpuModelId)
            // On Apple hardware this is a GPU (Metal) contender, whatever the
            // env var is called: llama.cpp offloads every layer, and
            // LoadOptions.accelerator cannot override it on SDK 0.20.35.
            contenders.append(try await contender(id: cpuModelId))
        }

        let runner = AcceleratorBenchRunner()
        let threads = CpuLoadGenerator.defaultThreadCount
        let results = try await runner.runContention(
            contenders: contenders,
            prompt: "List three reasons to run inference locally.",
            maxTokens: 96,
            systemPrompt: nil,
            loadThreads: threads,
            repetitions: 3
        )

        for result in results {
            let noiseNote = result.deltaExceedsNoise == false
                ? "  <-- WITHIN NOISE, not a measured change"
                : ""
            log("""
            contention — \(result.contender.displayName) [\(result.contender.accelerator.shortLabel)]
              \(result.repetitions) runs per condition, alternating order, medians
              quiet    \(f(result.quietTokensPerSecond ?? 0, 2)) tok/s  \
            (\(f(result.quietMsPerToken ?? 0, 3)) ms/token, spread \(f(result.quietSpreadPercent ?? 0, 1))%)
              loaded   \(f(result.loadedTokensPerSecond ?? 0, 2)) tok/s  \
            (\(f(result.loadedMsPerToken ?? 0, 3)) ms/token, spread \(f(result.loadedSpreadPercent ?? 0, 1))%)
              \(threads) competing threads on \(HostCostSampler.coreCount) cores
              host CPU loaded \(f(result.loadedHostCoresHeld ?? 0, 3)) cores (load generator excluded)
              latency delta   \(result.latencyDeltaPercent.map { f($0, 2) + "%" } ?? "—")\(noiseNote)
              retained        \(result.throughputRetentionPercent.map { f($0, 1) + "%" } ?? "—")
              artifact?       \(result.isPowerStateArtifact ? "YES — discard, this is frequency scaling" : "no")
              trustworthy?    \(result.isTrustworthy)
            """)

            XCTAssertEqual(result.repetitions, 3, "every condition must be measured three times")
            XCTAssertNotNil(
                result.latencyDeltaPercent,
                "both conditions produced tokens, so a delta must be computable"
            )

            // Contention cannot make work faster, so a retention over 100% is
            // an artifact. On a phone that is the EXPECTED outcome and not a
            // bug in the bench: an idle device sits in a low-power state and
            // the load threads boost the whole package, GPU clocks included.
            // Measured on an iPhone 15, llama.cpp on Metal retained 183.5% and
            // 294.6% across runs, reproducibly, with alternating pass order.
            //
            // So the requirement is not "no artifact" — it is that the result
            // KNOWS when it is an artifact, and refuses to present it as a
            // contention verdict.
            if let retention = result.throughputRetentionPercent, retention > 110 {
                XCTAssertTrue(
                    result.isPowerStateArtifact,
                    "\(f(retention, 1))% retention must be flagged as a power-state artifact, "
                    + "or the panel will publish an impossible number as a win"
                )
                XCTAssertFalse(result.isTrustworthy, "an artifact cannot be a trustworthy result")
            }
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
        return BenchCatalog.availableContenders(from: models)
    }

    /// One model now yields several contenders — a llama.cpp GGUF appears as
    /// both a GPU arm and a CPU arm — so the accelerator has to be named.
    private func contender(
        id: String,
        requesting requested: BenchAccelerator? = nil
    ) async throws -> BenchContender {
        let all = try await currentContenders()
        let matches = all.filter { $0.modelId == id }
        let found = requested.map { policy in matches.first { $0.requested == policy } }
            ?? matches.first
        return try XCTUnwrap(
            found,
            "\(id)\(requested.map { " on \($0.shortLabel)" } ?? "") is not an available contender"
        )
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

    /// Print AND append to a file in the host's documents directory.
    ///
    /// `print` is enough on a device, where xcodebuild pipes the test host's
    /// stdout through. On macOS it does not: the run passes, the numbers are
    /// gone, and the xcresult keeps no activities either. So every line also
    /// lands on disk, and `logPath` is emitted first so the file can be found.
    private func log(_ message: String) {
        print("[bench] \(message)")
        guard let url = Self.logURL else { return }
        let line = "[bench] \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static let logURL: URL? = {
        guard let dir = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first else { return nil }
        let url = dir.appendingPathComponent("accelerator-bench-report.txt")
        let header = "=== Accelerator Bench run \(Date()) ===\n"
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(header.utf8))
                try? handle.close()
            }
        } else {
            try? header.write(to: url, atomically: true, encoding: .utf8)
        }
        print("[bench] logPath \(url.path)")
        return url
    }()
}
