import SwiftUI

/// 14-day cost trend miniature for a cost row's right side. Single
/// series, so no legend — a 1.4pt secondary line with the endpoint
/// emphasized (today is the point the eye should land on). Answers "is
/// the burn accelerating" without opening the detail tab.
struct CostSparkline: View {
    /// Dense oldest→newest values (one per day, $0 for quiet days), from
    /// `OverviewSummary.trailingDailySeries`.
    let values: [Double]

    var width: CGFloat = 64
    var height: CGFloat = 16

    var body: some View {
        let maxValue = max(values.max() ?? 0, 0.01)
        let points = values.enumerated().map { index, value in
            CGPoint(
                x: CGFloat(index) / CGFloat(max(values.count - 1, 1)) * width,
                // 1.5pt inset top and bottom so the stroke + endpoint dot
                // don't clip at the extremes.
                y: height - 1.5 - CGFloat(value / maxValue) * (height - 3)
            )
        }

        ZStack(alignment: .topLeading) {
            Path { path in
                guard let first = points.first else { return }
                path.move(to: first)
                for point in points.dropFirst() { path.addLine(to: point) }
            }
            .stroke(
                Color.secondary.opacity(0.55),
                style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
            )

            if let last = points.last {
                Circle()
                    .fill(Color.primary.opacity(0.85))
                    .frame(width: 3.5, height: 3.5)
                    .position(last)
            }
        }
        .frame(width: width, height: height)
        .accessibilityLabel("14-day cost trend")
    }
}

#Preview {
    VStack(spacing: 12) {
        CostSparkline(values: [1, 3.2, 4, 2.1, 2.5, 1.9, 5.2, 3.4, 3.5, 2.4, 3.6, 6.8, 7.1, 4.9])
        CostSparkline(values: [0, 0, 0.2, 0, 0.4, 0.1, 0, 0.3, 0.2, 0.5, 0.4, 0.6, 0.3, 0.8])
    }
    .padding(16)
}
