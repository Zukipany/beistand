import SwiftUI

/// Beistand's look: Apple's glass (iOS 26 "Liquid Glass") where it helps, solid where it would hurt.
///
/// Glass lowers contrast. Anyone who needs contrast gets solid, high-contrast surfaces instead:
/// Reduce Transparency or Increase Contrast in iOS settings, or the low vision / easy reading modes.
enum Look {
    /// Solid surfaces instead of glass.
    static func solid(reduceTransparency: Bool, contrast: ColorSchemeContrast) -> Bool {
        let s = AppStore.shared
        return reduceTransparency || contrast == .increased || s.has(.lowVision) || s.has(.easyReading)
    }
}

/// A glass (or solid) surface behind content. `tint` makes it a coloured button-like surface with white text.
struct Surface: ViewModifier {
    var tint: Color?
    var cornerRadius: CGFloat = 24
    var interactive = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if Look.solid(reduceTransparency: reduceTransparency, contrast: contrast) {
            content
                .background(tint.map { A11yColor.fill($0) } ?? Color(.secondarySystemBackground), in: shape)
                .overlay { if contrast == .increased { shape.strokeBorder(Color.primary, lineWidth: 3) } }
        } else if #available(iOS 26, *) {
            content.glassEffect(tint.map { Glass.regular.tint(A11yColor.fill($0).opacity(0.82)).interactive(interactive) }
                                ?? Glass.regular.interactive(interactive), in: shape)
        } else {
            content
                .background(tint.map { AnyShapeStyle(A11yColor.fill($0).opacity(0.88)) } ?? AnyShapeStyle(.ultraThinMaterial), in: shape)
        }
    }
}

extension View {
    /// Glass (or solid, when the person needs contrast) behind this view.
    func surface(_ tint: Color? = nil, cornerRadius: CGFloat = 24, interactive: Bool = false) -> some View {
        modifier(Surface(tint: tint, cornerRadius: cornerRadius, interactive: interactive))
    }
}

/// Groups glass shapes so they blend and move together (iOS 26); a plain stack before that.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder let content: Content
    var body: some View {
        if #available(iOS 26, *) { GlassEffectContainer(spacing: spacing) { content } } else { content }
    }
}

/// Soft colour behind the screens, so glass has something to show; plain when the person needs contrast.
struct BeistandBackground: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if Look.solid(reduceTransparency: reduceTransparency, contrast: contrast) {
            Color(.systemBackground).ignoresSafeArea()
        } else {
            let dark = scheme == .dark
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.55, 0.45], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1],
            ], colors: dark ? [
                Color(red: 0.05, green: 0.10, blue: 0.22), Color(red: 0.10, green: 0.08, blue: 0.24), Color(red: 0.03, green: 0.16, blue: 0.22),
                Color(red: 0.07, green: 0.14, blue: 0.28), Color(red: 0.12, green: 0.10, blue: 0.30), Color(red: 0.04, green: 0.20, blue: 0.24),
                Color(red: 0.02, green: 0.06, blue: 0.14), Color(red: 0.06, green: 0.08, blue: 0.18), Color(red: 0.02, green: 0.10, blue: 0.14),
            ] : [
                Color(red: 0.86, green: 0.92, blue: 1.00), Color(red: 0.92, green: 0.89, blue: 1.00), Color(red: 0.84, green: 0.96, blue: 0.97),
                Color(red: 0.90, green: 0.95, blue: 1.00), Color(red: 0.97, green: 0.95, blue: 1.00), Color(red: 0.88, green: 0.98, blue: 0.95),
                Color(red: 0.96, green: 0.97, blue: 1.00), Color(red: 0.98, green: 0.96, blue: 0.99), Color(red: 0.95, green: 0.99, blue: 0.98),
            ])
            .ignoresSafeArea()
        }
    }
}

/// A feature tile on the home screen: icon, name, one line of what it does. Long press reads the
/// explanation aloud (like the big buttons); double taps are ignored, so a shaky hand does not open twice.
struct Tile: View {
    let title: String
    let icon: String
    var tint: Color = .blue
    var subtitle: String? = nil
    var explanation: String? = nil
    let action: () -> Void
    @State private var lastTap = Date.distantPast
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button {
            guard Date().timeIntervalSince(lastTap) > 0.8 else { return }
            lastTap = Date()
            action()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon)
                    .font(.title2.weight(.semibold))
                    .frame(width: 46, height: 46)
                    .background(.white.opacity(0.22), in: Circle())
                Spacer(minLength: 0)
                Text(title).font(.title3.bold()).lineLimit(3).minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle, !typeSize.isAccessibilitySize {
                    Text(subtitle).font(.subheadline).opacity(0.9).lineLimit(2)
                }
            }
            .foregroundStyle(.white)
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: typeSize.isAccessibilitySize ? 170 : 140, alignment: .topLeading)
            .contentShape(Rectangle())
            .surface(tint, cornerRadius: 26, interactive: true)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.8).onEnded { _ in
            Speaker.shared.say(explanation ?? title)
        })
        .accessibilityLabel(title)
        .accessibilityHint(explanation ?? subtitle ?? "")
    }
}

/// A section of the home screen: a short heading and tiles in two columns (one at very large text).
struct TileSection<Content: View>: View {
    let title: String
    let icon: String
    var subtitle: String? = nil
    @ViewBuilder let content: Content
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Label(title, systemImage: icon).font(.title2.bold())
                if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            // Plain grid: a glass container would merge neighbouring tiles (one disappeared in testing).
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: typeSize.isAccessibilitySize ? 1 : 2),
                      spacing: 12) { content }
        }
    }
}
