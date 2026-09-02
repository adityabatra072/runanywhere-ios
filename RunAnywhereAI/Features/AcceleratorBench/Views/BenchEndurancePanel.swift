//
//  BenchEndurancePanel.swift
//  RunAnywhereAI
//
//  Mode 3: many independent prompts, back to back, for as long as you set.
//
//  Two things only a long run can show. Whether throughput holds — a CPU or
//  GPU path warms the package until the scheduler starts clocking it down,
//  where a low-power accelerator has far less to shed. And battery, which is
//  the claim the desktop energy measurements could never make: they needed
//  `powermetrics` and root, and they were explicit that a desktop GPU's
//  bandwidth headroom makes its ratio meaningless on a phone.
//
//  `UIDevice.batteryLevel` needs no entitlement and reports whole percent, so
//  a long enough run measures on the phone what the lab could not.
//

import SwiftUI

struct BenchEndurancePanel: View {
    @Bindable var viewModel: AcceleratorBenchViewModel

    var body: some View {
        Group {
            durationSection
            promptPoolSection
            if viewModel.isRunning {
                liveSection
            }
            ForEach(viewModel.enduranceResults) { result in
                EnduranceResultSection(result: result)
            }
        }
    }

    // MARK: Duration

    private var durationSection: some View {
        Section {
            Picker("Duration", selection: $viewModel.enduranceMinutes) {
                ForEach(viewModel.enduranceMinuteOptions, id: \.self) { minutes in
                    Text("\(minutes) min").tag(minutes)
                }
            }
            .pickerStyle(.segmented)
            .disabled(viewModel.isRunning)

            Picker("Answer length", selection: $viewModel.enduranceMaxTokens) {
                ForEach(viewModel.maxTokenOptions, id: \.self) { count in
                    Text("\(count) tokens").tag(count)
                }
            }
            .disabled(viewModel.isRunning)

            if let reason = HostCostSampler.batteryUnavailableReason {
                Label(reason, systemImage: "battery.25")
                    .appType(.meta)
                    .foregroundStyle(AppColors.warningText)
            } else if viewModel.enduranceMinutes < 15 {
                Label(
                    "Battery is reported in whole percent, so runs under about 15 minutes "
                    + "usually cannot cross enough steps to report drain honestly.",
                    systemImage: "info.circle"
                )
                .appType(.meta)
                .foregroundStyle(AppColors.mutedForeground)
            }
        } header: {
            Label("Run length", systemImage: "timer")
        } footer: {
            Text("Each selected contender runs the full duration in turn.")
        }
    }

    // MARK: Prompt pool

    private var promptPoolSection: some View {
        Section {
            ForEach(Array(viewModel.endurancePrompts.enumerated()), id: \.offset) { item in
                Text(item.element)
                    .appType(.secondary)
            }
            .onDelete { offsets in
                viewModel.removeEndurancePrompts(at: offsets)
            }

            HStack {
                TextField("Add a prompt", text: $viewModel.newEndurancePrompt)
                    .appType(.secondary)
                    .onSubmit { viewModel.addEndurancePrompt() }
                Button("Add") { viewModel.addEndurancePrompt() }
                    .disabled(
                        viewModel.newEndurancePrompt
                            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
            }
            .disabled(viewModel.isRunning)
        } header: {
            Label("Prompt pool · cycled round-robin", systemImage: "list.bullet")
        } footer: {
            Text("Independent prompts, not one growing conversation. ANE fp16 does not "
                + "accumulate in fp32, so next-token agreement with the fp32 reference drifts as "
                + "the KV cache deepens — a single long context would measure that drift instead "
                + "of sustained throughput.")
        }
    }

    // MARK: Live

    private var liveSection: some View {
        Section {
            if viewModel.liveSamples.count > 2 {
                BenchThroughputChart(
                    series: [
                        .init(
                            id: "live",
                            label: "live",
                            tint: AppColors.brand,
                            samples: viewModel.liveSamples
                        )
                    ],
                    height: 180
                )
            }

            if let latest = viewModel.liveSamples.last {
                BenchMetricGrid(minimumTileWidth: 120) {
                    BenchMetricTile(
                        title: "Now",
                        value: BenchFormat.decimal(latest.tokensPerSecond, 1),
                        unit: "tok/s"
                    )
                    BenchMetricTile(
                        title: "Tokens",
                        value: "\(latest.tokens)"
                    )
                    BenchMetricTile(
                        title: "Host cores",
                        value: BenchFormat.decimal(latest.hostCores, 2)
                    )
                    BenchMetricTile(
                        title: "Thermal",
                        value: latest.thermal.benchLabel,
                        tint: latest.thermal.benchTint
                    )
                    if let battery = latest.batteryLevel {
                        BenchMetricTile(
                            title: "Battery",
                            value: BenchFormat.decimal(battery * 100, 0),
                            unit: "%"
                        )
                    }
                }
                .listRowInsets(EdgeInsets(
                    top: AppSpacing.smallMedium,
                    leading: AppSpacing.mediumLarge,
                    bottom: AppSpacing.smallMedium,
                    trailing: AppSpacing.mediumLarge
                ))
            }
        } header: {
            Label("In flight", systemImage: "waveform.path.ecg")
        }
    }
}

// MARK: - One finished endurance run

private struct EnduranceResultSection: View {
    let result: BenchEnduranceResult

    var body: some View {
        Section {
            if result.sustainPercent != nil || result.batteryPointsPerThousandTokens != nil {
                verdictRows
            }

            BenchMetricGrid {
                BenchMetricTile(
                    title: "Sustained",
                    value: BenchFormat.decimal(result.sustainPercent, 0),
                    unit: "% of minute one",
                    footnote: sustainFootnote,
                    tint: sustainTint,
                    isHeadline: true
                )
                BenchMetricTile(
                    title: "Average",
                    value: BenchFormat.decimal(result.averageTokensPerSecond, 1),
                    unit: "tok/s",
                    footnote: "across the whole run, prompt processing between turns included"
                )
                BenchMetricTile(
                    title: "Total work",
                    value: "\(result.totalTokens)",
                    unit: "tokens",
                    footnote: "\(result.promptsCompleted) prompts in "
                        + AcceleratorBenchRunner.clock(result.duration)
                )
                BenchMetricTile(
                    title: "Host CPU held",
                    value: BenchFormat.decimal(result.hostCoresHeld, 2),
                    unit: "of \(HostCostSampler.coreCount) cores",
                    footnote: "for the entire run",
                    tint: result.hostCoresHeld < 1.0 ? AppColors.success : AppColors.warning
                )
                BenchMetricTile(
                    title: "Peak thermal",
                    value: result.peakThermal.benchLabel,
                    tint: result.peakThermal.benchTint
                )
                if let perThousand = result.batteryPointsPerThousandTokens {
                    BenchMetricTile(
                        title: "Battery",
                        value: BenchFormat.decimal(perThousand, 2),
                        unit: "% per 1k tokens",
                        footnote: BenchFormat.decimal(result.batteryPointsUsed, 0)
                            + " points over the run",
                        tint: AppColors.brand
                    )
                } else {
                    BenchMetricTile(
                        title: "Battery",
                        value: "—",
                        footnote: batteryFallbackNote
                    )
                }
            }
            .listRowInsets(EdgeInsets(
                top: AppSpacing.smallMedium,
                leading: AppSpacing.mediumLarge,
                bottom: AppSpacing.smallMedium,
                trailing: AppSpacing.mediumLarge
            ))

            if result.samples.count > 2 {
                BenchThroughputChart(
                    series: [
                        .init(
                            id: result.id.uuidString,
                            label: result.contender.accelerator.shortLabel,
                            tint: result.contender.accelerator.tint,
                            samples: result.samples
                        )
                    ],
                    height: 180
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

    private var verdictRows: some View {
        VStack(spacing: AppSpacing.smallMedium) {
            if let sustain = result.sustainPercent {
                BenchVerdictRow(
                    claim: sustain >= 95 ? "throughput held flat" : "throughput fell off",
                    value: BenchFormat.decimal(sustain, 0) + "%",
                    detail: "final minute "
                        + BenchFormat.decimal(result.lastMinuteTokensPerSecond, 1)
                        + " tok/s against an opening minute of "
                        + BenchFormat.decimal(result.firstMinuteTokensPerSecond, 1)
                        + " tok/s, peak thermal state \(result.peakThermal.benchLabel)",
                    tint: sustainTint,
                    symbol: sustain >= 95 ? "equal.circle.fill" : "arrow.down.right.circle.fill"
                )
            }
            if let perThousand = result.batteryPointsPerThousandTokens {
                BenchVerdictRow(
                    claim: "battery per 1,000 tokens",
                    value: BenchFormat.decimal(perThousand, 2) + "%",
                    detail: "measured on this device over "
                        + AcceleratorBenchRunner.clock(result.duration)
                        + " and \(result.totalTokens) tokens, on battery power, "
                        + "from UIDevice.batteryLevel",
                    tint: AppColors.brand,
                    symbol: "battery.100percent.bolt"
                )
            }
        }
    }

    private var sustainFootnote: String {
        guard let sustain = result.sustainPercent else {
            return "needs at least two minutes of samples to compare"
        }
        return sustain >= 95
            ? "flat: no measurable throttling over this run"
            : "the final minute is slower than the first"
    }

    private var sustainTint: Color {
        guard let sustain = result.sustainPercent else { return AppColors.textTertiary }
        if sustain >= 95 { return AppColors.success }
        if sustain >= 85 { return AppColors.warning }
        return AppColors.danger
    }

    private var batteryFallbackNote: String {
        if let reason = HostCostSampler.batteryUnavailableReason { return reason }
        if let used = result.batteryPointsUsed {
            return "only \(BenchFormat.decimal(used, 0)) percentage points moved — below this "
                + "API's usable resolution. Run longer."
        }
        return "no battery movement recorded over this run"
    }
}
