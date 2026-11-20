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

    static let nuwaChatBackground = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor(white: 17 / 255, alpha: 1) : .white
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

    static let nuwaDrawerCardFill = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 39 / 255, green: 40 / 255, blue: 43 / 255, alpha: 1)
            : UIColor(red: 255 / 255, green: 255 / 255, blue: 255 / 255, alpha: 1)
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

    static let nuwaControlFill = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 1.0, alpha: 0.08)
            : UIColor(red: 15 / 255, green: 23 / 255, blue: 42 / 255, alpha: 0.05)
    })

    static let nuwaControlBorder = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 1.0, alpha: 0.12)
            : UIColor(red: 15 / 255, green: 23 / 255, blue: 42 / 255, alpha: 0.09)
    })

    static let nuwaCodeBlockFill = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 28 / 255, green: 29 / 255, blue: 34 / 255, alpha: 1)
            : UIColor(red: 245 / 255, green: 247 / 255, blue: 250 / 255, alpha: 1)
    })

    static let nuwaCodeBannerFill = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 37 / 255, green: 39 / 255, blue: 46 / 255, alpha: 1)
            : UIColor(red: 235 / 255, green: 240 / 255, blue: 247 / 255, alpha: 1)
    })

    static let nuwaInlineCodeFill = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 43 / 255, green: 45 / 255, blue: 53 / 255, alpha: 1)
            : UIColor(red: 234 / 255, green: 239 / 255, blue: 246 / 255, alpha: 1)
    })
}

/// Crisp, zero-latency tactile press button style that never conflicts with Liquid Glass or ScrollViews.
struct NuwaTactileButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1.0)
            .opacity(configuration.isPressed ? 0.78 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Applies native iOS 26 Liquid Glass strictly on top-level floating chrome (header, composer container,
/// floating scroll-to-bottom button, toast), with a lightweight fallback on iOS 17-18.
/// NEVER nest `.nuwaGlass` inside another `.nuwaGlass` or place it inside scrolling message lists.
struct NuwaGlassModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content
                .contentShape(shape)
                .glassEffect(glassStyle, in: shape)
        } else {
            fallbackView(content: content)
                .contentShape(shape)
        }
        #else
        fallbackView(content: content)
            .contentShape(shape)
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
                    Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.08),
                    lineWidth: 0.75
                )
            }
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.05),
                radius: 8,
                x: 0,
                y: 2
            )
    }
}

/// Lightweight GPU-free pill surface for controls inside glass cards or scrolling lists (120Hz zero jank).
struct NuwaPillSurfaceModifier: ViewModifier {
    let selected: Bool
    let destructive: Bool

    func body(content: Content) -> some View {
        content
            .background(fillColor, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(borderColor, lineWidth: selected ? 1.0 : 0.75)
            )
    }

    private var fillColor: Color {
        if destructive { return Color.red.opacity(0.09) }
        return selected ? Color.nuwaToggleActiveFill : Color.nuwaControlFill
    }

    private var borderColor: Color {
        if destructive { return Color.red.opacity(0.28) }
        return selected ? Color.nuwaToggleActiveBorder : Color.nuwaControlBorder
    }
}

/// Disables iOS 26 automatic ScrollView edge tinting so sidebar & chat headers stay 100% color-uniform.
struct NuwaNoScrollEdgeEffectModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectHidden(true, for: .all)
        } else {
            content
        }
        #else
        content
        #endif
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

    func nuwaPillSurface(selected: Bool = false, destructive: Bool = false) -> some View {
        modifier(NuwaPillSurfaceModifier(selected: selected, destructive: destructive))
    }

    func nuwaNoScrollEdgeEffect() -> some View {
        modifier(NuwaNoScrollEdgeEffectModifier())
    }
}

/// Groups adjacent floating Liquid Glass chrome buttons on iOS 26.
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

/// Smooth progressive frosted blur + soft background fade for chat top & bottom edges (iOS 17-18 fallback;
/// iOS 26+ uses native `.safeAreaBar` + `UIScrollEdgeEffect.Style.soft`).
/// Uses native SwiftUI Materials (never masked `UIVisualEffectView`, which breaks backdrop blur on iOS).
struct ProgressiveEdgeBlur: View {
    enum EdgePosition {
        case top
        case bottom
    }

    let edge: EdgePosition
    let baseColor: Color

    private var startPoint: UnitPoint { edge == .top ? .top : .bottom }
    private var endPoint: UnitPoint { edge == .top ? .bottom : .top }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .mask {
                    LinearGradient(
                        stops: outerBlurMaskStops,
                        startPoint: startPoint,
                        endPoint: endPoint
                    )
                }

            Rectangle()
                .fill(.thinMaterial)
                .mask {
                    LinearGradient(
                        stops: innerBlurMaskStops,
                        startPoint: startPoint,
                        endPoint: endPoint
                    )
                }

            LinearGradient(
                stops: tintFadeStops,
                startPoint: startPoint,
                endPoint: endPoint
            )
        }
        .allowsHitTesting(false)
    }

    private var outerBlurMaskStops: [Gradient.Stop] {
        [
            .init(color: .black, location: 0.0),
            .init(color: .black.opacity(0.92), location: 0.50),
            .init(color: .black.opacity(0.55), location: 0.74),
            .init(color: .black.opacity(0.18), location: 0.90),
            .init(color: .black.opacity(0.0), location: 1.0),
        ]
    }

    private var innerBlurMaskStops: [Gradient.Stop] {
        [
            .init(color: .black, location: 0.0),
            .init(color: .black.opacity(0.76), location: 0.42),
            .init(color: .black.opacity(0.24), location: 0.68),
            .init(color: .black.opacity(0.0), location: 0.86),
        ]
    }

    private var tintFadeStops: [Gradient.Stop] {
        [
            .init(color: baseColor.opacity(0.68), location: 0.0),
            .init(color: baseColor.opacity(0.36), location: 0.45),
            .init(color: baseColor.opacity(0.08), location: 0.76),
            .init(color: baseColor.opacity(0.0), location: 1.0),
        ]
    }
}
