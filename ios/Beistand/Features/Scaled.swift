import SwiftUI

/// Big text that still follows the iPhone's text-size setting.
/// `.system(size:)` alone ignores it. These sizes are already large, so growth is capped:
/// at the largest accessibility sizes, text that is 3× bigger would no longer fit a word per line.
struct ScaledFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let base: CGFloat
    private let weight: Font.Weight
    private let maxFactor: CGFloat

    init(size: CGFloat, weight: Font.Weight, relativeTo style: Font.TextStyle, maxFactor: CGFloat) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        base = size; self.weight = weight; self.maxFactor = maxFactor
    }

    func body(content: Content) -> some View {
        content.font(.system(size: min(size, base * maxFactor), weight: weight))
    }
}

extension View {
    func scaledFont(_ size: CGFloat, weight: Font.Weight = .bold, relativeTo style: Font.TextStyle = .title,
                    maxFactor: CGFloat = 1.8) -> some View {
        modifier(ScaledFont(size: size, weight: weight, relativeTo: style, maxFactor: maxFactor))
    }
}

/// Button colours dark enough for white text (at least 4.5:1, WCAG AA even for small text).
/// The system green and orange are only about 2.2:1 with white.
enum A11yColor {
    static func fill(_ c: Color) -> Color {
        switch c {
        case .green: Color(red: 0.0, green: 0.45, blue: 0.18)    // ≈ 6:1
        case .orange: Color(red: 0.70, green: 0.27, blue: 0.0)   // ≈ 5:1
        case .red: Color(red: 0.77, green: 0.10, blue: 0.10)     // ≈ 6:1
        case .blue: Color(red: 0.0, green: 0.33, blue: 0.80)     // ≈ 6.5:1
        case .indigo: Color(red: 0.25, green: 0.22, blue: 0.68)  // ≈ 8:1
        case .gray: Color(white: 0.33)                           // ≈ 9:1
        default: c
        }
    }
}

/// Lays content out to fill the screen (so Spacers work) but scrolls when large text makes it taller.
struct FitScroll<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        GeometryReader { geo in
            ScrollView {
                content.frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}
