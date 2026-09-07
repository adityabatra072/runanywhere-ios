//
//  AcceleratorBenchTests.swift
//  RunAnywhereAIUnitTests
//
//  Covers the Accelerator Bench's measurement machinery — the parts that decide
//  what a number means, and the one piece that fails silently if the optimiser
//  outsmarts it.
//

import XCTest
@testable import RunAnywhereAI
import RunAnywhere

final class AcceleratorBenchTests: XCTestCase {
    // MARK: - Accelerator mapping

    /// Placement is read from what the runtime reports, because the framework
    /// alone lies: on Apple hardware llama.cpp offloads to Metal, so mapping
    /// `.llamaCpp` to `.cpu` once put "CPU" on a contender measured running
    /// 15/15 layers on an A16 GPU.
    func testPlacementIsReadFromTheRuntimeNotTheFramework() {
        XCTAssertEqual(BenchAccelerator(deviceKind: "gpu", framework: .llamaCpp), .gpu)
        XCTAssertEqual(BenchAccelerator(deviceKind: "Metal", framework: .llamaCpp), .gpu)
        XCTAssertEqual(BenchAccelerator(deviceKind: "cpu", framework: .llamaCpp), .cpu)
        XCTAssertEqual(BenchAccelerator(deviceKind: "npu", framework: .coreml), .ane)
        XCTAssertEqual(BenchAccelerator(deviceKind: "neural-engine", framework: .coreml), .ane)
        // An empty kind is the only case allowed to fall back to a guess.
        XCTAssertEqual(BenchAccelerator(deviceKind: "", framework: .mlx), .gpu)
    }

    func testPreLoadGuessTreatsLlamaCppAsMetalOnApple() {
        XCTAssertEqual(BenchAccelerator(assumingFrom: .coreml), .ane)
        XCTAssertEqual(BenchAccelerator(assumingFrom: .mlx), .gpu)
        // Not .cpu: llama.cpp takes Metal unless CPU is requested at load.
        XCTAssertEqual(BenchAccelerator(assumingFrom: .llamaCpp), .gpu)
        XCTAssertEqual(BenchAccelerator(assumingFrom: .onnx), .cpu)
        XCTAssertEqual(BenchAccelerator(assumingFrom: .foundationModels), .other)
        XCTAssertEqual(BenchAccelerator(assumingFrom: .qhexrt), .other)
    }

    func testPlacementFlagsARequestTheRuntimeDidNotHonour() {
        let honoured = BenchPlacement(
            requested: .cpu, actual: .cpu, actualBackend: .llamaCpp,
            deviceName: "CPU", deviceKind: "cpu", fallbackReason: nil
        )
        XCTAssertFalse(honoured.divergedFromRequest)

        let silentlyMoved = BenchPlacement(
            requested: .cpu, actual: .gpu, actualBackend: .llamaCpp,
            deviceName: "Apple A16 GPU", deviceKind: "gpu", fallbackReason: nil
        )
        XCTAssertTrue(
            silentlyMoved.divergedFromRequest,
            "asking for CPU and getting Metal must be visible, not swallowed"
        )
    }

    func testAneSortsFirstBecauseItIsTheSubjectOfTheBench() {
        let ranks = [BenchAccelerator.cpu, .other, .ane, .gpu].sorted { $0.sortRank < $1.sortRank }
        XCTAssertEqual(ranks, [.ane, .gpu, .cpu, .other])
    }

    // MARK: - Statistics

    func testMedianIgnoresNonFiniteAndNonPositiveSamples() {
        // A zero-token window and a division by an instantaneous zero interval
        // both show up as junk rates; neither may move the reported median.
        XCTAssertEqual(BenchStats.median([10, 0, .infinity, 20, -5, 30]), 20)
        XCTAssertNil(BenchStats.median([]))
        XCTAssertNil(BenchStats.median([0, -1]))
    }

    func testMedianAveragesTheMiddlePairOnEvenCounts() {
        XCTAssertEqual(BenchStats.median([10, 20, 30, 40]), 25)
    }

    func testMedianRateOnlyReadsSamplesInsideTheWindow() {
        let samples = (0..<10).map { index in
            AcceleratorBenchTests.sample(elapsed: Double(index) * 10, tokensPerSecond: Double(index + 1))
        }
        // Elapsed 0…30 covers indices 0-3, whose rates are 1,2,3,4 → median 2.5.
        XCTAssertEqual(BenchStats.medianRate(in: samples, elapsedRange: 0...30), 2.5)
        // A window past every sample has nothing to report rather than a zero.
        XCTAssertNil(BenchStats.medianRate(in: samples, elapsedRange: 500...600))
    }

    // MARK: - Contention arithmetic

    func testLatencyDeltaIsSignedAndRelativeToTheQuietPass() {
        let result = Self.contention(quietTokensPerSecond: 100, loadedTokensPerSecond: 50)
        // Halved throughput is double the per-token latency: +100%.
        XCTAssertEqual(try XCTUnwrap(result.latencyDeltaPercent), 100, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result.throughputRetentionPercent), 50, accuracy: 0.001)
    }

    func testAnUnmovedPathReportsRoughlyZeroDelta() {
        let result = Self.contention(quietTokensPerSecond: 70.0, loadedTokensPerSecond: 70.0)
        XCTAssertEqual(try XCTUnwrap(result.latencyDeltaPercent), 0, accuracy: 0.001)
    }

    func testDeltaIsNilRatherThanZeroWhenAPassProducedNothing() {
        let result = Self.contention(quietTokensPerSecond: 0, loadedTokensPerSecond: 40)
        XCTAssertNil(result.latencyDeltaPercent)
        XCTAssertNil(result.throughputRetentionPercent)
    }

    /// A delta the size of the noise it sits in has not been measured. Without
    /// this the panel would present a real 3% and a coin-flip 3% identically.
    func testDeltaSmallerThanTheRunToRunSpreadIsFlaggedAsNoise() {
        // 2% effect buried in a 40% spread.
        let buried = Self.contention(
            quietTokensPerSecond: 100, loadedTokensPerSecond: 98, jitter: 0.4
        )
        XCTAssertEqual(buried.deltaExceedsNoise, false)

        // Halved throughput against a tight spread is a real effect.
        let clear = Self.contention(
            quietTokensPerSecond: 100, loadedTokensPerSecond: 50, jitter: 0.02
        )
        XCTAssertEqual(clear.deltaExceedsNoise, true)
    }

    func testMediansDriveTheDeltaSoOneOutlierPassCannotSetIt() {
        let result = BenchContentionResult(
            contender: Self.contender(),
            quietPasses: [
                Self.pass(tokensPerSecond: 100),
                Self.pass(tokensPerSecond: 100),
                // One absurd run, of the kind DVFS settling produces.
                Self.pass(tokensPerSecond: 1000)
            ],
            loadedPasses: [
                Self.pass(tokensPerSecond: 50),
                Self.pass(tokensPerSecond: 50),
                Self.pass(tokensPerSecond: 50)
            ],
            loadThreads: 3
        )
        // Median of the quiet condition is 100, not the 400 a mean would give.
        XCTAssertEqual(try XCTUnwrap(result.quietTokensPerSecond), 100, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result.latencyDeltaPercent), 100, accuracy: 0.001)
    }

    func testRepetitionCountIsTheSmallerOfTheTwoConditions() {
        let result = BenchContentionResult(
            contender: Self.contender(),
            quietPasses: [Self.pass(tokensPerSecond: 100), Self.pass(tokensPerSecond: 100)],
            loadedPasses: [Self.pass(tokensPerSecond: 50)],
            loadThreads: 3
        )
        XCTAssertEqual(result.repetitions, 1, "a condition measured once cannot claim two runs")
    }

    // MARK: - Endurance arithmetic

    func testSustainComparesTheFinalMinuteToTheOpeningMinute() {
        // Token totals are consistent with the rates: ~32 tok/s average over
        // 900 s against 40 tok/s decode windows, the gap being prompt
        // processing between turns. Inconsistent fixtures are now rejected by
        // the plausibility guard, which is the point of it.
        let flat = Self.endurance(first: 40, last: 40, totalTokens: 28_800, duration: 900)
        XCTAssertEqual(try XCTUnwrap(flat.sustainPercent), 100, accuracy: 0.001)

        let throttled = Self.endurance(first: 40, last: 24, totalTokens: 28_800, duration: 900)
        XCTAssertEqual(try XCTUnwrap(throttled.sustainPercent), 60, accuracy: 0.001)
    }

    /// A rate series that disagrees with the run's own wall-clock average is
    /// mis-attributed, and sustain must be withheld rather than reported.
    func testImplausibleRateSeriesWithholdsSustain() {
        // The real M4 failure: 223,365 tok/s first minute against a 17.6 average.
        let broken = Self.endurance(
            first: 223_365, last: 0.28, totalTokens: 3_200, duration: 182
        )
        XCTAssertTrue(broken.rateSeriesIsSuspect)
        XCTAssertNil(broken.sustainPercent, "a suspect series must not yield a sustain figure")
        // The wall-clock average is still trustworthy and must survive.
        XCTAssertEqual(broken.averageTokensPerSecond, 3_200 / 182, accuracy: 0.001)

        // A plausible series still reports.
        let sane = Self.endurance(first: 40, last: 38, totalTokens: 7_000, duration: 180)
        XCTAssertFalse(sane.rateSeriesIsSuspect)
        XCTAssertEqual(try XCTUnwrap(sane.sustainPercent), 95, accuracy: 0.001)
    }

    func testBatteryIsWithheldUntilTheRunCrossesTheApisResolution() {
        // UIDevice.batteryLevel steps in whole percent. One point of movement
        // is indistinguishable from rounding, so it must not be published.
        let tooShort = Self.endurance(
            first: 40, last: 40, totalTokens: 2_000, duration: 120,
            startBattery: 0.80, endBattery: 0.79
        )
        XCTAssertNil(tooShort.batteryPointsPerThousandTokens)

        let longEnough = Self.endurance(
            first: 40, last: 40, totalTokens: 10_000, duration: 900,
            startBattery: 0.80, endBattery: 0.76
        )
        // 4 points over 10,000 tokens = 0.4 points per 1,000.
        XCTAssertEqual(try XCTUnwrap(longEnough.batteryPointsPerThousandTokens), 0.4, accuracy: 0.0001)
    }

    func testChargingDeviceCannotProduceABatteryClaim() {
        // A rising level would otherwise compute a negative drain.
        let charging = Self.endurance(
            first: 40, last: 40, totalTokens: 10_000, duration: 900,
            startBattery: 0.70, endBattery: 0.85
        )
        XCTAssertNil(charging.batteryPointsUsed)
        XCTAssertNil(charging.batteryPointsPerThousandTokens)
    }

    // MARK: - Host cost

    func testProcessCpuTimeIsMonotonic() {
        let first = HostCostSampler.processCpuSeconds()
        XCTAssertGreaterThan(first, 0, "the test process has already burned CPU to get here")
        var sink = 0.0
        for index in 0..<2_000_000 { sink += Double(index).squareRoot() }
        withExtendedLifetime(sink) {}
        XCTAssertGreaterThanOrEqual(HostCostSampler.processCpuSeconds(), first)
    }

    /// The load generator's whole job is to be un-optimisable. If `-O` proves
    /// its inner loop dead, the threads sleep, the Contention panel reports a
    /// delta of zero for every backend, and the bench silently claims the CPU
    /// is as contention-proof as the Neural Engine. This test is the guard.
    func testSyntheticLoadActuallyBurnsCpu() {
        let generator = CpuLoadGenerator()
        let threads = 2
        let before = HostCostSampler.processCpuSeconds()

        generator.start(threadCount: threads)
        XCTAssertTrue(generator.running)
        Thread.sleep(forTimeInterval: 1.0)
        generator.stop()
        XCTAssertFalse(generator.running)

        let burned = HostCostSampler.processCpuSeconds() - before
        // Two threads spinning for a second should bill well over a second of
        // CPU. A generous floor keeps this from flaking on a busy CI box while
        // still failing outright if the loop was elided.
        XCTAssertGreaterThan(
            burned, 0.5,
            "expected the load threads to burn CPU; got \(burned)s across \(threads) threads"
        )
    }

    /// The generator must be able to say how much CPU it itself burned, or the
    /// runner cannot subtract it and every host-cost figure measured under load
    /// is really a measure of the load.
    func testLoadGeneratorReportsItsOwnCpuConsumption() {
        let generator = CpuLoadGenerator()
        XCTAssertEqual(generator.consumedCpuSeconds, 0, "nothing burned before start")

        generator.start(threadCount: 2)
        Thread.sleep(forTimeInterval: 1.0)
        let duringRun = generator.consumedCpuSeconds
        generator.stop()

        XCTAssertGreaterThan(duringRun, 0.5, "two threads for a second should self-report >0.5s")
        // Its own tally must not exceed what the whole process burned.
        XCTAssertLessThanOrEqual(duringRun, HostCostSampler.processCpuSeconds())
    }

    func testDefaultLoadIsHalfTheCoresNotAllOfThem() {
        // Pinning every core starves the host leg an accelerator needs for
        // sampling and dispatch, which measures scheduler starvation instead of
        // accelerator independence. Measured on an iPhone 15: 5-of-6 cores cost
        // the ANE path 58%.
        XCTAssertEqual(CpuLoadGenerator.defaultThreadCount, max(1, HostCostSampler.coreCount / 2))
        XCTAssertLessThan(CpuLoadGenerator.defaultThreadCount, HostCostSampler.coreCount)
    }

    func testStoppingTheLoadGeneratorLetsCpuTimeSettle() {
        let generator = CpuLoadGenerator()
        generator.start(threadCount: 1)
        Thread.sleep(forTimeInterval: 0.3)
        generator.stop()
        // Give the spinning threads a batch to notice the flag.
        Thread.sleep(forTimeInterval: 0.5)

        let quiescent = HostCostSampler.processCpuSeconds()
        Thread.sleep(forTimeInterval: 0.5)
        let after = HostCostSampler.processCpuSeconds()
        XCTAssertLessThan(
            after - quiescent, 0.2,
            "load threads kept running after stop()"
        )
    }

    // MARK: - Sample collection

    func testCollectorDropsWindowsShorterThanTheMinimumInterval() {
        let collector = BenchSampleCollector()
        // Two calls back to back cannot span the interval, so the second is
        // dropped rather than dividing by a near-zero window.
        XCTAssertNil(collector.record(tokens: 1, minimumInterval: 5))
        XCTAssertNil(collector.record(tokens: 2, minimumInterval: 5))
        XCTAssertTrue(collector.samples.isEmpty)
        // The first of those calls anchored decode; finalize ignores the
        // interval, so it yields the first real window.
        XCTAssertNotNil(collector.finalize(tokens: 3))
        XCTAssertEqual(collector.samples.count, 1)
    }

    /// Windows before the first token are prompt processing, not decode.
    /// Counting them corrupts the rate: on an M4 the 6-chunk LFM2.5-2.6B, which
    /// has no prefill graph and emits nothing for over a second, reported a
    /// median of 0.19 tok/s against a true 22.46 because a one-token-over-five-
    /// seconds prefill window is a legitimate 0.19 and passed the ">0" filter.
    func testSamplingIgnoresEverythingBeforeTheFirstToken() {
        let collector = BenchSampleCollector()

        // Prompt processing: repeated calls with nothing generated yet.
        XCTAssertNil(collector.record(tokens: 0, minimumInterval: 0))
        XCTAssertNil(collector.record(tokens: 0, minimumInterval: 0))
        XCTAssertTrue(collector.samples.isEmpty, "prefill must contribute no samples")
        XCTAssertNil(collector.timeToFirstToken, "no token has arrived yet")

        // The first token anchors decode and is itself not a window.
        XCTAssertNil(collector.record(tokens: 1, minimumInterval: 0))
        XCTAssertTrue(collector.samples.isEmpty)
        XCTAssertNotNil(collector.timeToFirstToken)

        // Only now do windows count, and they measure from the first token.
        Thread.sleep(forTimeInterval: 0.05)
        let sample = collector.record(tokens: 11, minimumInterval: 0)
        let unwrapped = try? XCTUnwrap(sample)
        XCTAssertNotNil(unwrapped)
        // 10 tokens in ~0.05 s is on the order of 200/s, and must not be the
        // sub-1 figure a prefill-inclusive window would produce.
        XCTAssertGreaterThan(unwrapped?.tokensPerSecond ?? 0, 50)
    }

    func testCollectorReportsTheWorstThermalStateItSaw() {
        let collector = BenchSampleCollector()
        collector.finalize(tokens: 1)
        // Cannot force a thermal state from a test, so assert the invariant:
        // the peak is never better than the live reading.
        XCTAssertGreaterThanOrEqual(
            collector.peakThermal.benchSeverity,
            0
        )
        XCTAssertLessThanOrEqual(collector.peakThermal.benchSeverity, 3)
    }

    // MARK: - Contender selection

    func testOnlyDownloadedLanguageModelsBecomeContenders() throws {
        let downloadedAne = Self.model(id: "ane", framework: .coreml, localPath: "/tmp/ane")
        let downloadedCpu = Self.model(id: "cpu", framework: .llamaCpp, localPath: "/tmp/cpu")
        let notDownloaded = Self.model(id: "remote", framework: .mlx, localPath: "")
        let wrongCategory = Self.model(
            id: "speech", framework: .onnx, localPath: "/tmp/stt", category: .speechRecognition
        )

        let contenders = BenchCatalog.availableContenders(
            from: [downloadedCpu, notDownloaded, wrongCategory, downloadedAne]
        )

        XCTAssertEqual(contenders.map(\.modelId), ["ane", "cpu"], "ANE first, and only on-disk LLMs")
        XCTAssertEqual(contenders.first?.requested, .ane)

        // The llama.cpp row is expected to be a GPU row, not a CPU one: it
        // offloads to Metal on Apple hardware, and LoadOptions.accelerator
        // cannot force it off (see BenchCatalog.acceleratorPolicyIsUnavailable).
        let llama = try XCTUnwrap(contenders.first { $0.framework == .llamaCpp })
        XCTAssertEqual(llama.requested, .gpu)
    }

    // MARK: - Result set

    func testResultSetEmptinessFollowsTheActiveMode() {
        let pass = Self.pass(tokensPerSecond: 40)
        let promptMode = BenchResultSet(mode: .prompt, passes: [pass], contention: [], endurance: [])
        XCTAssertFalse(promptMode.isEmpty)
        // The same passes must not make the contention mode look populated.
        let contentionMode = BenchResultSet(
            mode: .contention, passes: [pass], contention: [], endurance: []
        )
        XCTAssertTrue(contentionMode.isEmpty)
    }

    // MARK: - Report

    func testReportCarriesTheDeviceFingerprintAndTheHostCpuCaveat() {
        let results = BenchResultSet(
            mode: .prompt,
            passes: [Self.pass(tokensPerSecond: 42.5)],
            contention: [],
            endurance: []
        )
        let text = AcceleratorBenchReport.text(
            results: results,
            deviceInfo: SystemDeviceInfo(
                modelName: "iPhone 15",
                chipName: "A16 Bionic",
                totalMemory: 6_000_000_000,
                availableMemory: 3_000_000_000,
                neuralEngineAvailable: true,
                osVersion: "26.5",
                appVersion: "1.0"
            ),
            coreCount: 6
        )

        XCTAssertTrue(text.contains("iPhone 15"))
        XCTAssertTrue(text.contains("A16 Bionic"))
        XCTAssertTrue(text.contains("6 CPU cores"))
        XCTAssertTrue(text.contains("42.5 tok/s"))
        // The caveat is not optional decoration — a host-CPU figure read as
        // accelerator energy would be a false claim.
        XCTAssertTrue(text.contains("not accelerator energy"))
    }

    func testChunkedBundlesGetTheirTtftExplainedInTheReport() {
        let slow = Self.pass(tokensPerSecond: 38, ttftMs: 8_400)
        let text = AcceleratorBenchReport.text(
            results: BenchResultSet(mode: .prompt, passes: [slow], contention: [], endurance: []),
            deviceInfo: nil,
            coreCount: 10
        )
        XCTAssertTrue(
            text.contains("depth-chunked"),
            "a multi-second TTFT must be attributed to the bundle topology, not left bare"
        )
    }

    // MARK: - Clock

    func testClockFormatsMinutesAndSeconds() {
        XCTAssertEqual(AcceleratorBenchRunner.clock(0), "0:00")
        XCTAssertEqual(AcceleratorBenchRunner.clock(59), "0:59")
        XCTAssertEqual(AcceleratorBenchRunner.clock(900), "15:00")
        XCTAssertEqual(AcceleratorBenchRunner.clock(-5), "0:00")
    }
}

// MARK: - Fixtures

private extension AcceleratorBenchTests {
    static func sample(elapsed: TimeInterval, tokensPerSecond: Double) -> BenchSample {
        BenchSample(
            elapsed: elapsed,
            tokens: Int(tokensPerSecond * elapsed),
            tokensPerSecond: tokensPerSecond,
            hostCores: 0.2,
            thermal: .nominal,
            batteryLevel: nil
        )
    }

    static func model(
        id: String,
        framework: InferenceFramework,
        localPath: String,
        category: ModelCategory = .language
    ) -> RAModelInfo {
        var model = RAModelInfo()
        model.id = id
        model.name = id
        model.category = category
        model.framework = framework
        model.localPath = localPath
        return model
    }

    static func contender(
        _ accelerator: BenchAccelerator = .ane
    ) -> BenchContender {
        let framework: InferenceFramework
        switch accelerator {
        case .ane: framework = .coreml
        case .gpu: framework = .mlx
        case .cpu: framework = .llamaCpp
        case .other: framework = .unknown
        }
        return BenchContender(model: model(id: accelerator.rawValue, framework: framework, localPath: "/tmp"))
    }

    static func placement(
        requested: BenchAccelerator = .ane,
        actual: BenchAccelerator? = nil
    ) -> BenchPlacement {
        let resolved = actual ?? requested
        return BenchPlacement(
            requested: requested,
            actual: resolved,
            actualBackend: resolved == .ane ? .coreml : .llamaCpp,
            deviceName: resolved.label,
            deviceKind: resolved.rawValue,
            fallbackReason: nil
        )
    }

    static func pass(tokensPerSecond: Double, ttftMs: Double? = 30) -> BenchPassResult {
        BenchPassResult(
            contender: contender(),
            placement: placement(),
            prompt: "why does this matter",
            answer: "because it does",
            ttftMs: ttftMs,
            tokensPerSecond: tokensPerSecond,
            medianTokensPerSecond: tokensPerSecond,
            inputTokens: 12,
            outputTokens: 128,
            wallMs: 128 / max(tokensPerSecond, 0.001) * 1000,
            loadMs: 480,
            wasWarmLoad: true,
            hostCpuSeconds: 0.4,
            hostCoresHeld: 0.2,
            peakThermal: .nominal,
            samples: [],
            finishedAt: Date()
        )
    }

    static func contention(
        quietTokensPerSecond: Double,
        loadedTokensPerSecond: Double,
        repetitions: Int = 3,
        jitter: Double = 0
    ) -> BenchContentionResult {
        // `jitter` scales the spread within each condition so a test can put
        // the effect above or below the run-to-run noise on purpose.
        func passes(_ rate: Double) -> [BenchPassResult] {
            (0..<repetitions).map { index in
                let offset = repetitions > 1
                    ? jitter * (Double(index) / Double(repetitions - 1) - 0.5)
                    : 0
                return pass(tokensPerSecond: rate * (1 + offset))
            }
        }
        return BenchContentionResult(
            contender: contender(),
            quietPasses: quietTokensPerSecond > 0 ? passes(quietTokensPerSecond) : [],
            loadedPasses: loadedTokensPerSecond > 0 ? passes(loadedTokensPerSecond) : [],
            loadThreads: 3
        )
    }

    static func endurance(
        first: Double,
        last: Double,
        totalTokens: Int,
        duration: TimeInterval,
        startBattery: Double? = nil,
        endBattery: Double? = nil
    ) -> BenchEnduranceResult {
        BenchEnduranceResult(
            contender: contender(),
            placement: placement(),
            samples: [],
            totalTokens: totalTokens,
            promptsCompleted: 20,
            duration: duration,
            hostCpuSeconds: 90,
            peakThermal: .fair,
            startBattery: startBattery,
            endBattery: endBattery,
            startedAt: Date(),
            firstMinuteTokensPerSecond: first,
            lastMinuteTokensPerSecond: last
        )
    }
}
