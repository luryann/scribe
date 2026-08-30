import SwiftUI

/// Scribe commits to one look: a white / tinted-grey Liquid Glass panel. Colours are fixed
/// rather than semantic so the panel reads the same regardless of the system appearance.
extension Color {
    static let ink        = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let inkSoft     = Color(red: 0.24, green: 0.24, blue: 0.26)
    static let inkFaint    = Color(red: 0.24, green: 0.24, blue: 0.26).opacity(0.55)
    static let scribeBlue  = Color(red: 0.086, green: 0.404, blue: 0.839)
    static let scribeRed   = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let panelTint   = Color.white.opacity(0.5)
    static let hairline    = Color.black.opacity(0.06)
    static let wellFill    = Color.white.opacity(0.55)
}

extension Font {
    /// Reading content — transcript, summary, notes, card answers — is set in the system serif.
    static func reading(_ size: CGFloat) -> Font { .system(size: size, design: .serif) }
}

/// The translucent panel background: a soft cool→warm diagonal wash over the desktop,
/// with two faint colour blooms, kept see-through so it reads as glass.
struct GlassBackground: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)

            LinearGradient(
                colors: [
                    Color(red: 0.91, green: 0.93, blue: 0.97).opacity(0.55),
                    Color(red: 0.83, green: 0.86, blue: 0.91).opacity(0.55),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [Color(red: 0.64, green: 0.73, blue: 0.89).opacity(0.22), .clear],
                center: .topLeading, startRadius: 0, endRadius: 260
            )
            RadialGradient(
                colors: [Color(red: 0.86, green: 0.76, blue: 0.89).opacity(0.20), .clear],
                center: .bottomTrailing, startRadius: 0, endRadius: 300
            )
        }
        .ignoresSafeArea()
    }
}

/// A soft inset "well" used for cards, chips and rows inside the panel.
struct Well<Content: View>: View {
    var padding: CGFloat = 12
    var cornerRadius: CGFloat = 11
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(Color.wellFill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.6), lineWidth: 0.5)
            )
    }
}

/// The single contextual action pinned to the bottom of the panel.
struct FooterActionButton: View {
    let title: String
    var systemImage: String = "sparkles"
    var isBusy: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isBusy {
                    ProgressView().controlSize(.small)
                    Text("Working…")
                } else {
                    Image(systemName: systemImage)
                    Text(title)
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(
                (isEnabled ? Color.scribeBlue.opacity(0.12) : Color.gray.opacity(0.12)),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .foregroundStyle(isEnabled ? Color.scribeBlue : Color.inkFaint)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isBusy)
    }
}

/// Centered empty-state used across tabs.
struct EmptyHint: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.55))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.8), lineWidth: 0.5))
                    .frame(width: 58, height: 58)
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(Color.inkFaint)
            }
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.ink)
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.inkSoft.opacity(0.85))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 230)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}
