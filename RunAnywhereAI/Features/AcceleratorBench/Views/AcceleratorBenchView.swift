//
//  AcceleratorBenchView.swift
//  RunAnywhereAI
//
//  The Accelerator Bench: what the same work costs on the Neural Engine, the
//  CPU and the GPU, measured on the device in your hand from prompts you type.
//
//  It sits beside the existing Benchmarks screen rather than inside it. That
//  screen runs deterministic synthetic scenarios across every downloaded model
//  and is the right tool for tracking regressions. This one answers a
//  different question — where does the accelerator choice actually change the
//  outcome — and it answers it from real generations.
//

import SwiftUI
import RunAnywhere
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

struct AcceleratorBenchView: View {
    @State private var viewModel = AcceleratorBenchViewModel()
    @StateObject private var deviceService = DeviceInfoService.shared
    @State private var showsSettings = false
    @State private var copiedReport = false

    var body: some View {
        List {
            modeSection
            deviceSection
            BenchContenderPicker(viewModel: viewModel)

            switch viewModel.mode {
            case .prompt:
                BenchPromptPanel(viewModel: viewModel)
            case .contention:
                BenchContentionPanel(viewModel: viewModel)
            case .endurance:
                BenchEndurancePanel(viewModel: viewModel)
            }

            if viewModel.isRunning {
                progressSection
            }
            if let message = viewModel.errorMessage {
                errorSection(message)
            }
            if hasResults {
                reportSection
            }
            provenanceSection
        }
        .navigationTitle("Accelerator Bench")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsSettings = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("Bench settings")
            }
        }
        .safeAreaInset(edge: .bottom) { runBar }
        .sheet(isPresented: $showsSettings) {
            BenchSettingsSheet(viewModel: viewModel)
        }
        .task { viewModel.refresh() }
        .onChange(of: viewModel.mode) { _, _ in
            viewModel.resetSelectionForCurrentMode()
        }
    }

    // MARK: - Mode

    private var modeSection: some View {
        Section {
            Picker("Mode", selection: $viewModel.mode) {
                ForEach(BenchMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(viewModel.isRunning)

            Text(viewModel.mode.blurb)
                .appType(.secondary)
                .foregroundStyle(AppColors.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Device

    private var deviceSection: some View {
        Section {
            if let info = deviceService.deviceInfo {
                LabeledContent("Device", value: info.modelName)
                LabeledContent("Chip", value: info.chipName)
                LabeledContent("CPU cores", value: "\(HostCostSampler.coreCount)")
                LabeledContent(
                    "Neural Engine",
                    value: info.neuralEngineAvailable ? "present" : "not reported"
                )
                if !info.neuralEngineAvailable {
                    Label(
                        "No Neural Engine reported. The iOS Simulator has none — Core ML runs "
                        + "those graphs on the CPU there, so every ANE number from a simulator is "
                        + "a CPU number wearing a badge. Measure on a device.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .appType(.meta)
                    .foregroundStyle(AppColors.warningText)
                }
            } else {
                LabeledContent("CPU cores", value: "\(HostCostSampler.coreCount)")
            }
            BenchThermalPill(state: HostCostSampler.thermalState())
        } header: {
            Label("This device", systemImage: "cpu")
        }
    }

    // MARK: - Progress

    private var progressSection: some View {
        Section {
            VStack(alignment: .leading, spacing: AppSpacing.small) {
                HStack {
                    Text(viewModel.progress.phase.isEmpty ? "Working" : viewModel.progress.phase)
                        .appType(.cardTitle)
                    Spacer()
                    if let started = viewModel.runStartedAt {
                        BenchElapsedLabel(since: started)
                    }
                }
                if !viewModel.progress.contender.isEmpty {
                    Text(viewModel.progress.contender)
                        .appType(.meta)
                        .foregroundStyle(AppColors.mutedForeground)
                }
                if !viewModel.progress.detail.isEmpty {
                    Text(viewModel.progress.detail)
                        .appType(.caption)
                        .foregroundStyle(AppColors.mutedForeground)
                }
                if let fraction = viewModel.progress.fraction {
                    ProgressView(value: min(max(fraction, 0), 1))
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
        }
    }

    private func errorSection(_ message: String) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .appType(.secondary)
                .foregroundStyle(AppColors.dangerText)
        }
    }

    // MARK: - Report

    private var hasResults: Bool { !viewModel.resultSet.isEmpty }

    private var reportSection: some View {
        Section {
            Button {
                copyReport()
            } label: {
                Label(
                    copiedReport ? "Copied" : "Copy report",
                    systemImage: copiedReport ? "checkmark" : "doc.on.doc"
                )
            }
        } footer: {
            Text("Plain text, with the device fingerprint and each metric's caveat attached.")
        }
    }

    private func copyReport() {
        let text = viewModel.report(deviceInfo: deviceService.deviceInfo)
        #if canImport(UIKit) && !os(macOS)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        copiedReport = true
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            copiedReport = false
        }
    }

    // MARK: - Provenance

    private var provenanceSection: some View {
        Section {
            VStack(alignment: .leading, spacing: AppSpacing.small) {
                BenchProvenanceRow(
                    title: "Every number is measured here, now",
                    detail: "Nothing on this screen is read from a table. Load times, throughput, "
                        + "host CPU, thermal state and battery all come from the run you just "
                        + "watched, on this device."
                )
                BenchProvenanceRow(
                    title: "Host CPU is not accelerator energy",
                    detail: "It is this process's own user+system CPU time, from getrusage. "
                        + "Joules-per-token needs powermetrics and root, which no app has. Host "
                        + "CPU needs nothing and is what decides whether the app stays responsive "
                        + "while it infers."
                )
                BenchProvenanceRow(
                    title: "Warm-up is discarded",
                    detail: "A short generation runs and is thrown away before every measured pass, "
                        + "so first-call graph specialization is never charged to the number. "
                        + "Only one model is resident at a time."
                )
            }
        } header: {
            Label("How this is measured", systemImage: "checkmark.shield")
        }
    }
}

// MARK: - Run bar

private extension AcceleratorBenchView {
    var runBar: some View {
        HStack(spacing: AppSpacing.mediumLarge) {
            if viewModel.isRunning {
                Button(role: .destructive) {
                    viewModel.cancel()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    viewModel.run()
                } label: {
                    Label(runTitle, systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canRun)
            }
        }
        .padding(.horizontal, AppSpacing.large)
        .padding(.vertical, AppSpacing.mediumLarge)
        .background(.bar)
    }

    var runTitle: String {
        switch viewModel.mode {
        case .prompt:
            return viewModel.selected.count > 1 ? "Run on \(viewModel.selected.count) models" : "Run"
        case .contention:
            return "Run both passes"
        case .endurance:
            let total = viewModel.enduranceMinutes * max(1, viewModel.selected.count)
            return "Run \(total) min"
        }
    }
}

// MARK: - Elapsed label

/// Ticks once a second so a long run shows it is alive.
struct BenchElapsedLabel: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(AcceleratorBenchRunner.clock(context.date.timeIntervalSince(since)))
                .appType(.monoMetric)
                .foregroundStyle(AppColors.mutedForeground)
        }
    }
}

// MARK: - Provenance row

struct BenchProvenanceRow: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
            Text(title)
                .appType(.cardTitle)
            Text(detail)
                .appType(.caption)
                .foregroundStyle(AppColors.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Settings

struct BenchSettingsSheet: View {
    @Bindable var viewModel: AcceleratorBenchViewModel
    @Environment(\.dismiss)
    private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Time to first token", isOn: $viewModel.showsTimeToFirstToken)
                    Toggle("Host CPU cost", isOn: $viewModel.showsHostCpu)
                    Toggle("Thermal state", isOn: $viewModel.showsThermal)
                } header: {
                    Label("Metrics", systemImage: "list.bullet.rectangle")
                }

                Section {
                    Toggle("Rank contenders by throughput", isOn: $viewModel.showsThroughputRanking)
                } header: {
                    Label("Throughput ranking", systemImage: "chart.bar")
                } footer: {
                    Text("Off by default, for a measurement reason rather than a cosmetic one. At "
                        + "matched quantization the Neural Engine is not the fastest path on Apple "
                        + "silicon — the GPU is — so a raw tok/s ranking makes the bench a story "
                        + "about peak speed. The claims it is built to show are behaviour under "
                        + "contention, host cost and sustained throughput. Turn this on to see the "
                        + "ranking anyway; each contender's own throughput is always shown either "
                        + "way.")
                }

                Section {
                    Text("Contenders are every downloaded language model, whatever engine runs "
                        + "them. Add a model to the catalog and it appears here — nothing in this "
                        + "screen names a model or a family.")
                        .appType(.secondary)
                        .foregroundStyle(AppColors.mutedForeground)
                } header: {
                    Label("Adding models", systemImage: "plus.square.on.square")
                }
            }
            .navigationTitle("Bench settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
