import SwiftUI

extension Color {
    /// Nuwa brand blue (#3964FE) matching web theme
    static let nuwaBrand = Color(red: 57 / 255, green: 100 / 255, blue: 254 / 255)
    static let nuwaBrandSoft = Color(red: 57 / 255, green: 100 / 255, blue: 254 / 255).opacity(0.14)
}

/// Applies native iOS 26 Liquid Glass when available, falling back to translucent material
/// with a specular hairline border on iOS 17-18.
struct NuwaGlassModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content
                .glassEffect(glassStyle, in: shape)
        } else {
            fallbackView(content: content)
        }
        #else
        fallbackView(content: content)
        #endif
    }

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    private var glassStyle: Glass {
        var style: Glass = .regular
        if let tint {
            style = style.tint(tint)
        }
        if interactive {
            style = style.interactive()
        }
        return style
    }
    #endif

    @ViewBuilder
    private func fallbackView(content: Content) -> some View {
        content
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    if let tint {
                        shape.fill(tint.opacity(colorScheme == .dark ? 0.22 : 0.14))
                    }
                }
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.28 : 0.72),
                            Color.white.opacity(colorScheme == .dark ? 0.06 : 0.18),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.75
                )
            }
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.08),
                radius: 14,
                x: 0,
                y: 6
            )
    }
}

extension View {
    func nuwaGlass<S: InsettableShape>(
        in shape: S = Capsule(),
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(NuwaGlassModifier(shape: shape, tint: tint, interactive: interactive))
    }

    func nuwaGlassCard(
        cornerRadius: CGFloat = 22,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(
            NuwaGlassModifier(
                shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                tint: tint,
                interactive: interactive
            )
        )
    }
}

/// Groups adjacent Liquid Glass controls on iOS 26 so they morph and refract together.
struct NuwaGlassGroup<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    init(spacing: CGFloat = 10, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}
