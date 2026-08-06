import SwiftUI

/// The Spendcap mark: three spending bars rising toward a hard cap rule.
///
/// The geometry here mirrors `scripts/make_icon.py`, which renders the same
/// drawing to the app icon and the marketing art. Change one without the other
/// and the logo inside the app stops matching the one on the home screen — so
/// `SpendcapMarkTests` pins the numbers on this side to the values in that
/// script.
struct SpendcapMark: View {
    /// Draw every element in the current foreground colour instead of
    /// green-on-amber, for places that tint the mark themselves.
    var monochrome = false

    var body: some View {
        GeometryReader { geo in
            // Everything below is expressed in the icon's own 1024 space and
            // scaled once, so the proportions can't drift from the PNG.
            let k = geo.size.width / Geometry.unit
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: Geometry.ruleHeight / 2 * k, style: .continuous)
                    .fill(ruleStyle)
                    .frame(width: Geometry.ruleWidth * k, height: Geometry.ruleHeight * k)
                    .offset(x: Geometry.ruleX * k, y: Geometry.ruleY * k)

                ForEach(Array(Geometry.barTops.enumerated()), id: \.offset) { index, top in
                    RoundedRectangle(cornerRadius: Geometry.barRadius * k, style: .continuous)
                        .fill(barStyle)
                        .frame(width: Geometry.barWidth * k,
                               height: (Geometry.baseline - top) * k)
                        .offset(x: Geometry.barX(index) * k, y: top * k)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private var ruleStyle: AnyShapeStyle {
        monochrome ? AnyShapeStyle(.foreground) : AnyShapeStyle(Color.spendcapCap)
    }

    private var barStyle: AnyShapeStyle {
        monochrome
            ? AnyShapeStyle(.foreground)
            : AnyShapeStyle(LinearGradient(
                colors: [.spendcapBarTop, .spendcapBarBottom],
                startPoint: .top,
                endPoint: .bottom))
    }

    /// The mark's proportions, on the same 1024 canvas the icon is drawn on.
    enum Geometry {
        static let unit: CGFloat = 1024
        static let barWidth: CGFloat = 132
        static let barGap: CGFloat = 60
        static let barRadius: CGFloat = 38
        static let baseline: CGFloat = 754
        static let barTops: [CGFloat] = [570, 452, 344]
        static let ruleY: CGFloat = 268
        static let ruleHeight: CGFloat = 48
        static let ruleOverhang: CGFloat = 46

        static var barsSpan: CGFloat { 3 * barWidth + 2 * barGap }
        static var ruleWidth: CGFloat { barsSpan + 2 * ruleOverhang }
        static var ruleX: CGFloat { (unit - ruleWidth) / 2 }
        static func barX(_ index: Int) -> CGFloat {
            (unit - barsSpan) / 2 + CGFloat(index) * (barWidth + barGap)
        }
    }
}

/// The mark on its dark field, clipped to the squircle iOS uses for app icons
/// — i.e. what the user sees on their home screen, shown back to them inside
/// the app. Prefer this over a bare `SpendcapMark` on system backgrounds: the
/// green-and-amber mark is drawn for a near-black field and thins out badly on
/// a white one.
struct SpendcapIcon: View {
    var size: CGFloat
    var body: some View {
        SpendcapMark()
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [.spendcapFieldTop, .spendcapFieldBottom],
                               startPoint: .top,
                               endPoint: .bottom)
            )
            // 0.2237 is the ratio behind iOS's icon squircle; a plain corner
            // radius at this size reads as a different shape next to the real
            // icon in the app switcher.
            .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
            .accessibilityHidden(true)
    }
}

extension Color {
    /// Palette shared with `scripts/make_icon.py`. `spendcapBarTop` is the
    /// asset-catalogue AccentColor lightened; `spendcapCap` is the same amber
    /// the 80%-of-cap warning uses, so the rule in the logo means what the
    /// amber on Trends means.
    static let spendcapBarTop = Color(red: 0x3A / 255, green: 0xDB / 255, blue: 0x59 / 255)
    static let spendcapBarBottom = Color(red: 0x1E / 255, green: 0x9E / 255, blue: 0x43 / 255)
    static let spendcapCap = Color(red: 0xFF / 255, green: 0x9F / 255, blue: 0x0A / 255)
    static let spendcapFieldTop = Color(red: 0x16 / 255, green: 0x1C / 255, blue: 0x25 / 255)
    static let spendcapFieldBottom = Color(red: 0x0B / 255, green: 0x0E / 255, blue: 0x13 / 255)
}

#Preview {
    VStack(spacing: 24) {
        SpendcapIcon(size: 120)
        SpendcapMark().frame(width: 64)
        SpendcapMark(monochrome: true).frame(width: 40).foregroundStyle(.secondary)
    }
    .padding()
}
