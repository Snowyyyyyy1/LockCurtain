import SwiftUI
import UIKit

/// What the Mac screen is showing. Timeout and open both show the desktop.
enum MacScreenState: Equatable {
    case desktop
    case closing
    case curtain
    /// 现在撤下 sent: the curtain is half up, waiting for the Mac
    case lifting
    case empty

    fileprivate var curtainFraction: CGFloat {
        switch self {
        case .desktop, .empty: 0
        case .closing: 0.55
        case .lifting: 0.45
        case .curtain: 1
        }
    }
}

/// The one custom drawing in the app: a Mac drawn with SwiftUI shapes and a
/// Canvas, never an image. The brand orange only appears inside this picture
/// when the curtain is fully down.
struct MacScreenIllustration: View {
    let state: MacScreenState
    var showsDemoBadge = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var curtainFraction: CGFloat
    @State private var eyeVisible: Bool

    private static let designSize = CGSize(width: 300, height: 190)
    private static let screenSize = CGSize(width: 236, height: 148)

    init(state: MacScreenState, showsDemoBadge: Bool = false) {
        self.state = state
        self.showsDemoBadge = showsDemoBadge
        _curtainFraction = State(initialValue: state.curtainFraction)
        _eyeVisible = State(initialValue: state == .curtain)
    }

    private var illustrationHeight: CGFloat {
        if dynamicTypeSize >= .accessibility1 { return 120 }
        if dynamicTypeSize >= .xxLarge { return 170 }
        return 220
    }

    var body: some View {
        GeometryReader { proxy in
            let scale = min(
                proxy.size.width / Self.designSize.width,
                proxy.size.height / Self.designSize.height
            )
            drawing
                .frame(width: Self.designSize.width, height: Self.designSize.height)
                .scaleEffect(scale)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(maxWidth: .infinity)
        .frame(height: illustrationHeight)
        .accessibilityHidden(true)
        .onChange(of: state) { oldState, newState in
            update(for: newState, from: oldState)
        }
        .onChange(of: reduceMotion) { _, _ in
            update(for: state, animated: false)
        }
    }

    // MARK: - Drawing

    private var drawing: some View {
        ZStack(alignment: .topLeading) {
            macBase
                .offset(x: 2, y: 178)

            Capsule()
                .fill(Self.al3)
                .frame(width: 44, height: 3.5)
                .offset(x: 128, y: 182)

            RoundedRectangle(cornerRadius: 11)
                .fill(Color(red: 0x0B / 255.0, green: 0x0B / 255.0, blue: 0x0D / 255.0))
                .frame(width: 250, height: 162)
                .overlay {
                    RoundedRectangle(cornerRadius: 11)
                        .strokeBorder(Self.al2, lineWidth: 1.2)
                }
                .offset(x: 25, y: 9)

            screen
                .frame(width: Self.screenSize.width, height: Self.screenSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .offset(x: 32, y: 16)
        }
        .frame(width: Self.designSize.width, height: Self.designSize.height)
    }

    private var screen: some View {
        ZStack {
            if state == .empty {
                Color(.tertiarySystemFill)
            } else {
                desktop

                curtain
                    .mask(alignment: .top) {
                        Rectangle()
                            .frame(height: Self.screenSize.height * curtainFraction)
                    }

                curtainEdge

                eye
                    .opacity(eyeVisible ? 1 : 0)
            }
        }
        .overlay(alignment: .topLeading) {
            if showsDemoBadge {
                Text("演示")
                    .font(.caption2.bold())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.orange, in: .rect(cornerRadius: 6))
                    .foregroundStyle(.black)
                    .fixedSize()
                    .padding(8)
            }
        }
    }

    private var screenGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0x9D / 255.0, green: 0xB7 / 255.0, blue: 0xE8 / 255.0),
                Color(red: 0xB9 / 255.0, green: 0xA9 / 255.0, blue: 0xE0 / 255.0),
                Color(red: 0xE7 / 255.0, green: 0xB8 / 255.0, blue: 0xC8 / 255.0)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var desktop: some View {
        ZStack(alignment: .topLeading) {
            screenGradient

            RoundedRectangle(cornerRadius: 7)
                .fill(.white.opacity(0.88))
                .frame(width: 118, height: 82)
                .offset(x: 24, y: 22)

            RoundedRectangle(cornerRadius: 7)
                .fill(.white.opacity(0.6))
                .frame(width: 96, height: 72)
                .offset(x: 118, y: 52)

            Rectangle()
                .fill(.white.opacity(0.55))
                .frame(height: 7)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(width: Self.screenSize.width, height: Self.screenSize.height)
    }

    private var curtain: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [
                    Color(red: 0x05 / 255.0, green: 0x06 / 255.0, blue: 0x1A / 255.0),
                    Color(red: 0x0D / 255.0, green: 0x10 / 255.0, blue: 0x30 / 255.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            Canvas { context, _ in
                for star in Self.stars {
                    let rect = CGRect(
                        x: star.x - star.radius,
                        y: star.y - star.radius,
                        width: star.radius * 2,
                        height: star.radius * 2
                    )
                    context.fill(
                        Path(ellipseIn: rect),
                        with: .color(.white.opacity(star.opacity))
                    )
                }
            }
            .frame(width: Self.screenSize.width, height: Self.screenSize.height)
        }
        .frame(width: Self.screenSize.width, height: Self.screenSize.height, alignment: .top)
    }

    private var curtainEdge: some View {
        Rectangle()
            .fill(
                Color(red: 0xFF / 255.0, green: 0xB0 / 255.0, blue: 0x6A / 255.0)
                    .opacity(0.55)
            )
            .frame(width: Self.screenSize.width, height: 1.2)
            .offset(y: Self.screenSize.height * curtainFraction - 1.2)
            .opacity(curtainFraction > 0.001 ? 1 : 0)
            .frame(maxHeight: .infinity, alignment: .top)
    }

    private var eye: some View {
        ZStack {
            Circle()
                .fill(Self.brand.opacity(0.25))
                .frame(width: 32, height: 32)
            Circle()
                .fill(Self.brand)
                .frame(width: 22, height: 22)
            Circle()
                .strokeBorder(Self.brandRing, lineWidth: 1.4)
                .frame(width: 22, height: 22)
            Circle()
                .fill(Self.brandPupil)
                .frame(width: 7.2, height: 7.2)
        }
    }

    private var macBase: some View {
        MacBaseShape()
            .fill(
                LinearGradient(
                    colors: [Self.al1, Self.al2],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 296, height: 12)
    }

    // MARK: - State changes

    private func update(for newState: MacScreenState, from oldState: MacScreenState? = nil, animated: Bool = true) {
        let target = newState.curtainFraction
        let showEye = newState == .curtain
        guard animated && !reduceMotion else {
            curtainFraction = target
            eyeVisible = showEye
            return
        }
        if newState == .lifting {
            // eye fades out quickly, curtain rises to 45% and holds
            withAnimation(.easeInOut(duration: 0.2)) { eyeVisible = false }
            withAnimation(.easeInOut(duration: 0.6)) { curtainFraction = target }
            return
        }
        if oldState == .lifting, newState == .desktop {
            // lifted: the rest of the curtain goes up, revealing the desktop
            withAnimation(.easeIn(duration: 0.35)) { curtainFraction = target }
            eyeVisible = false
            return
        }
        withAnimation(.easeInOut(duration: 0.6)) {
            curtainFraction = target
        }
        withAnimation(.easeInOut(duration: 0.25)) {
            eyeVisible = showEye
        }
    }

    // MARK: - Palette and stars

    private static let brand = Color(
        red: 0xFF / 255.0,
        green: 0x8A / 255.0,
        blue: 0x1F / 255.0
    )
    private static let brandRing = Color(
        red: 0xE0 / 255.0,
        green: 0x6A / 255.0,
        blue: 0x00 / 255.0
    )
    private static let brandPupil = Color(
        red: 0x1A / 255.0,
        green: 0x0E / 255.0,
        blue: 0x00 / 255.0
    )

    private static let al1 = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x6B / 255.0, green: 0x6C / 255.0, blue: 0x71 / 255.0, alpha: 1)
            : UIColor(red: 0xE3 / 255.0, green: 0xE4 / 255.0, blue: 0xE8 / 255.0, alpha: 1)
    })
    private static let al2 = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x48 / 255.0, green: 0x49 / 255.0, blue: 0x4D / 255.0, alpha: 1)
            : UIColor(red: 0xB5 / 255.0, green: 0xB7 / 255.0, blue: 0xBD / 255.0, alpha: 1)
    })
    private static let al3 = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x3A / 255.0, green: 0x3B / 255.0, blue: 0x3F / 255.0, alpha: 1)
            : UIColor(red: 0x9C / 255.0, green: 0x9E / 255.0, blue: 0xA4 / 255.0, alpha: 1)
    })

    private struct Star {
        let x: CGFloat
        let y: CGFloat
        let radius: CGFloat
        let opacity: Double
    }

    private struct SeededRandom {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((state >> 11) & 0xFFFF_FFFF) / Double(0xFFFF_FFFF)
        }
    }

    private static let stars: [Star] = {
        var random = SeededRandom(state: 0x1C0F_FEE5)
        return (0..<70).map { _ in
            let x = CGFloat(random.next()) * screenSize.width
            let y = CGFloat(random.next()) * screenSize.height
            let size = random.next()
            let radius: CGFloat
            if size < 0.5 {
                radius = 0.45
            } else if size < 0.83 {
                radius = 0.7
            } else {
                radius = 1.1
            }
            let opacity = 0.35 + random.next() * 0.65
            return Star(x: x, y: y, radius: radius, opacity: opacity)
        }
    }()
}

/// A very slightly tapered stand with rounded bottom corners.
private struct MacBaseShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let inset: CGFloat = 6
        let radius: CGFloat = 4
        path.move(to: CGPoint(x: rect.minX + inset, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - 2, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius - 2, y: rect.maxY),
            control: CGPoint(x: rect.maxX - 2, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius + 2, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + 2, y: rect.maxY - radius),
            control: CGPoint(x: rect.minX + 2, y: rect.maxY)
        )
        path.closeSubpath()
        return path
    }
}
