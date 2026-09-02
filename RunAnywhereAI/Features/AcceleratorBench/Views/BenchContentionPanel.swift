//
//  BenchContentionPanel.swift
//  RunAnywhereAI
//
//  Mode 2: the same prompt on a quiet machine, then again with the CPU
//  saturated.
//
//  This is the panel the bench exists for. `MLComputePlan` will happily report
//  that a graph was planned onto the Neural Engine; it says nothing about
//  whether the work is really executing there. Changing the machine's CPU load
//  and re-timing the identical artifact does say so, and it separates the two
//  hypotheses a latency ratio cannot.
//

import SwiftUI

struct BenchContentionPanel: View {
    @Bindable var viewModel: AcceleratorBenchViewModel

    var body: some View {
        Group {
            promptSection
            loadSection
            if !viewModel.contentionResults.isEmpty {
                verdictSection
                ForEach(viewModel.contentionResults) { result in
                    ContentionResultSection(result: result)
                }
            }
        }
    }

    // MARK: Prompt

    private var promptSection: some View {
        Section {
            TextField(
                "Prompt",
                text: $viewModel.prompt,
                prompt: Text("One prompt, run twice…"),
                axis: .vertical
            )
            .lineLimit(2...5)
            .appType(.body)
            .disabled(viewModel.isRunning)

            Picker("Answer length", selection: $viewModel.contentionMaxTokens) {
                ForEach(viewModel.maxTokenOptions, id: \.self) { count in
                    Text("\(count) tokens").tag(count)
                }
            }
            .disabled(viewModel.isRunning)
        } header: {
            Label("Prompt", systemImage: "text.cursor")
        } footer: {
            Text("The quiet pass always runs first, on a machine this bench has not already "
                + "heated up. Same prompt, same seed, same token budget in both passes.")
        }
    }

    // MARK: Load

    private var loadSection: some View {
        Section {
            VStack(alignment: .leading, spacing: AppSpacing.small) {
                HStack {
                    Text("Competing threads")
                        .appType(.body)
                    Spacer()
                    Text("\(viewModel.loadThreads)")
                        .appType(.monoMetric)
                }
                Slider(
                    value: Binding(
                        get: { Double(viewModel.loadThreads) },
                        set: { viewModel.loadThreads = Int($0.rounded()) }
                    ),
                    in: viewModel.loadThreadRange,
                    step: 1
                )
                .disabled(viewModel.isRunning)

                Text("This device reports \(HostCostSampler.coreCount) cores. The default of "
                    + "\(CpuLoadGenerator.defaultThreadCount) is half of them — \"the app is "
                    + "busy\", not \"the machine is wedged\". An accelerator still needs the "
                    + "host to sample and dispatch between calls, so pinning every core measures "
                    + "scheduler starvation rather than accelerator independence. Raise it for a "
                    + "deliberate worst case; the result always states the count.")
                    .appType(.caption)
                    .foregroundStyle(AppColors.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker("Repetitions", selection: $viewModel.contentionRepetitions) {
                ForEach(viewModel.contentionRepetitionOptions, id: \.self) { count in
                    Text(count == 1 ? "1 (not advised)" : "\(count)").tag(count)
                }
            }
            .disabled(viewModel.isRunning)

            Text("Each condition is measured this many times, in alternating order, and compared "
                + "on medians. One pass each is not enough: the quiet pass would run first on a "
                + "down-clocked chip while the load itself boosts the package, so the handicapped "
                + "condition gets better hardware. That artifact is big enough to make a CPU "
                + "contender look faster with cores taken away.")
                .appType(.caption)
                .foregroundStyle(AppColors.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Label("Synthetic load", systemImage: "gauge.with.dots.needle.67percent")
        }
    }

    // MARK: Verdict

    /// The comparison stated as a claim, ranked by how little each path moved.
    private var verdictSection: some View {
        Section {
            ForEach(viewModel.contentionResults.sorted(by: Self.byLeastMovement)) { result in
                if result.isPowerStateArtifact {
                    BenchVerdictRow(
                        claim: "not a contention measurement",
                        value: BenchFormat.decimal(result.throughputRetentionPercent, 0) + "%",
                        detail: artifactDetail(for: result),
                        tint: AppColors.danger,
                        symbol: "exclamationmark.octagon.fill"
                    )
                } else {
                    BenchVerdictRow(
                        claim: "\((result.placement?.actual ?? result.contender.accelerator).label) under load",
                        value: BenchFormat.signedPercent(result.latencyDeltaPercent, 1),
                        detail: detail(for: result),
                        tint: tint(for: result),
                        symbol: symbol(for: result)
                    )
                }
            }
        } header: {
            Label("Per-token latency change", systemImage: "arrow.left.arrow.right")
        } footer: {
            Text("Near zero means the work is on silicon that the competing threads cannot "
                + "touch. A large positive number means it was queueing behind them for the "
                + "same cores. A result over 100% retention is not a contention measurement at "
                + "all and is reported as such: on a phone an idle device is a low-power state, "
                + "and the load itself boosts the whole package, so whichever engine is measured "
                + "first on a quiet device is penalised. This panel is most trustworthy on a Mac "
                + "with cores to spare.")
        }
    }

    private static func byLeastMovement(
        _ lhs: BenchContentionResult,
        _ rhs: BenchContentionResult
    ) -> Bool {
        abs(lhs.latencyDeltaPercent ?? .infinity) < abs(rhs.latencyDeltaPercent ?? .infinity)
    }

    /// Explains the impossible number rather than printing it as a win.
    private func artifactDetail(for result: BenchContentionResult) -> String {
        "\(result.contender.displayName) came out FASTER with \(result.loadThreads) of "
            + "\(HostCostSampler.coreCount) cores taken away, which contention cannot do. The two "
            + "conditions ran at different SoC power states: an idle device sits clocked down, and "
            + "the load threads drag the package up, raising GPU and memory clocks too. This "
            + "measures frequency scaling, not contention — discard it."
    }

    private func detail(for result: BenchContentionResult) -> String {
        let quiet = BenchFormat.decimal(result.quietMsPerToken, 2)
        let loaded = BenchFormat.decimal(result.loadedMsPerToken, 2)
        let retained = BenchFormat.decimal(result.throughputRetentionPercent, 0)
        var text = "\(result.contender.displayName) · median \(quiet) → \(loaded) ms/token "
            + "with \(result.loadThreads) of \(HostCostSampler.coreCount) cores spinning · "
            + "\(retained)% of throughput retained · \(result.repetitions) runs each"
        // A delta smaller than the run-to-run spread has not been measured, and
        // saying so is the difference between a result and a coin flip.
        if result.deltaExceedsNoise == false {
            let noise = BenchFormat.decimal(
                max(result.quietSpreadPercent ?? 0, result.loadedSpreadPercent ?? 0), 0
            )
            text += " — WITHIN NOISE (run-to-run spread \(noise)%), treat as no measured change"
        }
        return text
    }

    private func tint(for result: BenchContentionResult) -> Color {
        guard let delta = result.latencyDeltaPercent else { return AppColors.textTertiary }
        if result.deltaExceedsNoise == false { return AppColors.textTertiary }
        if abs(delta) < 5 { return AppColors.success }
        if abs(delta) < 25 { return AppColors.warning }
        return AppColors.danger
    }

    private func symbol(for result: BenchContentionResult) -> String {
        guard let delta = result.latencyDeltaPercent else { return "questionmark.circle" }
        if result.deltaExceedsNoise == false { return "questionmark.circle.fill" }
        if abs(delta) < 5 { return "equal.circle.fill" }
        return delta > 0 ? "arrow.up.right.circle.fill" : "arrow.down.right.circle.fill"
    }
}

// MARK: - One contender's two passes

private struct ContentionResultSection: View {
    let result: BenchContentionResult

    var body: some View {
        Section {
            BenchMetricGrid {
                BenchMetricTile(
                    title: "Quiet (median)",
                    value: BenchFormat.decimal(result.quietTokensPerSecond, 1),
                    unit: "tok/s",
                    footnote: BenchFormat.decimal(result.quietMsPerToken, 2) + " ms/token · spread "
                        + BenchFormat.decimal(result.quietSpreadPercent, 0) + "%",
                    tint: AppColors.foreground
                )
                BenchMetricTile(
                    title: "Under load (median)",
                    value: BenchFormat.decimal(result.loadedTokensPerSecond, 1),
                    unit: "tok/s",
                    footnote: BenchFormat.decimal(result.loadedMsPerToken, 2) + " ms/token · spread "
                        + BenchFormat.decimal(result.loadedSpreadPercent, 0) + "%",
                    tint: AppColors.foreground
                )
                BenchMetricTile(
                    title: "Host CPU, quiet",
                    value: BenchFormat.decimal(result.quietHostCoresHeld, 2),
                    unit: "cores",
                    tint: AppColors.foreground
                )
                BenchMetricTile(
                    title: "Host CPU, loaded",
                    value: BenchFormat.decimal(result.loadedHostCoresHeld, 2),
                    unit: "cores",
                    footnote: "the load threads' own CPU is subtracted, so this is the "
                        + "generation's cost, not the synthetic load's",
                    tint: AppColors.foreground
                )
                BenchMetricTile(
                    title: "Runs",
                    value: "\(result.repetitions)",
                    unit: "each condition",
                    footnote: "alternating order, compared on medians"
                )
            }
            .listRowInsets(EdgeInsets(
                top: AppSpacing.smallMedium,
                leading: AppSpacing.mediumLarge,
                bottom: AppSpacing.smallMedium,
                trailing: AppSpacing.mediumLarge
            ))

            if let quiet = result.quiet, let loaded = result.loaded,
               quiet.samples.count > 2 || loaded.samples.count > 2 {
                BenchThroughputChart(
                    series: [
                        .init(
                            id: "quiet-\(result.id)",
                            label: "quiet",
                            tint: (result.placement?.actual ?? result.contender.accelerator).tint,
                            samples: quiet.samples
                        ),
                        .init(
                            id: "loaded-\(result.id)",
                            label: "under load",
                            tint: AppColors.danger,
                            samples: loaded.samples
                        )
                    ]
                )
            }
        } header: {
            HStack {
                Text(result.contender.displayName)
                Spacer()
                if let placement = result.placement {
                    BenchPlacementBadge(placement: placement)
                } else {
                    BenchAcceleratorBadge(accelerator: result.contender.accelerator)
                }
            }
        }
    }
}
