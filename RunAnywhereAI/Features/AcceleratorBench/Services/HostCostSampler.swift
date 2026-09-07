//
//  HostCostSampler.swift
//  RunAnywhereAI
//
//  Reads what a generation costs the HOST, as opposed to what it costs the
//  accelerator, plus the two platform signals that only show up over a long
//  run: thermal pressure and battery.
//
//  Why host CPU and not joules: joules-per-token needs `powermetrics`, which
//  needs root, which an app cannot have. Host CPU time needs nothing and is
//  the number that actually decides whether the app stays responsive while it
//  infers. State it for what it is — this process's own CPU — and it is an
//  honest, reproducible measurement rather than a proxy dressed up as energy.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Point-in-time host cost readings. Cheap enough to call on every token.
enum HostCostSampler {
    /// User + system CPU seconds this process has consumed since launch,
    /// summed across every thread (`RUSAGE_SELF`).
    ///
    /// Take two readings and difference them; the absolute value includes app
    /// startup and is meaningless on its own.
    static func processCpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }

    static func thermalState() -> ProcessInfo.ThermalState {
        ProcessInfo.processInfo.thermalState
    }

    static var coreCount: Int {
        ProcessInfo.processInfo.activeProcessorCount
    }

    /// Battery charge as 0…1, or nil where there is nothing meaningful to read.
    ///
    /// iOS only, and only while the device is on battery: a charging phone
    /// would report a level that rises during the run, which would make
    /// "battery points per 1,000 tokens" a lie. A plugged-in device returns
    /// nil so the caller hides the metric instead of reporting nonsense.
    static func batteryLevel() -> Double? {
        #if canImport(UIKit) && !os(macOS)
        let device = UIDevice.current
        guard device.isBatteryMonitoringEnabled else { return nil }
        guard device.batteryState == .unplugged else { return nil }
        let level = device.batteryLevel
        guard level >= 0 else { return nil }
        return Double(level)
        #else
        return nil
        #endif
    }

    /// Turn battery monitoring on. Idempotent, and a no-op off iOS.
    static func startBatteryMonitoring() {
        #if canImport(UIKit) && !os(macOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        #endif
    }

    /// Why the battery metric is unavailable, for the UI to explain itself.
    static var batteryUnavailableReason: String? {
        #if canImport(UIKit) && !os(macOS)
        switch UIDevice.current.batteryState {
        case .charging, .full:
            return "Unplug the device to measure battery drain."
        case .unknown:
            return "Battery level is not readable on this device."
        case .unplugged:
            return nil
        @unknown default:
            return nil
        }
        #else
        return "Battery drain is measured on iPhone and iPad only."
        #endif
    }
}

// MARK: - Accumulating sampler

/// Collects `BenchSample`s over one run, differencing the counters for you.
///
/// Not thread-safe by design: one run drives one sampler from one task.
final class BenchSampleCollector {
    private let startWall: Date
    private let startCpu: Double
    private var lastWall: Date
    private var lastCpu: Double
    private var lastTokens: Int
    private var worstThermal: ProcessInfo.ThermalState
    /// When the first token arrived, i.e. when decode actually began.
    ///
    /// Windows before this point are prompt processing, not decode, and
    /// including them corrupts the rate. A depth-chunked bundle has no prefill
    /// graph, so it pushes prompt tokens through the whole chunk chain one at a
    /// time and emits nothing for over a second: measured on an M4 with the
    /// 6-chunk LFM2.5-2.6B, that made the reported median 0.19 tok/s against a
    /// true 22.46. One token over five seconds is a real 0.19 — it just is not
    /// decode, and it survives a naive "greater than zero" filter.
    private var decodeStart: Date?

    private(set) var samples: [BenchSample] = []
    let startBattery: Double?

    init() {
        let now = Date()
        let cpu = HostCostSampler.processCpuSeconds()
        self.startWall = now
        self.startCpu = cpu
        self.lastWall = now
        self.lastCpu = cpu
        self.lastTokens = 0
        self.worstThermal = HostCostSampler.thermalState()
        self.startBattery = HostCostSampler.batteryLevel()
    }

    var elapsed: TimeInterval { Date().timeIntervalSince(startWall) }

    /// Total host CPU seconds burned since `init`.
    var totalCpuSeconds: Double { max(0, HostCostSampler.processCpuSeconds() - startCpu) }

    var peakThermal: ProcessInfo.ThermalState { worstThermal }

    /// Record a reading. `tokens` is the cumulative token count for the run.
    ///
    /// Returns nil when the window since the previous sample is too short to
    /// divide by — sampling faster than the clock resolves produces garbage
    /// rates, so those calls are dropped rather than smoothed.
    @discardableResult
    func record(tokens: Int, minimumInterval: TimeInterval = 0.25) -> BenchSample? {
        let now = Date()

        // Nothing has been generated yet: still in prompt processing. Keep the
        // counters moving forward so the first decode window is not credited
        // with the prefill wait, and emit no sample.
        guard tokens > 0 else {
            lastWall = now
            lastCpu = HostCostSampler.processCpuSeconds()
            lastTokens = tokens
            return nil
        }
        if decodeStart == nil {
            // First token. Anchor decode here rather than at request start.
            decodeStart = now
            lastWall = now
            lastCpu = HostCostSampler.processCpuSeconds()
            lastTokens = tokens
            return nil
        }

        let window = now.timeIntervalSince(lastWall)
        guard window >= minimumInterval else { return nil }

        let cpu = HostCostSampler.processCpuSeconds()
        let thermal = HostCostSampler.thermalState()
        if thermal.benchSeverity > worstThermal.benchSeverity {
            worstThermal = thermal
        }

        let sample = BenchSample(
            elapsed: now.timeIntervalSince(startWall),
            tokens: tokens,
            tokensPerSecond: Double(tokens - lastTokens) / window,
            hostCores: max(0, cpu - lastCpu) / window,
            thermal: thermal,
            batteryLevel: HostCostSampler.batteryLevel()
        )

        lastWall = now
        lastCpu = cpu
        lastTokens = tokens
        samples.append(sample)
        return sample
    }

    /// Force a final reading regardless of the sampling window, so a short run
    /// still produces at least one point.
    ///
    /// Returns nil when nothing was ever generated, or when the only token
    /// arrived at the instant decode was anchored — there is no window to
    /// divide by in either case.
    @discardableResult
    func finalize(tokens: Int) -> BenchSample? {
        record(tokens: tokens, minimumInterval: 0)
    }

    /// Seconds spent in prompt processing before the first token, as this
    /// collector saw it. Nil when nothing was generated.
    var timeToFirstToken: TimeInterval? {
        decodeStart.map { $0.timeIntervalSince(startWall) }
    }

    /// Begin a new generation inside the same run, re-anchoring decode.
    ///
    /// A run that cycles many prompts has one prefill per prompt, not one for
    /// the run. Without re-anchoring, the window spanning each gap is credited
    /// to decode and the series alternates between absurdly high and absurdly
    /// low rates — an endurance leg on an M4 reported a first-minute median of
    /// 223,365 tok/s and a final minute of 0.28.
    ///
    /// `tokens` is the cumulative count so far, so the next window measures
    /// only what the new generation adds.
    func beginSegment(atTokens tokens: Int) {
        decodeStart = nil
        lastWall = Date()
        lastCpu = HostCostSampler.processCpuSeconds()
        lastTokens = tokens
    }
}

// MARK: - Statistics

enum BenchStats {
    /// Median, which is what the bench reports for rates. A mean would let one
    /// stalled window — a download finishing, the OS deciding to index
    /// something — move a number the viewer reads as steady-state.
    static func median(_ values: [Double]) -> Double? {
        let sorted = values.filter { $0.isFinite && $0 > 0 }.sorted()
        guard !sorted.isEmpty else { return nil }
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    /// Median rate over the samples whose elapsed time falls in `range`.
    static func medianRate(
        in samples: [BenchSample],
        elapsedRange range: ClosedRange<TimeInterval>
    ) -> Double? {
        median(samples.filter { range.contains($0.elapsed) }.map(\.tokensPerSecond))
    }
}
