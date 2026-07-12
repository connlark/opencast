import SwiftUI

struct EpisodePipelineStepRow: View {
    let step: EpisodePipelineStep

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(step.kind.title)
                    .font(.subheadline)
                    .foregroundStyle(titleStyle)

                if let detailText {
                    Text(detailText)
                        .font(.footnote)
                        .foregroundStyle(detailStyle)
                }
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(statusDescription)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch step.status {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .waiting:
            Image(systemName: "circle.dotted")
                .foregroundStyle(.tertiary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .running(let fraction, _):
            if let fraction {
                ZStack {
                    Circle()
                        .stroke(.quaternary, lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .animation(.smooth, value: fraction)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var detailText: String? {
        switch step.status {
        case .running(_, let detail):
            detail
        case .failed(let message):
            message
        case .done, .waiting:
            nil
        }
    }

    private var titleStyle: AnyShapeStyle {
        switch step.status {
        case .waiting:
            AnyShapeStyle(.tertiary)
        case .done, .running, .failed:
            AnyShapeStyle(.primary)
        }
    }

    private var detailStyle: AnyShapeStyle {
        step.status.isFailed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary)
    }

    private var statusDescription: String {
        switch step.status {
        case .done:
            "Complete"
        case .waiting:
            "Waiting"
        case .running(let fraction, _):
            fraction.map { "\(Int(($0 * 100).rounded())) percent" } ?? "In progress"
        case .failed:
            "Failed"
        }
    }
}

#Preview("Dark") {
    VStack(alignment: .leading, spacing: 10) {
        EpisodePipelineStepRow(step: EpisodePipelineStep(kind: .download, status: .done))
        EpisodePipelineStepRow(step: EpisodePipelineStep(
            kind: .transcribe,
            status: .running(fraction: 0.58, detail: "34:00 of 58:00")
        ))
        EpisodePipelineStepRow(step: EpisodePipelineStep(kind: .detectAds, status: .waiting))
        EpisodePipelineStepRow(step: EpisodePipelineStep(
            kind: .download,
            status: .failed(message: "The download couldn't finish.")
        ))
    }
    .padding()
    .preferredColorScheme(.dark)
}

#Preview("Light") {
    VStack(alignment: .leading, spacing: 10) {
        EpisodePipelineStepRow(step: EpisodePipelineStep(kind: .download, status: .done))
        EpisodePipelineStepRow(step: EpisodePipelineStep(
            kind: .transcribe,
            status: .running(fraction: nil, detail: "Preparing speech model…")
        ))
        EpisodePipelineStepRow(step: EpisodePipelineStep(kind: .detectAds, status: .waiting))
    }
    .padding()
    .preferredColorScheme(.light)
}
