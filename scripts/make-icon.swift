// 画 Safarier 的 1024×1024 图标 PNG（参考 Safari：浅色底板 + 中间深色落盘 + 主题金属色星轨与星星 + 主题金属色与红色双向罗盘指针）。
// 用法：swift scripts/make-icon.swift OUTPUT.png（build-app.sh 调用，再由 iconutil 转成 .icns）。
import AppKit
import CoreGraphics

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("用法：swift make-icon.swift OUTPUT.png\n".utf8))
    exit(64)
}

func srgb(_ hex: UInt32, _ alpha: CGFloat = 1.0) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
        green: CGFloat((hex >> 8) & 0xFF) / 255.0,
        blue: CGFloat(hex & 0xFF) / 255.0,
        alpha: alpha
    )
}

func cgColor(_ hex: UInt32, _ alpha: CGFloat = 1.0) -> CGColor {
    srgb(hex, alpha).cgColor
}

func renderCanvas(size: Int = 1024, draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    let nsCtx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = nsCtx
    let cg = nsCtx.cgContext
    cg.setAllowsAntialiasing(true)
    cg.setShouldAntialias(true)
    cg.interpolationQuality = .high
    draw(cg)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// 绘制浅色陶瓷 / 铝合金圆角底板（参考 Safari / macOS 系统质感）
func drawLightSquircleBase(_ cg: CGContext) -> CGPath {
    let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: rect, cornerWidth: 185.4, cornerHeight: 185.4, transform: nil)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // 1. 底层标准 macOS Dock 阴影
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -18), blur: 36, color: srgb(0x000000, 0.24).cgColor)
    cg.setFillColor(cgColor(0xCBD5E1))
    cg.addPath(path)
    cg.fillPath()
    cg.restoreGState()

    // 2. 剪裁到圆角矩形内部进行浅色陶瓷质感渲染
    cg.saveGState()
    cg.addPath(path)
    cg.clip()

    // 2.1 浅色底基渐变（自顶向下微微渐变：纯白 -> 极浅冷灰 -> 浅冷银）
    let baseColors: [CGColor] = [
        cgColor(0xFFFFFF, 1.00), // 顶部微高光
        cgColor(0xF8FAFC, 1.00),
        cgColor(0xF1F5F9, 1.00),
        cgColor(0xE2E8F0, 1.00)  // 底部自然承重冷灰
    ]
    let baseLocations: [CGFloat] = [0.0, 0.35, 0.70, 1.0]
    let baseGrad = CGGradient(colorsSpace: space, colors: baseColors as CFArray, locations: baseLocations)!
    cg.drawLinearGradient(
        baseGrad,
        start: CGPoint(x: 512, y: 924),
        end: CGPoint(x: 512, y: 100),
        options: []
    )

    // 2.2 顶部柔和弧形漫反射高光（凸面陶瓷质感）
    let topRadial = CGGradient(
        colorsSpace: space,
        colors: [cgColor(0xFFFFFF, 0.70), cgColor(0xFFFFFF, 0.20), cgColor(0xF8FAFC, 0.0)] as CFArray,
        locations: [0.0, 0.45, 1.0]
    )!
    cg.drawRadialGradient(
        topRadial,
        startCenter: CGPoint(x: 512, y: 880), startRadius: 0,
        endCenter: CGPoint(x: 512, y: 880), endRadius: 460,
        options: [.drawsAfterEndLocation]
    )

    // 2.3 微妙对角线环境光感
    let diagGrad = CGGradient(
        colorsSpace: space,
        colors: [cgColor(0xFFFFFF, 0.35), cgColor(0xE2E8F0, 0.0)] as CFArray,
        locations: [0.0, 1.0]
    )!
    cg.drawLinearGradient(
        diagGrad,
        start: CGPoint(x: 100, y: 924),
        end: CGPoint(x: 924, y: 100),
        options: []
    )

    cg.restoreGState()

    // 3. 精密倒角边框（苹果风格微边框）
    // 3.1 外层微边线
    cg.saveGState()
    cg.setStrokeColor(cgColor(0x94A3B8, 0.45))
    cg.setLineWidth(1.5)
    cg.addPath(path)
    cg.strokePath()
    cg.restoreGState()

    // 3.2 顶部内边高光线
    cg.saveGState()
    let innerRect = rect.insetBy(dx: 1.5, dy: 1.5)
    let innerPath = CGPath(roundedRect: innerRect, cornerWidth: 184, cornerHeight: 184, transform: nil)
    cg.setStrokeColor(cgColor(0xFFFFFF, 0.85))
    cg.setLineWidth(1.5)
    cg.addPath(innerPath)
    cg.strokePath()
    cg.restoreGState()

    return path
}

/// 绘制深色落盘（中间下沉式暗色金属 / 宇宙黑罗盘盘体）
func drawSunkenDarkDial(_ cg: CGContext, center: CGPoint, radius: CGFloat) -> CGRect {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let dialRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)

    // 1. 外部下沉阴影与金属倒角凹槽（模拟落盘沉入浅色外壳的深度）
    // 1.1 盘体底部光泽切边（模拟浅色外壳下边缘被光线照亮）
    cg.saveGState()
    cg.setStrokeColor(cgColor(0xFFFFFF, 0.95))
    cg.setLineWidth(2.5)
    cg.strokeEllipse(in: dialRect.offsetBy(dx: 0, dy: -2.0))
    cg.restoreGState()

    // 1.2 外层机械沉槽线
    cg.saveGState()
    cg.setStrokeColor(cgColor(0x64748B, 0.50))
    cg.setLineWidth(2.0)
    cg.strokeEllipse(in: dialRect.insetBy(dx: -1.0, dy: -1.0))
    cg.restoreGState()

    // 2. 落盘内部深度渲染
    cg.saveGState()
    cg.addEllipse(in: dialRect)
    cg.clip()

    // 2.1 深邃黑曜石渐变底色（0x111827 -> 0x090D16 -> 0x030712）
    let dialGrad = CGGradient(
        colorsSpace: space,
        colors: [
            cgColor(0x111827, 1.00), // 顶部略带深黑灰
            cgColor(0x090D16, 1.00), // 中段纯净深邃黑
            cgColor(0x030712, 1.00)  // 底部深黑
        ] as CFArray,
        locations: [0.0, 0.50, 1.0]
    )!
    cg.drawLinearGradient(
        dialGrad,
        start: CGPoint(x: center.x, y: center.y + radius),
        end: CGPoint(x: center.x, y: center.y - radius),
        options: []
    )

    // 2.2 中心主题亮银铂金金属微漫反射（0xD8E2F0 / 0x94A3B8 微漫射，使星星更通透生动）
    let nebulaGrad = CGGradient(
        colorsSpace: space,
        colors: [
            cgColor(0xD8E2F0, 0.16),
            cgColor(0x94A3B8, 0.06),
            cgColor(0x030712, 0.00)
        ] as CFArray,
        locations: [0.0, 0.50, 1.0]
    )!
    cg.drawRadialGradient(
        nebulaGrad,
        startCenter: center, startRadius: 0,
        endCenter: center, endRadius: radius * 0.95,
        options: []
    )

    // 2.3 顶部内阴影（落盘顶檐遮挡下沉形成的内阴影，强化物理落差深度）
    let innerShadowGrad = CGGradient(
        colorsSpace: space,
        colors: [
            cgColor(0x000000, 0.85),
            cgColor(0x000000, 0.45),
            cgColor(0x000000, 0.00)
        ] as CFArray,
        locations: [0.0, 0.15, 0.40]
    )!
    cg.drawLinearGradient(
        innerShadowGrad,
        start: CGPoint(x: center.x, y: center.y + radius),
        end: CGPoint(x: center.x, y: center.y),
        options: []
    )

    // 2.4 内壁一圈极细深色阴影环
    cg.setStrokeColor(cgColor(0x000000, 0.70))
    cg.setLineWidth(4.0)
    cg.strokeEllipse(in: dialRect.insetBy(dx: 2.0, dy: 2.0))

    cg.restoreGState()

    // 3. 落盘内圈边缘的主题金属高光圈（CNC 精密切边）
    cg.saveGState()
    cg.setStrokeColor(cgColor(0xD8E2F0, 0.65)) // 边缘亮银金属反光
    cg.setLineWidth(1.5)
    cg.strokeEllipse(in: dialRect.insetBy(dx: 1.0, dy: 1.0))
    cg.restoreGState()

    return dialRect
}

/// 绘制罗盘精密刻度（主题亮银金属分度）
func drawCompassTicks(
    _ cg: CGContext,
    center: CGPoint,
    radius: CGFloat,
    count: Int = 72,
    majorColor: UInt32 = 0xF8FAFC,   // 主题亮银铂金高光
    mediumColor: UInt32 = 0xD8E2F0,  // 主题拉丝银灰
    minorColor: UInt32 = 0x64748B   // 深精炼钢灰
) {
    cg.saveGState()
    for i in 0..<count {
        let angle = CGFloat(i) * (2.0 * .pi / CGFloat(count))
        let isMajor = (i % 6 == 0)
        let isMedium = (i % 2 == 0)
        let innerR = radius - (isMajor ? 26 : (isMedium ? 16 : 10))
        let outerR = radius
        let p1 = CGPoint(x: center.x + cos(angle) * innerR, y: center.y + sin(angle) * innerR)
        let p2 = CGPoint(x: center.x + cos(angle) * outerR, y: center.y + sin(angle) * outerR)

        if isMajor {
            cg.setStrokeColor(cgColor(majorColor, 0.95))
            cg.setLineWidth(4.0)
        } else if isMedium {
            cg.setStrokeColor(cgColor(mediumColor, 0.75))
            cg.setLineWidth(2.5)
        } else {
            cg.setStrokeColor(cgColor(minorColor, 0.50))
            cg.setLineWidth(1.8)
        }

        cg.setLineCap(.round)
        cg.move(to: p1)
        cg.addLine(to: p2)
        cg.strokePath()
    }
    cg.restoreGState()
}

/// 绘制星轨与主题金属色星星（多环境隔离轨道 + 发光星宿）
func drawOrbitsAndStars(_ cg: CGContext, center: CGPoint) {
    // 采用与主题完全一致的拉丝银、亮银铂金与精钢金属色
    let orbits: [(rx: CGFloat, ry: CGFloat, deg: CGFloat, orbitColor: UInt32, starColor: UInt32, dotAngle: CGFloat)] = [
        (255, 108, -28, 0xD8E2F0, 0xFCFDFF, 0.55),
        (255, 108,  32, 0xE6EEFA, 0xFCFDFF, 2.45),
        (255, 108,  92, 0xC4D0E2, 0xFCFDFF, 4.20)
    ]

    for o in orbits {
        cg.saveGState()
        cg.translateBy(x: center.x, y: center.y)
        cg.rotate(by: o.deg * .pi / 180.0)

        // 1. 轨道线条（亮银金属色拉丝微光）
        cg.saveGState()
        cg.setStrokeColor(cgColor(o.orbitColor, 0.55))
        cg.setLineWidth(4.0)
        cg.strokeEllipse(in: CGRect(x: -o.rx, y: -o.ry, width: o.rx * 2, height: o.ry * 2))
        cg.restoreGState()

        // 2. 星轨上的星星（主题金属亮钻星宿）
        let nx = cos(o.dotAngle) * o.rx
        let ny = sin(o.dotAngle) * o.ry

        // 2.1 外部亮银金属柔和发光光晕 (Specular Aura)
        cg.saveGState()
        cg.setShadow(offset: .zero, blur: 16, color: cgColor(0xE6EEFA, 0.90))
        cg.setFillColor(cgColor(0xD8E2F0, 1.0))
        cg.fillEllipse(in: CGRect(x: nx - 12, y: ny - 12, width: 24, height: 24))
        cg.restoreGState()

        // 2.2 核心璀璨白钻亮点 (Core Specular)
        cg.saveGState()
        cg.setFillColor(cgColor(0xFFFFFF, 1.0))
        cg.fillEllipse(in: CGRect(x: nx - 5, y: ny - 5, width: 10, height: 10))
        cg.restoreGState()

        cg.restoreGState()
    }
}

/// 绘制罗盘指针（红色指北 + 主题金属色指南，分面对称金属光影）
func drawCompassNeedle(
    _ cg: CGContext,
    center: CGPoint,
    length: CGFloat = 248,
    halfWidth: CGFloat = 46,
    angleDegrees: CGFloat = -42,
    northBright: UInt32 = 0xFF3B30,  // 北针亮红 (Poppy Red)
    northShaded: UInt32 = 0xBE123C,  // 北针暗红 (Deep Crimson)
    southBright: UInt32 = 0xF8FAFC,  // 南针受光面：纯净亮银铂金高光 (Bright Platinum / Silver Specular)
    southShaded: UInt32 = 0x8C9CB4,  // 南针背光面：主题拉丝钛钢阴影 (Brushed Steel Mid)
    pinColor: UInt32 = 0x0F172A,     // 中心枢轴金属外圈 (Dark Titanium)
    jewelColor: UInt32 = 0xD8E2F0    // 枢轴中心主题银宝石
) {
    cg.saveGState()
    cg.translateBy(x: center.x, y: center.y)
    cg.rotate(by: angleDegrees * .pi / 180.0)

    // 1. 指针投射到落盘上的真实立体阴影
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -14), blur: 24, color: cgColor(0x000000, 0.70))
    let shadowPath = CGMutablePath()
    shadowPath.move(to: CGPoint(x: 0, y: length))
    shadowPath.addLine(to: CGPoint(x: halfWidth, y: 0))
    shadowPath.addLine(to: CGPoint(x: 0, y: -length))
    shadowPath.addLine(to: CGPoint(x: -halfWidth, y: 0))
    shadowPath.closeSubpath()
    cg.setFillColor(cgColor(0x000000, 1.0))
    cg.addPath(shadowPath)
    cg.fillPath()
    cg.restoreGState()

    // 2. 北针红色分面（前倾指北，鲜红）
    // 2.1 北侧亮面 (左侧受光面)
    let nLeft = CGMutablePath()
    nLeft.move(to: CGPoint(x: 0, y: length))
    nLeft.addLine(to: CGPoint(x: -halfWidth, y: 0))
    nLeft.addLine(to: CGPoint(x: 0, y: 0))
    nLeft.closeSubpath()
    cg.setFillColor(cgColor(northBright))
    cg.addPath(nLeft)
    cg.fillPath()

    // 2.2 北侧暗面 (右侧背光面)
    let nRight = CGMutablePath()
    nRight.move(to: CGPoint(x: 0, y: length))
    nRight.addLine(to: CGPoint(x: halfWidth, y: 0))
    nRight.addLine(to: CGPoint(x: 0, y: 0))
    nRight.closeSubpath()
    cg.setFillColor(cgColor(northShaded))
    cg.addPath(nRight)
    cg.fillPath()

    // 3. 南针主题金属色分面（后坐指南，亮银铂金 + 拉丝钛钢）
    // 3.1 南侧亮面 (左侧受光面：纯白亮银铂金镜面高光)
    let sLeft = CGMutablePath()
    sLeft.move(to: CGPoint(x: 0, y: -length))
    sLeft.addLine(to: CGPoint(x: -halfWidth, y: 0))
    sLeft.addLine(to: CGPoint(x: 0, y: 0))
    sLeft.closeSubpath()
    cg.setFillColor(cgColor(southBright))
    cg.addPath(sLeft)
    cg.fillPath()

    // 3.2 南侧暗面 (右侧背光面：主题拉丝钢阴影面)
    let sRight = CGMutablePath()
    sRight.move(to: CGPoint(x: 0, y: -length))
    sRight.addLine(to: CGPoint(x: halfWidth, y: 0))
    sRight.addLine(to: CGPoint(x: 0, y: 0))
    sRight.closeSubpath()
    cg.setFillColor(cgColor(southShaded))
    cg.addPath(sRight)
    cg.fillPath()

    // 4. 中心机械枢轴 (Central Pivot)
    // 4.1 钛合金暗黑外圈
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -4), blur: 8, color: cgColor(0x000000, 0.60))
    cg.setFillColor(cgColor(pinColor))
    cg.fillEllipse(in: CGRect(x: -24, y: -24, width: 48, height: 48))

    // 钛合金边缘车削反光细圈
    cg.setStrokeColor(cgColor(0xFFFFFF, 0.50))
    cg.setLineWidth(1.5)
    cg.strokeEllipse(in: CGRect(x: -23, y: -23, width: 46, height: 46))

    // 4.2 枢轴中心主题金属银宝石
    cg.setFillColor(cgColor(jewelColor))
    cg.fillEllipse(in: CGRect(x: -12, y: -12, width: 24, height: 24))

    // 4.3 宝石顶部高光反光点
    cg.setFillColor(cgColor(0xFFFFFF, 0.95))
    cg.fillEllipse(in: CGRect(x: -5, y: 2, width: 8, height: 8))
    cg.restoreGState()

    cg.restoreGState()
}

// 主渲染流程
let rep = renderCanvas { cg in
    let center = CGPoint(x: 512, y: 512)

    // 1. 绘制浅色陶瓷圆角底板 (Light Squircle Base)
    let squircle = drawLightSquircleBase(cg)

    cg.saveGState()
    cg.addPath(squircle)
    cg.clip()

    // 2. 绘制中间深色落盘 (Sunken Dark Dial)
    _ = drawSunkenDarkDial(cg, center: center, radius: 320)

    // 剪裁到落盘内部渲染星轨、星星、刻度与指针
    cg.saveGState()
    let dialRect = CGRect(x: center.x - 320, y: center.y - 320, width: 640, height: 640)
    cg.addEllipse(in: dialRect)
    cg.clip()

    // 3. 绘制星轨与主题金属色星星 (Orbits and Metallic Stars)
    drawOrbitsAndStars(cg, center: center)

    // 4. 绘制罗盘刻度线 (Compass Ticks in Metallic Tones)
    drawCompassTicks(
        cg,
        center: center,
        radius: 296,
        count: 72,
        majorColor: 0xF8FAFC,
        mediumColor: 0xD8E2F0,
        minorColor: 0x64748B
    )

    // 5. 绘制罗盘指针（红色 + 主题金属色）
    drawCompassNeedle(
        cg,
        center: center,
        length: 248,
        halfWidth: 46,
        angleDegrees: -42,
        northBright: 0xFF3B30,
        northShaded: 0xBE123C,
        southBright: 0xF8FAFC,
        southShaded: 0x8C9CB4,
        pinColor: 0x0F172A,
        jewelColor: 0xD8E2F0
    )

    cg.restoreGState()
    cg.restoreGState()
}

guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("PNG 编码失败\n".utf8))
    exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
} catch {
    FileHandle.standardError.write(Data("写入 \(CommandLine.arguments[1]) 失败：\(error)\n".utf8))
    exit(1)
}
