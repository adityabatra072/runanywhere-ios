//
//  AcceleratorBenchReport.swift
//  RunAnywhereAI
//
//  Turns a run into pasteable text.
//
//  Every block carries the device, the chip, the engine and the settings that
//  produced it, plus the caveat that applies to that particular metric. A
//  number without its fingerprint is not a measurement, and the caveats are
//  the difference between a benchmark and a brag.
//

import Foundation

enum AcceleratorBenchReport {
    static func text(
        results: BenchResultSet,
        deviceInfo: SystemDeviceInfo?,
        coreCount: Int
    ) -> String {
        var lines: [String] = []
        lines.append("RunAnywhere — Accelerator Bench")
        lines.append(header(deviceInfo: deviceInfo, coreCount: coreCount))
        lines.append("")

        switch results.mode {
        case .prompt:
            lines.append(contentsOf: promptSection(results.passes))
        case .contention:
            lines.append(contentsOf: contentionSection(results.contention))
        case .endurance:
            lines.append(contentsOf: enduranceSection(results.endurance))
        }

        lines.append("")
        lines.append("Measured in-app on this device. Host CPU is this process's own user+system")
        lines.append("time (getrusage RUSAGE_SELF) — it is not accelerator energy.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Header

    private static func header(deviceInfo: SystemDeviceInfo?, coreCount: Int) -> String {
        var parts: [String] = []
        if let info = deviceInfo {
            parts.append(info.modelName)
            parts.append(info.chipName)
            parts.append("\(coreCount) CPU cores")
            parts.append("OS \(info.osVersion)")
            parts.append(info.neuralEngineAvailable ? "ANE present" : "no ANE reported")
        } else {
            parts.append("\(coreCount) CPU cores")
        }
        parts.append(Self.timestamp.string(from: Date()))
        return parts.joined(separator: " · ")
    }

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    // MARK: - Sections

    private static func promptSection(_ passes: [BenchPassResult]) -> [String] {
        guard !passes.isEmpty else { return ["No prompt run recorded yet."] }
        var lines = ["## Prompt", "\"\(passes[0].prompt)\"", ""]

        for pass in passes {
            lines.append("### \(pass.contender.displayName)")
            lines.append("engine \(pass.contender.accelerator.engineLabel) · "
                + "runs on \(pass.contender.accelerator.label)")
            lines.append("- \(fmt(pass.tokensPerSecond, 1)) tok/s "
                + "(median of live windows \(fmt(pass.medianTokensPerSecond, 1)))")
            if let ttft = pass.ttftMs {
                lines.append("- time to first token \(fmt(ttft, 0)) ms"
                    + (ttft > 1500 ? "  [depth-chunked bundle: no prefill graph]" : ""))
            }
            lines.append("- \(pass.outputTokens) tokens out, \(pass.inputTokens) in, "
                + "\(fmt(pass.wallMs, 0)) ms wall")
            lines.append("- host CPU \(fmt(pass.hostCoresHeld, 2)) cores held"
                + (pass.hostCpuMsPerToken.map { ", \(fmt($0, 1)) core-ms/token" } ?? ""))
            lines.append("- model load \(fmt(pass.loadMs, 0)) ms "
                + "(\(pass.wasWarmLoad ? "warm, from the compiled-graph cache" : "cold, first load"))")
            lines.append("- peak thermal state \(pass.peakThermal.benchLabel)")
            lines.append("")
        }
        return lines
    }

    private static func contentionSection(_ results: [BenchContentionResult]) -> [String] {
        guard !results.isEmpty else { return ["No contention run recorded yet."] }
        var lines = ["## Contention — the same prompt, quiet then under load", ""]

        for result in results {
            lines.append("### \(result.contender.displayName) "
                + "(\(result.contender.accelerator.label))")
            lines.append("- quiet:  \(fmt(result.quiet.tokensPerSecond, 1)) tok/s, "
                + "\(fmt(result.quiet.msPerToken ?? 0, 2)) ms/token")
            lines.append("- loaded (\(result.loadThreads) threads spinning): "
                + "\(fmt(result.loaded.tokensPerSecond, 1)) tok/s, "
                + "\(fmt(result.loaded.msPerToken ?? 0, 2)) ms/token")
            if let delta = result.latencyDeltaPercent {
                lines.append("- **per-token latency change: \(signed(delta, 1)) %**")
            }
            if let retention = result.throughputRetentionPercent {
                lines.append("- throughput retained: \(fmt(retention, 0)) %")
            }
            lines.append("")
        }
        lines.append("A path executing on the Neural Engine is separate silicon and should barely")
        lines.append("move. A path on the general-purpose cores competes for the cores the load")
        lines.append("threads are holding.")
        return lines
    }

    private static func enduranceSection(_ results: [BenchEnduranceResult]) -> [String] {
        guard !results.isEmpty else { return ["No endurance run recorded yet."] }
        var lines = ["## Endurance — independent prompts, back to back", ""]

        for result in results {
            lines.append("### \(result.contender.displayName) "
                + "(\(result.contender.accelerator.label))")
            lines.append("- ran \(AcceleratorBenchRunner.clock(result.duration)), "
                + "\(result.promptsCompleted) prompts, \(result.totalTokens) tokens")
            lines.append("- average \(fmt(result.averageTokensPerSecond, 1)) tok/s "
                + "including prompt processing between turns")
            if let first = result.firstMinuteTokensPerSecond {
                lines.append("- first minute \(fmt(first, 1)) tok/s")
            }
            if let last = result.lastMinuteTokensPerSecond {
                lines.append("- final minute \(fmt(last, 1)) tok/s")
            }
            if let sustain = result.sustainPercent {
                lines.append("- **sustained \(fmt(sustain, 0)) % of the opening minute**")
            }
            lines.append("- host CPU \(fmt(result.hostCoresHeld, 2)) cores held for the whole run")
            lines.append("- peak thermal state \(result.peakThermal.benchLabel)")
            if let perThousand = result.batteryPointsPerThousandTokens,
               let used = result.batteryPointsUsed {
                lines.append("- **battery \(fmt(perThousand, 2)) points per 1,000 tokens** "
                    + "(\(fmt(used, 0)) points over the run)")
            } else if let reason = HostCostSampler.batteryUnavailableReason {
                lines.append("- battery drain not measured: \(reason)")
            } else {
                lines.append("- battery drain not reported: the run was too short to cross "
                    + "\(Int(BenchEnduranceResult.minimumBatteryPoints)) whole percent, which is "
                    + "this API's resolution")
            }
            lines.append("")
        }
        lines.append("Prompts are independent rather than one growing conversation: ANE fp16 does")
        lines.append("not accumulate in fp32, so a single long context would measure that drift")
        lines.append("instead of sustained throughput.")
        return lines
    }

    // MARK: - Formatting

    private static func fmt(_ value: Double, _ places: Int) -> String {
        guard value.isFinite else { return "—" }
        return String(format: "%.\(places)f", value)
    }

    private static func signed(_ value: Double, _ places: Int) -> String {
        guard value.isFinite else { return "—" }
        return (value >= 0 ? "+" : "") + String(format: "%.\(places)f", value)
    }
}
