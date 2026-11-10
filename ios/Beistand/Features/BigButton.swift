import SwiftUI

/// Full-width button, at least 88 pt tall. Long press explains it aloud.
/// Follows the text-size setting; at accessibility sizes the icon goes above the text
/// so the words keep the full width. With "Increase Contrast" it gets a solid outline.
struct BigButton: View {
    let title: String
    var systemImage: String? = nil
    var color: Color = .blue
    var explanation: String? = nil
    let action: () -> Void
    @State private var lastTap = Date.distantPast
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button {
            // Shake-proof: ignore repeated taps within 0.8 s.
            guard Date().timeIntervalSince(lastTap) > 0.8 else { return }
            lastTap = Date()
            action()
        } label: {
            label
                .padding(.horizontal, 24).padding(.vertical, 12)
                .frame(maxWidth: .infinity, minHeight: 88)
                .foregroundStyle(.white)
                .contentShape(Rectangle())
                // Tinted glass; solid with a border when the person needs contrast (see Surface).
                .surface(color, cornerRadius: 26, interactive: true)
                .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.8).onEnded { _ in
            Speaker.shared.say(explanation ?? title)
        })
        .accessibilityHint(explanation ?? "")
    }

    @ViewBuilder private var label: some View {
        let text = Text(title).scaledFont(30).lineLimit(4).minimumScaleFactor(0.7)
            .fixedSize(horizontal: false, vertical: true)
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                if let systemImage { Image(systemName: systemImage).scaledFont(30, weight: .semibold, maxFactor: 1.3) }
                text
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 16) {
                if let systemImage { Image(systemName: systemImage).scaledFont(36, weight: .semibold, maxFactor: 1.3) }
                text
                Spacer(minLength: 0)
            }
        }
    }
}
