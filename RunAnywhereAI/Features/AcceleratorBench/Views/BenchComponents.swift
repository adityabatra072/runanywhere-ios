//
//  BenchComponents.swift
//  RunAnywhereAI
//
//  Small shared pieces for the Accelerator Bench: metric tiles, the
//  accelerator badge, and the live throughput chart.
//

import Charts
import SwiftUI

// MARK: - Accelerator badge

struct BenchAcceleratorBadge: View {
    let accelerator: BenchAccelerator
    var showsEngine = true

    var body: some View {
        HStack(spacing: AppSpacing.xSmall) {
            Image(systemName: accelerator.symbol)
                .font(.system(size: 10, weight: .semibold))
            Text(showsEngine ? "\(accelerator.shortLabel) · \(accelerator.engineLabel)" : accelerator.shortLabel)
                .appType(.chip)
        }
        .padding(.horizontal, AppSpacing.smallMedium)
        .padding(.vertical, AppSpacing.xxSmall)
        .foregroundStyle(accelerator.tint)
        .background(
            Capsule().fill(accelerator.tint.opacity(0.12))
        )
        .overlay(
            Capsule().stroke(accelerator.tint.opacity(0.3), lineWidth: AppSpacing.strokeThin)
        )
    }
}

/// Shows measured placement, and says so when it is not what was asked for.
///
/// This exists because the alternative — labelling by framework — put "CPU" on
/// a contender the runtime had placed entirely on the A16 GPU.
struct BenchPlacementBadge: View {
    let placement: BenchPlacement

    var body: some View {
        VStack(alignment: .trailing, spacing: AppSpacing.xxSmall) {
            BenchAcceleratorBadge(accelerator: placement.actual)
            if placement.divergedFromRequest {
                Label(
                    "asked for \(placement.requested.shortLabel), ran on \(placement.actual.shortLabel)",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .appType(.caption)
                .foregroundStyle(AppColors.warningText)
            }
            if !placement.deviceName.isEmpty {
                Text(placement.deviceName)
                    .appType(.caption)
                    .foregroundStyle(AppColors.mutedForeground)
            }
        }
    }
}

// MARK: - Metric tile

/// One measured value with its unit and, where it matters, the caveat that
/// keeps it honest.
struct BenchMetricTile: View {
    let title: String
    let value: String
    var unit: String?
    var footnote: String?
    var tint: Color = AppColors.foreground
    /// Draws the tile as the panel's headline number.
    var isHeadline = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
            Text(title.uppercased())
                .appType(.overline)
                .foregroundStyle(AppColors.mutedForeground)

            HStack(alignment: .lastTextBaseline, spacing: AppSpacing.xSmall) {
                Text(value)
                    .appType(isHeadline ? .metric : .monoMetric)
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if let unit {
                    Text(unit)
                        .appType(.meta)
                        .foregroundStyle(AppColors.mutedForeground)
                }
            }

            if let footnote {
                Text(footnote)
                    .appType(.caption)
                    .foregroundStyle(AppColors.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.mediumLarge)
        .background(
            RoundedRectangle(cornerRadius: AppSpacing.cornerRadiusXLarge)
                .fill(AppColors.surfaceSunken)
        )
    }
}

/// Adaptive grid so tiles reflow on a phone and spread out on a Mac.
struct BenchMetricGrid<Content: View>: View {
    var minimumTileWidth: CGFloat = 150
    @ViewBuilder var content: Content

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: minimumTileWidth), spacing: AppSpacing.smallMedium)],
            spacing: AppSpacing.smallMedium
        ) {
            content
        }
    }
}

// MARK: - Verdict row

/// A single claim with its measured basis, drawn so the claim and the number
/// are never separated.
struct BenchVerdictRow: View {
    let claim: String
    let value: String
    let detail: String
    let tint: Color
    var symbol: String = "checkmark.seal.fill"

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.mediumLarge) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 22)

            VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.small) {
                    Text(value)
                        .appType(.monoMetric)
                        .foregroundStyle(tint)
                    Text(claim)
                        .appType(.cardTitle)
                }
                Text(detail)
                    .appType(.caption)
                    .foregroundStyle(AppColors.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.mediumLarge)
        .background(
            RoundedRectangle(cornerRadius: AppSpacing.cornerRadiusXLarge)
                .fill(tint.opacity(0.08))
        )
    }
}

// MARK: - Live throughput chart

/// Throughput over time for one or more series.
///
/// A flat line is the claim in both comparison modes, so the y-axis starts at
/// zero: a chart that auto-scales to the data's own range turns ordinary noise
/// into a dramatic slope and would overstate every result.
struct BenchThroughputChart: View {
    struct Series: Identifiable {
        let id: String
        let label: String
        let tint: Color
        let samples: [BenchSample]
    }

    let series: [Series]
    var height: CGFloat = 160
    /// Marks where the synthetic CPU load began, for the contention chart.
    var loadStartedAt: TimeInterval?

    private var upperBound: Double {
        let peak = series.flatMap(\.samples).map(\.tokensPerSecond).max() ?? 1
        return max(1, peak * 1.25)
    }

    var body: some View {
        Chart {
            ForEach(series) { line in
                ForEach(line.samples) { sample in
                    LineMark(
                        x: .value("Elapsed", sample.elapsed),
                        y: .value("tok/s", sample.tokensPerSecond),
                        // `series:` is what keeps two lines apart. Without it
                        // Charts joins every point into one polyline and the
                        // quiet and loaded passes come out as a single zigzag.
                        series: .value("Series", line.label)
                    )
                    .foregroundStyle(by: .value("Series", line.label))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }

            if let loadStartedAt {
                RuleMark(x: .value("Load starts", loadStartedAt))
                    .foregroundStyle(AppColors.danger.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("load on")
                            .appType(.caption)
                            .foregroundStyle(AppColors.danger)
                    }
            }
        }
        .chartYScale(domain: 0...upperBound)
        .chartForegroundStyleScale(
            domain: series.map(\.label),
            range: series.map(\.tint)
        )
        .chartXAxisLabel("seconds")
        .chartYAxisLabel("tok/s")
        .chartLegend(series.count > 1 ? .visible : .hidden)
        .frame(height: height)
    }
}

// MARK: - Thermal pill

struct BenchThermalPill: View {
    let state: ProcessInfo.ThermalState

    var body: some View {
        HStack(spacing: AppSpacing.xSmall) {
            Image(systemName: "thermometer.medium")
                .font(.system(size: 10, weight: .semibold))
            Text(state.benchLabel)
                .appType(.chip)
        }
        .padding(.horizontal, AppSpacing.smallMedium)
        .padding(.vertical, AppSpacing.xxSmall)
        .foregroundStyle(state.benchTint)
        .background(Capsule().fill(state.benchTint.opacity(0.12)))
    }
}

// MARK: - Formatting helpers

enum BenchFormat {
    static func decimal(_ value: Double?, _ places: Int = 1, fallback: String = "—") -> String {
        guard let value, value.isFinite else { return fallback }
        return String(format: "%.\(places)f", value)
    }

    static func signedPercent(_ value: Double?, _ places: Int = 1) -> String {
        guard let value, value.isFinite else { return "—" }
        return (value >= 0 ? "+" : "") + String(format: "%.\(places)f", value) + "%"
    }

    static func milliseconds(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        if value >= 1000 {
            return String(format: "%.2f s", value / 1000)
        }
        return String(format: "%.0f ms", value)
    }

    static func bytes(_ value: Int64) -> String {
        guard value > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
