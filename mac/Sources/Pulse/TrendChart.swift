import Charts
import SwiftUI

struct TrendChart: View {
    let pts: [DayValue]
    let label: String
    let money: Bool
    let color: Color
    @State private var hoverDay: String?

    private var hovered: DayValue? { pts.first { $0.day == hoverDay } }
    private func fmt(_ v: Double?) -> String { money ? Fmt.usd(v) : Fmt.num(v) }

    private static let months = Loc.months
    private func dayLabel(_ d: String) -> String {
        let p = d.split(separator: "-")
        guard p.count == 3, let m = Int(p[1]), let g = Int(p[2]), (1...12).contains(m) else { return d }
        return "\(g) \(Self.months[m - 1])"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(fmt(hovered?.value ?? pts.last?.value))
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .moneyBlur(money)
                    Text(hovered.map { dayLabel($0.day) } ?? "bugün")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            Chart {
                ForEach(pts, id: \.day) { p in
                    AreaMark(x: .value("Gün", p.day), y: .value(label, p.value))
                        .foregroundStyle(LinearGradient(colors: [color.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Gün", p.day), y: .value(label, p.value))
                        .foregroundStyle(color)
                        .interpolationMethod(.monotone)
                }
                if let h = hovered {
                    RuleMark(x: .value("Gün", h.day))
                        .foregroundStyle(.white.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    PointMark(x: .value("Gün", h.day), y: .value(label, h.value))
                        .foregroundStyle(color)
                        .symbolSize(40)
                        .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            VStack(spacing: 0) {
                                Text(fmt(h.value)).font(.system(size: 11, weight: .semibold, design: .rounded)).moneyBlur(money)
                                Text(dayLabel(h.day)).font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 5))
                        }
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let loc):
                                guard let plot = proxy.plotFrame else { return }
                                let x = loc.x - geo[plot].origin.x
                                hoverDay = nearestDay(x: x, proxy: proxy)
                            case .ended:
                                hoverDay = nil
                            }
                        }
                }
            }
            .frame(height: 80)
            .moneyBlur(money)
        }
    }

    private func nearestDay(x: CGFloat, proxy: ChartProxy) -> String? {
        var best: (String, CGFloat)?
        for p in pts {
            guard let px = proxy.position(forX: p.day) else { continue }
            let d = abs(px - x)
            if best == nil || d < best!.1 { best = (p.day, d) }
        }
        return best?.0
    }
}
