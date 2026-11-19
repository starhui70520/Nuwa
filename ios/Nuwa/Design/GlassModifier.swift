import SwiftUI
import UIKit

extension Color {
    /// Exact Nuwa theme colors matching chat-demo/src/app/theme.css
    static let nuwaBrand = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 86 / 255, green: 134 / 255, blue: 254 / 255, alpha: 1)   // --dsw-static-blue-450
            : UIColor(red: 57 / 255, green: 100 / 255, blue: 254 / 255, alpha: 1)   // --dsw-static-blue-500
    })

    static let nuwaBrandText = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 103 / 255, green: 158 / 255, blue: 254 / 255, alpha: 1)  // --dsw-static-blue-400
            : UIColor(red: 57 / 255, green: 100 / 255, blue: 254 / 255, alpha: 1)   // --dsw-static-blue-500
    })

    static let nuwaBgBase = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 21 / 255, green: 21 / 255, blue: 23 / 255, alpha: 1)     // --dsw-static-neutral-bluish-950
            : UIColor(red: 255 / 255, green: 255 / 255, blue: 255 / 255, alpha: 1)  // --dsw-static-neutral-bluish-00
    })

    static let nuwaSidebarFill = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 27 / 255, green: 27 / 255, blue: 28 / 255, alpha: 1)     // --dsw-static-neutral-bluish-900
            : UIColor(red: 249 / 255, green: 250 / 255, blue: 251 / 255, alpha: 1)  // --dsw-static-neutral-bluish-50
    })

    static let nuwaSidebarActive = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 53 / 255, green: 54 / 255, blue: 56 / 255, alpha: 1)     // --dsw-static-neutral-bluish-800
            : UIColor(red: 228 / 255, green: 237 / 255, blue: 253 / 255, alpha: 1)  // --dsw-static-blue-100
    })

    static let nuwaBubbleFill = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 44 / 255, green: 44 / 255, blue: 46 / 255, alpha: 1)     // --dsw-static-neutral-bluish-850
            : UIColor(red: 237 / 255, green: 243 / 255, blue: 254 / 255, alpha: 1)  // --dsw-static-blue-50
    })

    static let nuwaLabelPrimary = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 249 / 255, green: 250 / 255, blue: 251 / 255, alpha: 1)  // --dsw-static-neutral-bluish-50
            : UIColor(red: 15 / 255, green: 17 / 255, blue: 21 / 255, alpha: 1)     // --dsw-static-neutral-bluish-1000
    })

    static let nuwaLabelSecondary = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 207 / 255, green: 211 / 255, blue: 214 / 255, alpha: 1)
            : UIColor(red: 97 / 255, green: 102 / 255, blue: 107 / 255, alpha: 1)
    })

    static let nuwaLabelTertiary = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 173 / 255, green: 178 / 255, blue: 184 / 255, alpha: 1)
            : UIColor(red: 129 / 255, green: 133 / 255, blue: 140 / 255, alpha: 1)
    })

    static let nuwaToggleActiveFill = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 40 / 255, green: 49 / 255, blue: 66 / 255, alpha: 1)     // --dsw-static-blue-900
            : UIColor(red: 237 / 255, green: 243 / 255, blue: 254 / 255, alpha: 1)  // --dsw-static-blue-50
    })

    static let nuwaToggleActiveBorder = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 72 / 255, green: 104 / 255, blue: 178 / 255, alpha: 1)   // --dsw-static-blue-600
            : UIColor(red: 183 / 255, green: 200 / 255, blue: 254 / 255, alpha: 1)  // --dsw-static-blue-300
    })
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
                            Color.white.opacity(colorScheme == .dark ? 0.24 : 0.72),
                            Color.white.opacity(colorScheme == .dark ? 0.06 : 0.16),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.75
                )
            }
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.30 : 0.06),
                radius: 10,
                x: 0,
                y: 3
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
        cornerRadius: CGFloat = 24,
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

    init(spacing: CGFloat = 8, @ViewBuilder content: @escaping () -> Content) {
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
