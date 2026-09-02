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

                Text("This device reports \(HostCostSampler.coreCount) cores. "
                    + "\(CpuLoadGenerator.defaultThreadCount) threads leaves one for the app "
                    + "itself, which starves a CPU contender without freezing the UI.")
                    .appType(.caption)
                    .foregroundStyle(AppColors.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Label("Synthetic load", systemImage: "gauge.with.dots.needle.67percent")
        }
    }

    // MARK: Verdict

    /// The comparison stated as a claim, ranked by how little each path moved.
    private var verdictSection: some View {
        Section {
            ForEach(viewModel.contentionResults.sorted(by: Self.byLeastMovement)) { result in
                BenchVerdictRow(
                    claim: "\(result.contender.accelerator.label) under load",
                    value: BenchFormat.signedPercent(result.latencyDeltaPercent, 1),
                    detail: detail(for: result),
                    tint: tint(for: result),
                    symbol: symbol(for: result)
                )
            }
        } header: {
            Label("Per-token latency change", systemImage: "arrow.left.arrow.right")
        } footer: {
            Text("Near zero means the work is on silicon that the competing threads cannot "
                + "touch. A large positive number means it was queueing behind them for the "
                + "same cores.")
        }
    }

    private static func byLeastMovement(
        _ lhs: BenchContentionResult,
        _ rhs: BenchContentionResult
    ) -> Bool {
        abs(lhs.latencyDeltaPercent ?? .infinity) < abs(rhs.latencyDeltaPercent ?? .infinity)
    }

    private func detail(for result: BenchContentionResult) -> String {
        let quiet = BenchFormat.decimal(result.quiet.msPerToken, 2)
        let loaded = BenchFormat.decimal(result.loaded.msPerToken, 2)
        let retained = BenchFormat.decimal(result.throughputRetentionPercent, 0)
        return "\(result.contender.displayName) · \(quiet) → \(loaded) ms/token with "
            + "\(result.loadThreads) threads spinning · \(retained)% of throughput retained"
    }

    private func tint(for result: BenchContentionResult) -> Color {
        guard let delta = result.latencyDeltaPercent else { return AppColors.textTertiary }
        if abs(delta) < 5 { return AppColors.success }
        if abs(delta) < 25 { return AppColors.warning }
        return AppColors.danger
    }

    private func symbol(for result: BenchContentionResult) -> String {
        guard let delta = result.latencyDeltaPercent else { return "questionmark.circle" }
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
                    title: "Quiet",
                    value: BenchFormat.decimal(result.quiet.tokensPerSecond, 1),
                    unit: "tok/s",
                    footnote: BenchFormat.decimal(result.quiet.msPerToken, 2) + " ms/token",
                    tint: AppColors.foreground
                )
                BenchMetricTile(
                    title: "Under load",
                    value: BenchFormat.decimal(result.loaded.tokensPerSecond, 1),
                    unit: "tok/s",
                    footnote: BenchFormat.decimal(result.loaded.msPerToken, 2) + " ms/token",
                    tint: AppColors.foreground
                )
                BenchMetricTile(
                    title: "Host CPU, quiet",
                    value: BenchFormat.decimal(result.quiet.hostCoresHeld, 2),
                    unit: "cores",
                    tint: AppColors.foreground
                )
                BenchMetricTile(
                    title: "Host CPU, loaded",
                    value: BenchFormat.decimal(result.loaded.hostCoresHeld, 2),
                    unit: "cores",
                    footnote: "the load threads are not in this figure — it is this process only",
                    tint: AppColors.foreground
                )
            }
            .listRowInsets(EdgeInsets(
                top: AppSpacing.smallMedium,
                leading: AppSpacing.mediumLarge,
                bottom: AppSpacing.smallMedium,
                trailing: AppSpacing.mediumLarge
            ))

            if result.quiet.samples.count > 2 || result.loaded.samples.count > 2 {
                BenchThroughputChart(
                    series: [
                        .init(
                            id: "quiet-\(result.id)",
                            label: "quiet",
                            tint: result.contender.accelerator.tint,
                            samples: result.quiet.samples
                        ),
                        .init(
                            id: "loaded-\(result.id)",
                            label: "under load",
                            tint: AppColors.danger,
                            samples: result.loaded.samples
                        )
                    ]
                )
            }
        } header: {
            HStack {
                Text(result.contender.displayName)
                Spacer()
                BenchAcceleratorBadge(accelerator: result.contender.accelerator)
            }
        }
    }
}
