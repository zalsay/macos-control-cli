import AppKit
import SwiftUI

// MARK: - 亮银铂金与高透液态玻璃设计系统 (Metallic & Crystal Liquid Glass Theme)

public enum MetallicTheme {
    /// 亮银铂金核心强调色 (Bright Platinum / Silver Specular Accent)
    public static let accent = Color(red: 0xE6 / 255.0, green: 0xEE / 255.0, blue: 0xFA / 255.0)

    /// 纯钛镜面高光 (Specular Platinum)
    public static let specularLight = Color(red: 0xFC / 255.0, green: 0xFD / 255.0, blue: 0xFF / 255.0)

    /// 亮金属拉丝银 (Bright Brushed Silver)
    public static let brushedSilver = Color(red: 0xD8 / 255.0, green: 0xE2 / 255.0, blue: 0xF0 / 255.0)

    /// 精密银灰过渡色 (Refined Silver Mid)
    public static let steelMid = Color(red: 0xC4 / 255.0, green: 0xD0 / 255.0, blue: 0xE2 / 255.0)

    /// 金属按钮主文字颜色（深邃钛黑蓝灰，对齐预览图中的「新建环境 +」高对比蚀刻文字）
    public static let darkText = Color(red: 0x16 / 255.0, green: 0x1C / 255.0, blue: 0x26 / 255.0)

    /// 常态：亮银铂金金属光泽渐变（两端色差极小，具备多段拉丝金属高光带）
    public static var prominentGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: Color(red: 0xDC / 255.0, green: 0xE4 / 255.0, blue: 0xF0 / 255.0), location: 0.00),
                .init(color: Color(red: 0xF5 / 255.0, green: 0xF8 / 255.0, blue: 0xFD / 255.0), location: 0.22),
                .init(color: Color.white, location: 0.34),
                .init(color: Color(red: 0xE2 / 255.0, green: 0xEA / 255.0, blue: 0xF5 / 255.0), location: 0.54),
                .init(color: Color(red: 0xF2 / 255.0, green: 0xF6 / 255.0, blue: 0xFC / 255.0), location: 0.74),
                .init(color: Color(red: 0xD6 / 255.0, green: 0xDF / 255.0, blue: 0xED / 255.0), location: 1.00)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// 悬停态：高亮镜面铂金金属光泽渐变（更强的纯白高光反射带与极小首尾色差）
    public static var prominentHoverGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: Color(red: 0xE6 / 255.0, green: 0xEE / 255.0, blue: 0xF8 / 255.0), location: 0.00),
                .init(color: Color.white, location: 0.25),
                .init(color: Color.white, location: 0.38),
                .init(color: Color(red: 0xEC / 255.0, green: 0xF2 / 255.0, blue: 0xFB / 255.0), location: 0.56),
                .init(color: Color.white, location: 0.76),
                .init(color: Color(red: 0xE0 / 255.0, green: 0xE9 / 255.0, blue: 0xF6 / 255.0), location: 1.00)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// 各向异性拉丝金属锥形反光层（还原预览图中的放射状金属拉丝光泽）
    public static func anisotropicSheen(isHovered: Bool = false) -> AngularGradient {
        let peak = Color.white.opacity(isHovered ? 0.65 : 0.45)
        let valley = Color(red: 0xB8 / 255.0, green: 0xC6 / 255.0, blue: 0xDC / 255.0).opacity(isHovered ? 0.22 : 0.28)
        let mid = Color(red: 0xE4 / 255.0, green: 0xEC / 255.0, blue: 0xF7 / 255.0).opacity(isHovered ? 0.15 : 0.12)
        return AngularGradient(
            stops: [
                .init(color: mid, location: 0.00),
                .init(color: peak, location: 0.12),
                .init(color: valley, location: 0.25),
                .init(color: peak, location: 0.38),
                .init(color: mid, location: 0.50),
                .init(color: peak, location: 0.64),
                .init(color: valley, location: 0.78),
                .init(color: peak, location: 0.90),
                .init(color: mid, location: 1.00)
            ],
            center: .center,
            angle: .degrees(-28)
        )
    }

    /// 外圈 CNC 车削金属高光边框渐变（对齐预览图中的双层金属外环）
    public static var metallicRimBorder: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: Color.white, location: 0.00),
                .init(color: Color(red: 0xB8 / 255.0, green: 0xC6 / 255.0, blue: 0xDA / 255.0), location: 0.22),
                .init(color: Color.white.opacity(0.95), location: 0.48),
                .init(color: Color(red: 0x9A / 255.0, green: 0xAA / 255.0, blue: 0xC0 / 255.0), location: 0.74),
                .init(color: Color(red: 0xF0 / 255.0, green: 0xF5 / 255.0, blue: 0xFC / 255.0), location: 1.00)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// 内圈 CNC 凹槽倒角描边（形成预览图中外圈金属环与内层面板的立体分层）
    public static var metallicInnerBevel: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: Color(red: 0x8C / 255.0, green: 0x9C / 255.0, blue: 0xB4 / 255.0).opacity(0.55), location: 0.00),
                .init(color: Color.white.opacity(0.90), location: 0.35),
                .init(color: Color(red: 0x96 / 255.0, green: 0xA6 / 255.0, blue: 0xBE / 255.0).opacity(0.50), location: 0.70),
                .init(color: Color.white.opacity(0.85), location: 1.00)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// 浅灰金属卡片徽章描边
    public static var badgeStroke: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: Color.white.opacity(0.90), location: 0.0),
                .init(color: accent.opacity(0.65), location: 0.5),
                .init(color: Color.white.opacity(0.35), location: 1.0)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// 根据外观模式自适应图标颜色
    public static func iconColor(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0xEC / 255.0, green: 0xF2 / 255.0, blue: 0xFA / 255.0)
            : Color(red: 0x2C / 255.0, green: 0x35 / 255.0, blue: 0x45 / 255.0)
    }

    /// 控制栏与主卡片背景色 (#0C1018 / #E8EEF6)
    public static func chromeBackground(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0x0C / 255.0, green: 0x10 / 255.0, blue: 0x18 / 255.0)
            : Color(red: 0xE8 / 255.0, green: 0xEE / 255.0, blue: 0xF6 / 255.0)
    }

    /// 控制栏与主卡片半透明度 (Dark: 0.28, Light: 0.25)
    public static func chromeOpacity(for scheme: ColorScheme) -> Double {
        scheme == .dark ? 0.28 : 0.25
    }

    /// 贴近当前控制栏背景色的卡片边框颜色渐变 (Dark: #202A3C -> #0E131D, Light: #D6DEEA -> #C6D0DF)
    public static func chromeBorder(for scheme: ColorScheme) -> LinearGradient {
        scheme == .dark
            ? LinearGradient(
                stops: [
                    .init(color: Color(red: 0x20 / 255.0, green: 0x2A / 255.0, blue: 0x3C / 255.0).opacity(0.85), location: 0.0),
                    .init(color: Color(red: 0x0E / 255.0, green: 0x13 / 255.0, blue: 0x1D / 255.0).opacity(0.75), location: 1.0)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            : LinearGradient(
                stops: [
                    .init(color: Color(red: 0xD6 / 255.0, green: 0xDE / 255.0, blue: 0xEA / 255.0).opacity(0.95), location: 0.0),
                    .init(color: Color(red: 0xC6 / 255.0, green: 0xD0 / 255.0, blue: 0xDF / 255.0).opacity(0.85), location: 1.0)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
    }
}

// MARK: - 原生 macOS 视觉效果背景 (NSVisualEffectView 桥接)

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

// MARK: - 深邃液态金属流光底衬 (Ambient Liquid Metal Backdrop - 严格还原预览图背景)

/// 还原预览图中的深邃黑曜石蓝黑基底与立体液态金属流光曲面，为高透明度玻璃卡片提供通透的底层光影折射。
struct AmbientLiquidBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if colorScheme == .dark {
                // 1. 深邃黑曜石冷调基底 (#05080F -> #080D17)，隔离桌面暖色壁纸串色
                LinearGradient(
                    colors: [
                        Color(red: 0x05 / 255.0, green: 0x08 / 255.0, blue: 0x0E / 255.0),
                        Color(red: 0x08 / 255.0, green: 0x0D / 255.0, blue: 0x16 / 255.0),
                        Color(red: 0x04 / 255.0, green: 0x06 / 255.0, blue: 0x0B / 255.0)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                // 2. 立体液态金属流光波纹（还原预览图中玻璃面板背后的银蓝液态金属折光绸带）
                GeometryReader { proxy in
                    let w = proxy.size.width
                    let h = proxy.size.height

                    ZStack {
                        // 左上至中下：主液态银蓝曲面高光绸带
                        Ellipse()
                            .fill(
                                LinearGradient(
                                    stops: [
                                        .init(color: Color(red: 0x7A / 255.0, green: 0x96 / 255.0, blue: 0xB8 / 255.0).opacity(0.28), location: 0.0),
                                        .init(color: Color(red: 0x38 / 255.0, green: 0x4E / 255.0, blue: 0x6B / 255.0).opacity(0.18), location: 0.45),
                                        .init(color: Color.clear, location: 1.0)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: w * 0.75, height: h * 0.55)
                            .rotationEffect(.degrees(-28))
                            .position(x: w * 0.26, y: h * 0.24)
                            .blur(radius: 38)

                        // 左上流光锐利高光脊线
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0xB8 / 255.0, green: 0xCE / 255.0, blue: 0xEB / 255.0).opacity(0.22),
                                        Color(red: 0x4A / 255.0, green: 0x62 / 255.0, blue: 0x82 / 255.0).opacity(0.08),
                                        Color.clear
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: w * 0.55, height: h * 0.16)
                            .rotationEffect(.degrees(-32))
                            .position(x: w * 0.22, y: h * 0.18)
                            .blur(radius: 22)

                        // 右上至中部：次级液态金属折光弧面
                        Ellipse()
                            .fill(
                                LinearGradient(
                                    stops: [
                                        .init(color: Color(red: 0x88 / 255.0, green: 0xA4 / 255.0, blue: 0xC6 / 255.0).opacity(0.24), location: 0.0),
                                        .init(color: Color(red: 0x28 / 255.0, green: 0x3A / 255.0, blue: 0x52 / 255.0).opacity(0.14), location: 0.55),
                                        .init(color: Color.clear, location: 1.0)
                                    ],
                                    startPoint: .topTrailing,
                                    endPoint: .bottomLeading
                                )
                            )
                            .frame(width: w * 0.68, height: h * 0.50)
                            .rotationEffect(.degrees(-22))
                            .position(x: w * 0.78, y: h * 0.36)
                            .blur(radius: 42)

                        // 右下与底部：深海银钛环境漫反射弧光
                        Ellipse()
                            .fill(
                                RadialGradient(
                                    colors: [
                                        Color(red: 0x4E / 255.0, green: 0x68 / 255.0, blue: 0x8A / 255.0).opacity(0.22),
                                        Color(red: 0x1A / 255.0, green: 0x26 / 255.0, blue: 0x38 / 255.0).opacity(0.10),
                                        Color.clear
                                    ],
                                    center: .center,
                                    startRadius: 0,
                                    endRadius: w * 0.42
                                )
                            )
                            .frame(width: w * 0.80, height: h * 0.60)
                            .position(x: w * 0.62, y: h * 0.86)
                            .blur(radius: 48)
                    }
                }
            } else {
                LinearGradient(
                    colors: [
                        Color(red: 0xEB / 255.0, green: 0xF0 / 255.0, blue: 0xF7 / 255.0),
                        Color(red: 0xE2 / 255.0, green: 0xE8 / 255.0, blue: 0xF2 / 255.0)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - 半透明卡片背景 (LiquidGlassBackground - 与控制栏底色与微半透明完全一致)

/// 对齐当前控制栏的半透明外壳规范：
/// 采用与控制栏完全相同的背景底色 (#0C1018 / #E8EEF6) 与半透明度 (Dark: 0.28, Light: 0.25)，
/// 边框颜色也严格贴近控制栏背景色，去除突兀的亮白反光与高反差描边，与整体深色钛金外观完全融合。
struct LiquidGlassBackground: View {
    var radius: CGFloat = 16
    var tintColor: Color? = nil
    var interactive: Bool = false
    var showsSheen: Bool = true
    var bevelWidth: CGFloat = 1.0
    var hasShadow: Bool = true

    @Environment(\.colorScheme) private var colorScheme

    /// 与控制栏完全一致的底色 (#0C1018 / #E8EEF6)
    private var chromeBackgroundColor: Color {
        MetallicTheme.chromeBackground(for: colorScheme)
    }

    /// 与控制栏完全一致的半透明度 (Dark: 0.28, Light: 0.25)
    private var chromeOpacity: Double {
        MetallicTheme.chromeOpacity(for: colorScheme)
    }

    /// 贴近当前控制栏背景色的卡片边框颜色渐变
    private var cardBorderColor: LinearGradient {
        MetallicTheme.chromeBorder(for: colorScheme)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        ZStack {
            // Layer 1: 原生半透明光学微磨砂层
            shape
                .fill(.regularMaterial)
                .opacity(colorScheme == .dark ? 0.35 : 0.45)

            // Layer 2: 与控制栏完全相同的背景底色与半透明度
            shape
                .fill(chromeBackgroundColor.opacity(chromeOpacity))

            // Layer 2.1: 自定义局部色调（若传入）
            if let tintColor {
                shape
                    .fill(tintColor.opacity(colorScheme == .dark ? 0.08 : 0.05))
            }

            // Layer 3: 微妙的顶部微光光泽（柔和自然，不破坏与控制栏的一致感）
            if showsSheen {
                shape
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: Color.white.opacity(colorScheme == .dark ? 0.025 : 0.06), location: 0.00),
                                .init(color: Color.clear, location: 0.40)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }

            // Layer 4: 贴近当前控制栏背景色的精致细边框
            shape
                .strokeBorder(cardBorderColor, lineWidth: bevelWidth)
        }
        .contentShape(shape)
        .shadow(
            color: hasShadow
                ? (colorScheme == .dark ? Color.black.opacity(0.18) : Color.black.opacity(0.04))
                : Color.clear,
            radius: hasShadow ? 8 : 0,
            x: 0,
            y: hasShadow ? 3 : 0
        )
    }
}

// MARK: - 玻璃卡片容器 (LiquidGlassCard)

struct LiquidGlassCard<Content: View, Trailing: View>: View {
    let title: String
    let systemImage: String
    var badge: String? = nil
    var radius: CGFloat = 16
    let trailing: () -> Trailing
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var colorScheme

    init(
        title: String,
        systemImage: String,
        badge: String? = nil,
        radius: CGFloat = 16,
        @ViewBuilder trailing: @escaping () -> Trailing,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.badge = badge
        self.radius = radius
        self.trailing = trailing
        self.content = content
    }

    init(
        title: String,
        systemImage: String,
        badge: String? = nil,
        radius: CGFloat = 16,
        @ViewBuilder content: @escaping () -> Content
    ) where Trailing == EmptyView {
        self.title = title
        self.systemImage = systemImage
        self.badge = badge
        self.radius = radius
        self.trailing = { EmptyView() }
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MetallicTheme.iconColor(for: colorScheme))
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(colorScheme == .dark ? 0.07 : 0.45))
                            .overlay(
                                Circle().stroke(
                                    LinearGradient(
                                        colors: [Color.white.opacity(0.45), Color.white.opacity(0.10)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 0.7
                                )
                            )
                    )

                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))

                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MetallicTheme.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.06))
                                .overlay(Capsule().stroke(MetallicTheme.badgeStroke, lineWidth: 0.6))
                        )
                }

                Spacer()

                trailing()
            }

            content()
        }
        .padding(18)
        .background(
            LiquidGlassBackground(radius: radius, bevelWidth: 1.0)
        )
    }
}

// MARK: - 金属与高透玻璃质感按钮 (LiquidGlassButton - 严格还原预览图按钮样式)

struct LiquidGlassButton: View {
    enum Variant {
        case regular
        case prominent
        case destructive
    }

    let title: String
    let systemImage: String?
    var variant: Variant = .regular
    var size: ControlSize = .regular
    var minWidth: CGFloat? = nil
    var action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: iconSize, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: fontSize, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(minWidth: minWidth)
            .background(
                buttonBackground
            )
            .scaleEffect(isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.16), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var fontSize: CGFloat {
        switch size {
        case .mini, .small: return 11.5
        case .regular: return 13
        case .large, .extraLarge: return 14.5
        @unknown default: return 13
        }
    }

    private var iconSize: CGFloat {
        switch size {
        case .mini, .small: return 10.5
        case .regular: return 12
        case .large, .extraLarge: return 13.5
        @unknown default: return 12
        }
    }

    private var horizontalPadding: CGFloat {
        switch size {
        case .mini, .small: return 12
        case .regular: return 16
        case .large, .extraLarge: return 22
        @unknown default: return 16
        }
    }

    private var verticalPadding: CGFloat {
        switch size {
        case .mini, .small: return 5
        case .regular: return 8
        case .large, .extraLarge: return 11
        @unknown default: return 8
        }
    }

    private var foregroundColor: Color {
        switch variant {
        case .prominent: return MetallicTheme.darkText
        case .destructive: return Color(red: 0xFF / 255.0, green: 0x5A / 255.0, blue: 0x5A / 255.0)
        case .regular: return .primary
        }
    }

    @ViewBuilder
    private var buttonBackground: some View {
        let shape = Capsule()
        ZStack {
            switch variant {
            case .prominent:
                // 1. 外圈 CNC 金属底座环 (Outer Machined Metal Ring)
                shape
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: Color.white, location: 0.0),
                                .init(color: Color(red: 0xB4 / 255.0, green: 0xC2 / 255.0, blue: 0xD6 / 255.0), location: 0.28),
                                .init(color: Color(red: 0xF0 / 255.0, green: 0xF5 / 255.0, blue: 0xFC / 255.0), location: 0.55),
                                .init(color: Color(red: 0x92 / 255.0, green: 0xA2 / 255.0, blue: 0xB8 / 255.0), location: 0.80),
                                .init(color: Color(red: 0xE6 / 255.0, green: 0xEE / 255.0, blue: 0xFA / 255.0), location: 1.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                // 2. 内层亮银铂金主面板 (Inner Brushed Platinum Face，内缩 2pt 形成预览图的双层金属边框)
                let innerShape = shape.inset(by: 2.0)
                innerShape
                    .fill(isHovered ? MetallicTheme.prominentHoverGradient : MetallicTheme.prominentGradient)

                // 3. 放射状拉丝金属光泽叠加层 (Anisotropic Radial Brushed Sheen)
                innerShape
                    .fill(MetallicTheme.anisotropicSheen(isHovered: isHovered))

                // 4. 顶部对角镜面高光带 (Specular Reflection Band)
                innerShape
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: Color.white.opacity(isHovered ? 0.65 : 0.42), location: 0.00),
                                .init(color: Color.white.opacity(isHovered ? 0.85 : 0.55), location: 0.24),
                                .init(color: Color.clear, location: 0.48),
                                .init(color: Color(red: 0xC8 / 255.0, green: 0xD6 / 255.0, blue: 0xEB / 255.0).opacity(0.25), location: 0.78),
                                .init(color: Color.white.opacity(isHovered ? 0.50 : 0.30), location: 1.00)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                // 5. 内层凹槽车削线与外层高光圈描边
                innerShape
                    .strokeBorder(MetallicTheme.metallicInnerBevel, lineWidth: 0.8)

                shape
                    .strokeBorder(MetallicTheme.metallicRimBorder, lineWidth: 1.1)

            case .destructive:
                shape
                    .fill(Color(red: 0xEB / 255.0, green: 0x47 / 255.0, blue: 0x47 / 255.0).opacity(isHovered ? 0.22 : 0.12))
                shape
                    .strokeBorder(Color(red: 0xFF / 255.0, green: 0x60 / 255.0, blue: 0x60 / 255.0).opacity(isHovered ? 0.65 : 0.38), lineWidth: 0.9)

            case .regular:
                shape
                    .fill(Color(red: 0x10 / 255.0, green: 0x17 / 255.0, blue: 0x24 / 255.0).opacity(colorScheme == .dark ? (isHovered ? 0.48 : 0.32) : 0.15))
                shape
                    .fill(isHovered ? Color.white.opacity(colorScheme == .dark ? 0.10 : 0.30) : Color.white.opacity(0.03))
                shape
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: Color.white.opacity(colorScheme == .dark ? 0.50 : 0.85), location: 0.0),
                                .init(color: Color(red: 0x9A / 255.0, green: 0xB2 / 255.0, blue: 0xD2 / 255.0).opacity(0.25), location: 0.5),
                                .init(color: Color.white.opacity(colorScheme == .dark ? 0.15 : 0.25), location: 1.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.9
                    )
            }
        }
        // 还原预览图中的金属边缘柔光光晕（常态柔和立体投影，悬停态绽放银白星芒柔光）
        .shadow(
            color: variant == .prominent
                ? Color(red: 0xDC / 255.0, green: 0xEA / 255.0, blue: 0xFF / 255.0).opacity(isHovered ? 0.55 : 0.16)
                : Color.clear,
            radius: isHovered ? 12 : 4,
            x: 0,
            y: 0
        )
        .shadow(
            color: Color.black.opacity(variant == .prominent ? 0.42 : 0.22),
            radius: isHovered ? 8 : 5,
            x: 0,
            y: isHovered ? 4 : 2
        )
    }
}
