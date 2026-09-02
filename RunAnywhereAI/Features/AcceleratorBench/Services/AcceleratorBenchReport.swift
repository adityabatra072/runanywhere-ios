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
            lines.append("ran on \(pass.placement.actual.label)"
                + (pass.placement.deviceName.isEmpty ? "" : " (\(pass.placement.deviceName))")
                + " via \(pass.placement.actualBackend.consumerBackendBadgeLabel)"
                + " · requested \(pass.placement.requested.shortLabel)"
                + (pass.placement.divergedFromRequest ? "  [REQUEST NOT HONOURED]" : ""))
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
        var lines = ["## Contention — the same prompt with and without competing CPU load", ""]

        for result in results {
            lines.append("### \(result.contender.displayName) "
                + "(ran on \((result.placement?.actual ?? result.contender.accelerator).label))")
            lines.append("- \(result.repetitions) runs per condition, alternating order, "
                + "medians reported")
            lines.append("- quiet:  \(fmt(result.quietTokensPerSecond ?? 0, 1)) tok/s, "
                + "\(fmt(result.quietMsPerToken ?? 0, 2)) ms/token "
                + "(spread \(fmt(result.quietSpreadPercent ?? 0, 0))%)")
            lines.append("- loaded (\(result.loadThreads) threads spinning): "
                + "\(fmt(result.loadedTokensPerSecond ?? 0, 1)) tok/s, "
                + "\(fmt(result.loadedMsPerToken ?? 0, 2)) ms/token "
                + "(spread \(fmt(result.loadedSpreadPercent ?? 0, 0))%)")
            if result.isPowerStateArtifact {
                lines.append("- **DISCARD: measured "
                    + fmt(result.throughputRetentionPercent ?? 0, 0)
                    + "% of quiet throughput WITH cores removed.** Contention cannot make work "
                    + "faster; the two conditions ran at different SoC power states. This is "
                    + "frequency scaling, not contention.")
            } else if let delta = result.latencyDeltaPercent {
                if result.deltaExceedsNoise == false {
                    lines.append("- median per-token latency change: \(signed(delta, 1)) % — "
                        + "**WITHIN RUN-TO-RUN NOISE, not a measured change**")
                } else {
                    lines.append("- **median per-token latency change: \(signed(delta, 1)) %**")
                }
            }
            if let retention = result.throughputRetentionPercent {
                lines.append("- throughput retained: \(fmt(retention, 0)) %")
            }
            if let cores = result.loadedHostCoresHeld {
                lines.append("- host CPU under load: \(fmt(cores, 2)) cores "
                    + "(the load generator's own burn is excluded)")
            }
            lines.append("")
        }
        lines.append("Read the sign, not just the size. A path executing on the Neural Engine is")
        lines.append("separate silicon and should barely move; a path on the general-purpose cores")
        lines.append("competes for the cores the load threads hold. But a single pass per condition")
        lines.append("cannot show that: the quiet pass would run first on a down-clocked chip while")
        lines.append("the load itself boosts the package, an artifact large enough to make a CPU")
        lines.append("contender measure FASTER with cores taken away. Hence the repetitions, the")
        lines.append("alternating order, and the spread printed next to every median.")
        return lines
    }

    private static func enduranceSection(_ results: [BenchEnduranceResult]) -> [String] {
        guard !results.isEmpty else { return ["No endurance run recorded yet."] }
        var lines = ["## Endurance — independent prompts, back to back", ""]

        for result in results {
            lines.append("### \(result.contender.displayName) "
                + "(ran on \(result.placement.actual.label))")
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
