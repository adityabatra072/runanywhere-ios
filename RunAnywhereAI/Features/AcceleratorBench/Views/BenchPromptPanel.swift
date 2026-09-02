//
//  BenchPromptPanel.swift
//  RunAnywhereAI
//
//  Mode 1: type a real prompt, read the answer, and read what it cost.
//
//  Deliberately not a "run benchmark" button. The numbers come from the same
//  generation that produced the words on screen, which is the only kind of
//  benchmark a viewer has any reason to believe.
//

import SwiftUI

struct BenchPromptPanel: View {
    @Bindable var viewModel: AcceleratorBenchViewModel

    var body: some View {
        Group {
            promptSection
            settingsSection
            if !viewModel.streamingAnswer.isEmpty && viewModel.isRunning {
                streamingSection
            }
            if viewModel.passResults.count > 1 {
                comparisonSection
                if viewModel.showsThroughputRanking {
                    throughputRankingSection
                }
            }
            ForEach(viewModel.passResults) { pass in
                PassResultSection(pass: pass, viewModel: viewModel)
            }
        }
    }

    // MARK: Comparison

    /// Rankings across contenders, shown only when more than one ran.
    ///
    /// Host cost is ranked unconditionally because it is the axis the
    /// accelerator choice actually decides. Throughput is behind a setting: at
    /// matched quantization the Neural Engine is not the fastest path on Apple
    /// silicon, so ranking on it turns the bench into a story about peak speed
    /// rather than about where the accelerator changes the outcome. Nothing is
    /// hidden either way — each contender's own throughput is on its own card.
    private var comparisonSection: some View {
        Section {
            ForEach(hostCostRanking) { pass in
                BenchVerdictRow(
                    claim: "\(pass.contender.accelerator.label) host cost",
                    value: pass.hostCpuMsPerToken.map { BenchFormat.decimal($0, 1) + " ms" }
                        ?? "—",
                    detail: "\(pass.contender.displayName) held "
                        + BenchFormat.decimal(pass.hostCoresHeld, 2)
                        + " of \(HostCostSampler.coreCount) cores while generating "
                        + "\(pass.outputTokens) tokens",
                    tint: pass.hostCoresHeld < 1.0 ? AppColors.success : AppColors.warning,
                    symbol: pass.hostCoresHeld < 1.0 ? "leaf.fill" : "flame.fill"
                )
            }
        } header: {
            Label("Host CPU per token · least first", systemImage: "bolt.badge.clock")
        } footer: {
            Text("Core-milliseconds of this process's own CPU per generated token. A path on an "
                + "accelerator spends host CPU only orchestrating; a path on the general-purpose "
                + "cores spends it doing the arithmetic.")
        }
    }

    /// Opt-in, from Bench settings.
    private var throughputRankingSection: some View {
        Section {
            ForEach(viewModel.passResults.sorted { $0.tokensPerSecond > $1.tokensPerSecond }) { pass in
                HStack {
                    BenchAcceleratorBadge(accelerator: pass.contender.accelerator)
                    Text(pass.contender.displayName)
                        .appType(.meta)
                        .lineLimit(1)
                    Spacer(minLength: AppSpacing.smallMedium)
                    Text(BenchFormat.decimal(pass.tokensPerSecond, 1) + " tok/s")
                        .appType(.monoMetric)
                }
            }
        } header: {
            Label("Throughput · fastest first", systemImage: "chart.bar")
        } footer: {
            Text("Peak decode rate is the one axis where the Neural Engine is not expected to "
                + "lead on Apple silicon: at matched quantization the GPU reads the same weights "
                + "with far more bandwidth. The case for the ANE is the host cost above, and what "
                + "the other two modes measure.")
        }
    }

    private var hostCostRanking: [BenchPassResult] {
        viewModel.passResults.sorted {
            ($0.hostCpuMsPerToken ?? .infinity) < ($1.hostCpuMsPerToken ?? .infinity)
        }
    }

    // MARK: Prompt

    private var promptSection: some View {
        Section {
            TextField(
                "Ask it something",
                text: $viewModel.prompt,
                prompt: Text("Ask it something real…"),
                axis: .vertical
            )
            .lineLimit(2...6)
            .appType(.body)
            .disabled(viewModel.isRunning)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppSpacing.smallMedium) {
                    ForEach(AcceleratorBenchViewModel.promptSuggestions, id: \.self) { suggestion in
                        Button {
                            viewModel.prompt = suggestion
                        } label: {
                            Text(suggestion)
                                .appType(.chip)
                                .lineLimit(1)
                                .padding(.horizontal, AppSpacing.mediumLarge)
                                .padding(.vertical, AppSpacing.small)
                                .background(Capsule().fill(AppColors.muted))
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.isRunning)
                    }
                }
                .padding(.vertical, AppSpacing.xxSmall)
            }
            .listRowInsets(
                EdgeInsets(top: 0, leading: AppSpacing.large, bottom: 0, trailing: AppSpacing.large)
            )
        } header: {
            Label("Prompt", systemImage: "text.cursor")
        }
    }

    // MARK: Settings

    private var settingsSection: some View {
        Section {
            Picker("Answer length", selection: $viewModel.maxTokens) {
                ForEach(viewModel.maxTokenOptions, id: \.self) { count in
                    Text("\(count) tokens").tag(count)
                }
            }
            .disabled(viewModel.isRunning)

            DisclosureGroup("System prompt") {
                TextField("System prompt", text: $viewModel.systemPrompt, axis: .vertical)
                    .lineLimit(2...5)
                    .appType(.secondary)
                    .disabled(viewModel.isRunning)
            }
        } header: {
            Label("Generation", systemImage: "slider.horizontal.3")
        } footer: {
            Text("Greedy decoding with a fixed seed, so a re-run is comparable rather than "
                + "merely similar.")
        }
    }

    // MARK: Streaming

    private var streamingSection: some View {
        Section {
            Text(viewModel.streamingAnswer)
                .appType(.body)
                .textSelection(.enabled)

            if let latest = viewModel.liveSamples.last {
                HStack(spacing: AppSpacing.large) {
                    LiveReadout(
                        label: "tok/s",
                        value: BenchFormat.decimal(latest.tokensPerSecond, 1)
                    )
                    LiveReadout(
                        label: "host cores",
                        value: BenchFormat.decimal(latest.hostCores, 2)
                    )
                    BenchThermalPill(state: latest.thermal)
                }
            }
        } header: {
            Label("Answering", systemImage: "ellipsis.bubble")
        }
    }
}

// MARK: - Live readout

private struct LiveReadout: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .appType(.monoMetric)
            Text(label)
                .appType(.caption)
                .foregroundStyle(AppColors.mutedForeground)
        }
    }
}

// MARK: - One finished pass

private struct PassResultSection: View {
    let pass: BenchPassResult
    let viewModel: AcceleratorBenchViewModel

    var body: some View {
        Section {
            BenchMetricGrid {
                BenchMetricTile(
                    title: "Throughput",
                    value: BenchFormat.decimal(pass.tokensPerSecond, 1),
                    unit: "tok/s",
                    footnote: "median of live windows "
                        + BenchFormat.decimal(pass.medianTokensPerSecond, 1),
                    tint: pass.contender.accelerator.tint,
                    isHeadline: true
                )

                if viewModel.showsTimeToFirstToken {
                    BenchMetricTile(
                        title: "First token",
                        value: BenchFormat.milliseconds(pass.ttftMs),
                        footnote: ttftFootnote,
                        tint: AppColors.foreground
                    )
                }

                if viewModel.showsHostCpu {
                    BenchMetricTile(
                        title: "Host CPU held",
                        value: BenchFormat.decimal(pass.hostCoresHeld, 2),
                        unit: "of \(HostCostSampler.coreCount) cores",
                        footnote: pass.hostCpuMsPerToken.map {
                            BenchFormat.decimal($0, 1) + " core-ms per token"
                        } ?? "this process's own CPU time",
                        tint: hostCpuTint
                    )
                }

                BenchMetricTile(
                    title: "Tokens",
                    value: "\(pass.outputTokens)",
                    unit: "out",
                    footnote: "\(pass.inputTokens) in · "
                        + BenchFormat.milliseconds(pass.wallMs) + " wall"
                )

                BenchMetricTile(
                    title: pass.wasWarmLoad ? "Load (warm)" : "Load (cold)",
                    value: BenchFormat.milliseconds(pass.loadMs),
                    footnote: pass.wasWarmLoad
                        ? "from the compiled-graph cache"
                        : "first load compiles and specializes the graph"
                )

                if viewModel.showsThermal {
                    BenchMetricTile(
                        title: "Peak thermal",
                        value: pass.peakThermal.benchLabel,
                        tint: pass.peakThermal.benchTint
                    )
                }
            }
            .listRowInsets(EdgeInsets(
                top: AppSpacing.smallMedium,
                leading: AppSpacing.mediumLarge,
                bottom: AppSpacing.smallMedium,
                trailing: AppSpacing.mediumLarge
            ))

            if pass.samples.count > 2 {
                BenchThroughputChart(
                    series: [
                        .init(
                            id: pass.id.uuidString,
                            label: pass.contender.accelerator.shortLabel,
                            tint: pass.contender.accelerator.tint,
                            samples: pass.samples
                        )
                    ]
                )
            }

            DisclosureGroup("Answer") {
                Text(pass.answer)
                    .appType(.body)
                    .textSelection(.enabled)
            }
        } header: {
            HStack {
                Text(pass.contender.displayName)
                Spacer()
                BenchAcceleratorBadge(accelerator: pass.contender.accelerator)
            }
        }
    }

    /// The honest explanation of a large TTFT, rather than a hidden tile.
    ///
    /// A depth-chunked bundle has no prefill graph, so prompt tokens traverse
    /// the whole chunk chain one at a time. That is a property of the bundle's
    /// topology, not of the hardware, and saying so is more useful than either
    /// hiding the number or letting it look like an ANE limitation.
    private var ttftFootnote: String? {
        guard let ttft = pass.ttftMs else { return "engine reported none" }
        if ttft > 1500 {
            return "depth-chunked bundle: no prefill graph, so prompt tokens go through the "
                + "chunk chain one at a time"
        }
        return nil
    }

    private var hostCpuTint: Color {
        // One core is the rough line between "orchestrating an accelerator"
        // and "doing the arithmetic on the CPU".
        pass.hostCoresHeld < 1.0 ? AppColors.success : AppColors.warning
    }
}
