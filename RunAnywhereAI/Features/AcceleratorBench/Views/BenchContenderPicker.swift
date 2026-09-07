//
//  BenchContenderPicker.swift
//  RunAnywhereAI
//
//  Picks which models the bench runs. Every downloaded LLM is eligible
//  whatever its engine, grouped by the silicon it executes on, so a model
//  added to the catalog later shows up here with no code change.
//

import SwiftUI

struct BenchContenderPicker: View {
    @Bindable var viewModel: AcceleratorBenchViewModel

    private var grouped: [(accelerator: BenchAccelerator, contenders: [BenchContender])] {
        BenchAccelerator.allCases.compactMap { accelerator in
            let matching = viewModel.available.filter { $0.accelerator == accelerator }
            return matching.isEmpty ? nil : (accelerator, matching)
        }
    }

    var body: some View {
        Section {
            if viewModel.available.isEmpty {
                BenchEmptyContenderNotice()
            } else {
                ForEach(grouped, id: \.accelerator) { group in
                    ForEach(group.contenders) { contender in
                        ContenderRow(
                            contender: contender,
                            isSelected: viewModel.selectedIds.contains(contender.modelId),
                            isDisabled: viewModel.isRunning
                        ) {
                            viewModel.toggle(contender)
                        }
                    }
                }

                HStack {
                    Button("Reset to default") { viewModel.resetSelectionForCurrentMode() }
                        .appType(.meta)
                    Spacer()
                    Text("\(viewModel.selected.count) selected")
                        .appType(.meta)
                        .foregroundStyle(AppColors.mutedForeground)
                }
                .disabled(viewModel.isRunning)
            }
        } header: {
            Label("Contenders", systemImage: "square.stack.3d.down.right")
        } footer: {
            Text(footerText)
        }
    }

    private var footerText: String {
        switch viewModel.mode {
        case .prompt:
            return "One model per run is the clearest demo. Add more and each answers the same "
                + "prompt in turn, one resident at a time."
        case .contention:
            return "Pick the Neural Engine model and at least one rival — a delta only means "
                + "something next to something else."
        case .endurance:
            return "Each contender runs the full duration, one after the other. Two contenders at "
                + "15 minutes is a 30-minute session."
        }
    }
}

// MARK: - Row

private struct ContenderRow: View {
    let contender: BenchContender
    let isSelected: Bool
    let isDisabled: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: AppSpacing.mediumLarge) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? contender.accelerator.tint : AppColors.textTertiary)
                    .font(.system(size: 18))

                VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
                    Text(contender.displayName)
                        .appType(.body)
                        .foregroundStyle(AppColors.foreground)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: AppSpacing.small) {
                        BenchAcceleratorBadge(
                            accelerator: contender.accelerator,
                            engine: contender.engineLabel
                        )
                        if contender.sizeBytes > 0 {
                            Text(BenchFormat.bytes(contender.sizeBytes))
                                .appType(.meta)
                                .foregroundStyle(AppColors.mutedForeground)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.55 : 1)
    }
}

// MARK: - Empty state

struct BenchEmptyContenderNotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            Text("No models on disk")
                .appType(.cardTitle)
            Text("The bench only lists downloaded models, because a download would otherwise be "
                + "timed as part of the first load. Get one from the Models screen — a Neural "
                + "Engine model plus a CPU or GPU model of the same size makes the best "
                + "comparison.")
                .appType(.secondary)
                .foregroundStyle(AppColors.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, AppSpacing.xSmall)
    }
}
