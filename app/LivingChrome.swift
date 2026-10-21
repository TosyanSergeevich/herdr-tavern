import AppKit
import QuartzCore

// Декор — отдельный от SurfaceView слой. Его часы меняют только CALayer,
// поэтому огонь и руны не инвалидируют ни терминал, ни текст кнопок.
final class LivingChromeView: NSView {
    enum Role { case root, sidebar, body, status, tabs }

    private struct Artwork {
        static let bundled: Result<Artwork, Error> = Result { try Artwork(bundle: .main) }
        let lantern: NSImage
        let lanternBracket: NSImage

        init(bundle: Bundle) throws {
            func image(_ name: String) throws -> NSImage {
                guard let url = bundle.url(forResource: name, withExtension: "png", subdirectory: "Textures"),
                      let image = NSImage(contentsOf: url), image.isValid else {
                    throw NSError(domain: "HerdrTavern.LivingChrome", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: L("core.resources.decoration", name)])
                }
                return image
            }
            lantern = try image("LivingHangingLantern")
            lantern.size = NSSize(width: 52, height: 99)
            lanternBracket = try image("LivingLanternBracket")
            lanternBracket.size = NSSize(width: 44, height: 30)
        }
    }

    static func validateResources() throws { _ = try Artwork.bundled.get() }

    let role: Role
    private let hangingAssembly = CALayer()
    private let bracketArm = CALayer()
    private let mountingPlate = CALayer()
    private var suspensionVisible: Bool?
    private let illumination = CALayer()
    private let runeLights = [CALayer(), CALayer()]
    private var runeParticles: [TavernRuneParticlesView] = []
    private let flameContainer = CALayer()
    private let amberFlame = CAShapeLayer()
    private let goldFlame = CAShapeLayer()
    private let whiteFlame = CAShapeLayer()
    private let glass = CAGradientLayer()
    private let leftGlass = CAGradientLayer()
    private let rightGlass = CAGradientLayer()
    private let lanternHousing = CALayer()
    private var flamePaths: [CGPath] = []
    private var lanternRect = CGRect.zero
    private var glowRect = CGRect.zero
    private var lastFlameIndex = -1
    private var layersPrepared = false
    private var litMaterialBounds = CGRect.null
    private var frameArtwork: NSImage?
    private var frameArtworkRect = NSRect.zero
    private var chromeLayoutBounds = CGRect.null

    var lanternLightPoint: CGPoint {
        guard suspensionVisible == true else { return CGPoint(x: -10_000, y: -10_000) }
        return CGPoint(x: flameContainer.frame.midX, y: flameContainer.frame.midY)
    }
    init(role: Role, frame: NSRect = .zero) {
        self.role = role
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("LivingChromeView requires a role") }
    override var isOpaque: Bool { role == .sidebar || role == .status || role == .tabs }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            LivingChromeClock.shared.remove(self)
        } else {
            if !layersPrepared {
                prepareLayers()
                layersPrepared = true
            }
            LivingChromeClock.shared.add(self)
        }
        needsLayout = true
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        lanternHousing.rasterizationScale = window?.backingScaleFactor ?? 2
    }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        LivingChromeClock.shared.refresh()
    }
    override func viewDidHide() {
        super.viewDidHide()
        LivingChromeClock.shared.refresh()
    }
    override func viewDidUnhide() {
        super.viewDidUnhide()
        LivingChromeClock.shared.refresh()
    }
    deinit { LivingChromeClock.shared.remove(self) }

    fileprivate var canAnimate: Bool {
        guard role == .sidebar || role == .root,
              !isHiddenOrHasHiddenAncestor, !visibleRect.isEmpty,
              let window, window.isVisible, !window.isMiniaturized else { return false }
        if role == .sidebar && suspensionVisible != true { return false }
        return window.occlusionState.contains(.visible)
    }

    private func prepareLayers() {
        guard let layer else { return }
        let artwork = try! Artwork.bundled.get()
        if role == .sidebar {
            hangingAssembly.opacity = 0
            layer.addSublayer(hangingAssembly)
            let bracket = artwork.lanternBracket.cgImage(forProposedRect: nil, context: nil,
                                                         hints: TavernMaterials.frameHints)
            // Последние 6 pt мастера — только пластина, без диагонального подкоса.
            mountingPlate.contents = bracket
            mountingPlate.contentsRect = CGRect(x: 38.0 / 44, y: 0, width: 6.0 / 44, height: 1)
            layer.addSublayer(mountingPlate)
            bracketArm.contents = bracket
            bracketArm.contentsRect = CGRect(x: 0, y: 0, width: 38.0 / 44, height: 1)
            illumination.opacity = 0.7
            hangingAssembly.addSublayer(illumination)
            flameContainer.masksToBounds = true
            flameContainer.backgroundColor = NSColor(calibratedRed: 0.48, green: 0.20, blue: 0.025, alpha: 1).cgColor
            hangingAssembly.addSublayer(flameContainer)
            amberFlame.fillColor = NSColor(calibratedRed: 1, green: 0.28, blue: 0.025, alpha: 0.86).cgColor
            goldFlame.fillColor = NSColor(calibratedRed: 1, green: 0.61, blue: 0.08, alpha: 0.98).cgColor
            whiteFlame.fillColor = NSColor(calibratedRed: 1, green: 0.86, blue: 0.43, alpha: 1).cgColor
            for flame in [amberFlame, goldFlame, whiteFlame] {
                flame.shadowColor = NSColor.orange.cgColor
                flame.shadowOpacity = 0.7
                flame.shadowRadius = 4
                flame.shadowOffset = .zero
                flameContainer.addSublayer(flame)
            }
            flamePaths = (0..<7).map { Self.flamePath(variation: $0) }
            glass.colors = [NSColor(calibratedRed: 1, green: 0.78, blue: 0.26, alpha: 0.38).cgColor,
                            NSColor(calibratedRed: 1, green: 0.50, blue: 0.05, alpha: 0.20).cgColor,
                            NSColor(calibratedRed: 1, green: 0.88, blue: 0.48, alpha: 0.30).cgColor]
            glass.locations = [0, 0.45, 1]
            glass.startPoint = CGPoint(x: 0, y: 0)
            glass.endPoint = CGPoint(x: 1, y: 0.15)
            hangingAssembly.addSublayer(glass)
            for side in [leftGlass, rightGlass] {
                side.colors = [NSColor(calibratedRed: 0.92, green: 0.42, blue: 0.045, alpha: 1).cgColor,
                               NSColor(calibratedRed: 1, green: 0.76, blue: 0.16, alpha: 1).cgColor,
                               NSColor(calibratedRed: 0.65, green: 0.25, blue: 0.025, alpha: 1).cgColor]
                side.locations = [0, 0.5, 1]
                hangingAssembly.addSublayer(side)
            }
            lanternHousing.contents = artwork.lantern.cgImage(forProposedRect: nil, context: nil, hints: TavernMaterials.frameHints)
            lanternHousing.contentsGravity = .resizeAspect
            lanternHousing.shadowColor = NSColor.black.cgColor
            lanternHousing.shadowOpacity = 0.85
            lanternHousing.shadowRadius = 2
            lanternHousing.shadowOffset = CGSize(width: 1.5, height: -2)
            lanternHousing.shouldRasterize = true
            lanternHousing.rasterizationScale = window?.backingScaleFactor ?? 2
            hangingAssembly.addSublayer(lanternHousing)
            hangingAssembly.addSublayer(bracketArm)
        }
        if role == .root {
            for light in runeLights {
                light.contents = Self.blueHalo
                light.opacity = 0.3
                layer.addSublayer(light)
            }
            for _ in 0..<2 {
                let particles = TavernRuneParticlesView(frame: bounds)
                particles.visualScale = 0.65
                addSubview(particles)
                runeParticles.append(particles)
            }
        }
    }

    override func layout() {
        super.layout()
        guard layersPrepared, chromeLayoutBounds != bounds else { return }
        chromeLayoutBounds = bounds
        prepareFrameArtwork()
        var suspensionChanged = false
        var hadSuspensionLayout = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch role {
        case .sidebar:
            let height: CGFloat = bounds.height < 420 ? 48 : 69.3
            let scale = height / 99
            let bracketScale = height / 69.3
            let previousVisibility = suspensionVisible
            hadSuspensionLayout = previousVisibility != nil
            if bounds.width < 210 {
                suspensionVisible = false
            } else if bounds.width >= 220 {
                suspensionVisible = true
            } else if previousVisibility == nil {
                suspensionVisible = false
            }
            suspensionChanged = previousVisibility != suspensionVisible
            hangingAssembly.frame = bounds
            hangingAssembly.bounds = bounds
            let bracketRect = CGRect(x: bounds.maxX - 1.8 - 44 * bracketScale,
                                     y: bounds.maxY - 5 - 30 * bracketScale,
                                     width: 44 * bracketScale, height: 30 * bracketScale)
            bracketArm.frame = CGRect(x: bracketRect.minX, y: bracketRect.minY,
                                      width: 38 * bracketScale, height: bracketRect.height)
            mountingPlate.frame = CGRect(x: bracketRect.minX + 38 * bracketScale, y: bracketRect.minY,
                                         width: 6 * bracketScale, height: bracketRect.height)
            // Крюк и кольцо — единый ресурс; к низу кольца крепится ушко корпуса.
            // Позиции меняются напрямую: resize не раскачивает и не растягивает подвес.
            let contact = CGPoint(x: bracketRect.minX + 5 * bracketScale,
                                  y: bracketRect.maxY - 25.5 * bracketScale)
            let width = 52 * scale
            // Ушко source(29,25) перекрывает нижнюю дугу, не оставляя зазора.
            lanternRect = CGRect(x: contact.x - 29 * scale, y: contact.y - 74 * scale,
                                 width: width, height: height)
            lanternHousing.frame = lanternRect
            // Точный crop концепта 52×99 px; координаты проёмов top-down → AppKit.
            func glassRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
                CGRect(x: lanternRect.minX + width * x / 52,
                       y: lanternRect.minY + height * (99 - y - h) / 99,
                       width: width * w / 52, height: height * h / 99)
            }
            let aperture = glassRect(22, 46, 13, 27)
            leftGlass.frame = glassRect(14, 46, 5, 26)
            rightGlass.frame = glassRect(37, 46, 6, 26)
            flameContainer.frame = aperture
            glass.frame = aperture
            for (index, flame) in [amberFlame, goldFlame, whiteFlame].enumerated() {
                let scale: CGFloat = index == 0 ? 1 : (index == 1 ? 0.7 : 0.38)
                flame.bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
                flame.anchorPoint = CGPoint(x: 0.5, y: 0)
                flame.position = CGPoint(x: aperture.width * 0.5, y: 0)
                flame.transform = CATransform3DMakeScale(aperture.width * scale, aperture.height * scale, 1)
                flame.path = flamePaths[3]
            }
            lastFlameIndex = -1
            glowRect = CGRect(x: aperture.midX - 72, y: aperture.midY - 72, width: 144, height: 144)
            illumination.frame = glowRect
            if suspensionVisible == true && litMaterialBounds != bounds {
                illumination.contents = Self.woodLightmap(panel: bounds, region: glowRect,
                                                        lamp: CGPoint(x: aperture.midX, y: aperture.midY))
                litMaterialBounds = bounds
            }
        case .root:
            let corners = rootCorners
            let topCenter = runeCenter(in: corners.topRight, topRight: true)
            let bottomCenter = runeCenter(in: corners.bottomLeft, topRight: false)
            // Медальон уже часть цельной пластины мастера; живой только свет.
            runeLights[0].frame = CGRect(x: topCenter.x - 19, y: topCenter.y - 19, width: 38, height: 38)
            runeLights[1].frame = CGRect(x: bottomCenter.x - 19, y: bottomCenter.y - 19, width: 38, height: 38)
            for (particles, center) in zip(runeParticles, [topCenter, bottomCenter]) {
                particles.frame = bounds
                particles.runeCenter = CGPoint(x: center.x, y: bounds.height - center.y)
            }
        case .body, .status, .tabs: break
        }
        CATransaction.commit()
        if suspensionChanged {
            let duration = hadSuspensionLayout && window?.isVisible == true ? TavernMotion.selectionDuration : 0
            TavernMotion.animate(hangingAssembly, key: "opacity", to: Float(suspensionVisible == true ? 1 : 0),
                                 duration: duration)
        }
        needsDisplay = true
        LivingChromeClock.shared.refresh()
        updateLight(time: 0, reducedMotion: true)
    }

    fileprivate func updateLight(time: TimeInterval, reducedMotion: Bool) {
        if role == .sidebar {
            if !TavernMotion.enabled {
                TavernMotion.animate(hangingAssembly, key: "opacity",
                                     to: Float(suspensionVisible == true ? 1 : 0), duration: 0)
            }
            guard suspensionVisible == true else { return }
        }
        let t = reducedMotion ? 0 : time
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch role {
        case .sidebar:
            let flicker = reducedMotion ? 0.5 : 0.5 + 0.22 * sin(t * 7.1) + 0.16 * sin(t * 11.7 + 1.8) + 0.09 * sin(t * 19.3)
            illumination.opacity = Float(0.80 + flicker * 0.18)
            let scale = CGFloat(0.98 + flicker * 0.035)
            illumination.transform = CATransform3DMakeScale(scale, scale, 1)
            let index = reducedMotion ? 3 : Int(t * 17) % flamePaths.count
            if index != lastFlameIndex {
                amberFlame.path = flamePaths[index]
                goldFlame.path = flamePaths[(index + 2) % flamePaths.count]
                whiteFlame.path = flamePaths[(index + 4) % flamePaths.count]
                lastFlameIndex = index
            }
            amberFlame.opacity = Float(0.78 + flicker * 0.18)
            goldFlame.opacity = Float(0.87 + flicker * 0.12)
            glass.opacity = Float(0.7 + flicker * 0.3)
            leftGlass.opacity = Float(0.76 + flicker * 0.23)
            rightGlass.opacity = Float(0.71 + flicker * 0.25)
        case .root:
            let breath = reducedMotion ? 0.5 : 0.5 + 0.5 * sin(t * 1.2)
            for light in runeLights { light.opacity = Float(0.27 + breath * 0.12) }
        case .body, .status, .tabs: break
        }
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard layersPrepared, let context = NSGraphicsContext.current?.cgContext, !bounds.isEmpty else { return }
        context.saveGState()
        defer { context.restoreGState() }
        switch role {
        case .sidebar:
            drawWood(in: bounds, dirtyRect: dirtyRect)
            drawFrame()
        case .root:
            drawFrame()
        case .body:
            drawFrame()
        case .status:
            drawWood(in: bounds, dirtyRect: dirtyRect)
        case .tabs:
            drawWood(in: bounds, dirtyRect: dirtyRect)
        }
    }

    private func drawWood(in rect: NSRect, dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.11, green: 0.075, blue: 0.052, alpha: 1).setFill()
        rect.fill()
        let wood = try! TavernMaterials.bundled.get().wood
        let visible = rect.intersection(dirtyRect)
        guard !visible.isEmpty else { return }
        if role == .sidebar {
            // Вертикальное волокно, без растяжения при resize.
            let top = floor((rect.maxY - visible.maxY) / wood.size.height) * wood.size.height
            for offset in stride(from: top, to: rect.maxY - visible.minY, by: wood.size.height) {
                let height = min(wood.size.height, rect.height - offset)
                let destination = NSRect(x: rect.minX, y: rect.maxY - offset - height, width: rect.width, height: height)
                let source = NSRect(x: 0, y: wood.size.height - height, width: rect.width, height: height)
                wood.draw(in: destination, from: source, operation: .sourceOver, fraction: 1,
                          respectFlipped: true, hints: TavernMaterials.frameHints)
            }
        } else if let context = NSGraphicsContext.current?.cgContext {
            // Нижняя балка и табы вырезаны вдоль доски, а не поперёк неё.
            let first = floor((visible.minX - rect.minX) / wood.size.height) * wood.size.height
            for offset in stride(from: first, to: visible.maxX - rect.minX, by: wood.size.height) {
                let length = min(wood.size.height, rect.width - offset)
                context.saveGState()
                context.translateBy(x: rect.minX + offset, y: rect.minY)
                context.rotate(by: .pi / 2)
                wood.draw(in: NSRect(x: 0, y: -length, width: rect.height, height: length),
                          from: NSRect(x: 0, y: wood.size.height - length, width: rect.height, height: length),
                          operation: .sourceOver, fraction: 1, respectFlipped: false,
                          hints: TavernMaterials.frameHints)
                context.restoreGState()
            }
        }
    }

    private func prepareFrameArtwork() {
        let style: TavernMaterials.FrameStyle
        let edge: CGFloat
        switch role {
        case .sidebar:
            frameArtworkRect = bounds
            frameArtwork = try! TavernMaterials.bundled.get().sidebarTrimImage(size: bounds.size)
            return
        case .root:
            frameArtworkRect = NSRect(x: bounds.minX + 3.5, y: bounds.minY + 2,
                                     width: max(0, bounds.width - 7), height: max(0, bounds.height - 2))
            style = .root
            edge = 8.4
        case .body:
            frameArtworkRect = bounds
            style = .viewport
            edge = 14.7
        case .status, .tabs:
            return
        }
        guard frameArtworkRect.width > edge * 2, frameArtworkRect.height > edge * 2 else {
            frameArtwork = nil
            return
        }
        frameArtwork = try! TavernMaterials.bundled.get().frameImage(size: frameArtworkRect.size,
                                                                  edge: edge, style: style)
    }

    private func drawFrame() {
        frameArtwork?.draw(in: frameArtworkRect, from: .zero, operation: .sourceOver, fraction: 1,
                           respectFlipped: true, hints: TavernMaterials.frameHints)
    }

    private var rootCorners: (topRight: NSRect, bottomLeft: NSRect) {
        let frame = frameArtworkRect
        return (NSRect(x: frame.maxX - 48, y: frame.maxY - 48, width: 48, height: 48),
                NSRect(x: frame.minX, y: frame.minY, width: 48, height: 48))
    }

    private func runeCenter(in rect: NSRect, topRight: Bool) -> NSPoint {
        NSPoint(x: topRight ? rect.maxX - 22 : rect.minX + 19,
                y: topRight ? rect.maxY - 22 : rect.minY + 19)
    }


    private static func flamePath(variation: Int) -> CGPath {
        let tip = CGFloat(variation - 3) * 0.045
        let height: CGFloat = 0.82 + CGFloat(variation % 3) * 0.075
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0.5, y: 0.01))
        path.addCurve(to: CGPoint(x: 0.13, y: 0.35), control1: CGPoint(x: 0.17, y: 0.04), control2: CGPoint(x: 0.06, y: 0.2))
        path.addCurve(to: CGPoint(x: 0.38, y: 0.69), control1: CGPoint(x: 0.1, y: 0.51), control2: CGPoint(x: 0.35, y: 0.52))
        path.addCurve(to: CGPoint(x: 0.5 + tip, y: height), control1: CGPoint(x: 0.46, y: 0.73), control2: CGPoint(x: 0.57 + tip, y: 0.8))
        path.addCurve(to: CGPoint(x: 0.78, y: 0.45), control1: CGPoint(x: 0.68 + tip, y: 0.76), control2: CGPoint(x: 0.62, y: 0.64))
        path.addCurve(to: CGPoint(x: 0.5, y: 0.01), control1: CGPoint(x: 1, y: 0.2), control2: CGPoint(x: 0.79, y: 0.02))
        path.closeSubpath()
        return path
    }

    // Декодированное дерево общее для окон. Lightmap повторяет тот же native-size
    // crop, что drawWood: цвет волокон становится albedo, перепады — normal map.
    private final class WoodSamples {
        let context: CGContext
        let width: Int
        let height: Int
        let pointSize: NSSize
        let pixels: UnsafeMutablePointer<UInt8>

        init() {
            let wood = try! TavernMaterials.bundled.get().wood
            let image = wood.cgImage(forProposedRect: nil, context: nil, hints: TavernMaterials.frameHints)!
            width = image.width
            height = image.height
            pointSize = wood.size
            let bitmap = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                   bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            bitmap.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
            context = bitmap
            pixels = bitmap.data!.assumingMemoryBound(to: UInt8.self)
        }

        func luminance(x: Int, y: Int) -> Double {
            let offset = (min(height - 1, max(0, y)) * width + min(width - 1, max(0, x))) * 4
            return (Double(pixels[offset]) * 0.2126 + Double(pixels[offset + 1]) * 0.7152
                    + Double(pixels[offset + 2]) * 0.0722) / 255
        }
    }
    private static let woodSamples = WoodSamples()

    private static func woodLightmap(panel: CGRect, region: CGRect, lamp: CGPoint) -> CGImage {
        let wood = woodSamples
        let resolution: CGFloat = 2
        let width = Int(ceil(region.width * resolution))
        let height = Int(ceil(region.height * resolution))
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.clear(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        let radius = Double(min(region.width, region.height) * 0.5)
        let radiusSquared = radius * radius
        // Высота источника над деревом даёт мягкий косой свет на рельеф волокон.
        let lampHeight = 42.0
        for row in 0..<height {
            let worldY = region.maxY - (CGFloat(row) + 0.5) / resolution
            let textureY = (panel.maxY - worldY).truncatingRemainder(dividingBy: wood.pointSize.height)
            let sourceY = max(0, min(wood.height - 1, Int(textureY * CGFloat(wood.height) / wood.pointSize.height)))
            let dy = Double(lamp.y - worldY)
            for column in 0..<width {
                let worldX = region.minX + (CGFloat(column) + 0.5) / resolution
                guard panel.contains(CGPoint(x: worldX, y: worldY)) else { continue }
                let dx = Double(lamp.x - worldX)
                let distanceSquared = dx * dx + dy * dy
                guard distanceSquared < radiusSquared else { continue }
                let sourceX = max(0, min(wood.width - 1, Int((worldX - panel.minX) * CGFloat(wood.width) / wood.pointSize.width)))
                let albedo = wood.luminance(x: sourceX, y: sourceY)
                let nx = (wood.luminance(x: sourceX - 2, y: sourceY)
                          - wood.luminance(x: sourceX + 2, y: sourceY)) * 4
                let ny = (wood.luminance(x: sourceX, y: sourceY + 2)
                          - wood.luminance(x: sourceX, y: sourceY - 2)) * 4
                let normalLength = sqrt(nx * nx + ny * ny + 1)
                let rayLength = sqrt(distanceSquared + lampHeight * lampHeight)
                let diffuse = max(0, (nx * dx + ny * dy + lampHeight) / (normalLength * rayLength))
                let attenuation = 1 - distanceSquared / radiusSquared
                let falloff = attenuation * attenuation
                let alpha = falloff * (0.22 + 0.78 * diffuse) * (0.45 + 0.55 * albedo) * 0.72
                let offset = (row * width + column) * 4
                // Premultiplied отражённый янтарный свет, а не одноцветный halo.
                pixels[offset] = UInt8((0.78 + albedo * 0.22) * alpha * 255)
                pixels[offset + 1] = UInt8((0.31 + albedo * 0.27) * alpha * 255)
                pixels[offset + 2] = UInt8((0.035 + albedo * 0.09) * alpha * 255)
                pixels[offset + 3] = UInt8(alpha * 255)
            }
        }
        return context.makeImage()!
    }

    private static let blueHalo = halo(red: 0.12, green: 0.58, blue: 1, strength: 0.5)
    private static func halo(red: CGFloat, green: CGFloat, blue: CGFloat, strength: CGFloat) -> CGImage {
        let side = 256
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                bytesPerRow: side * 4, space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let center = CGColor(colorSpace: colorSpace, components: [red, green, blue, strength])!
        let middle = CGColor(colorSpace: colorSpace, components: [red, green, blue, strength * 0.28])!
        let clear = CGColor(colorSpace: colorSpace, components: [red, green, blue, 0])!
        let gradient = CGGradient(colorsSpace: colorSpace, colors: [center, middle, clear] as CFArray,
                                  locations: [0, 0.35, 1])!
        context.drawRadialGradient(gradient, startCenter: CGPoint(x: 128, y: 128), startRadius: 0,
                                   endCenter: CGPoint(x: 128, y: 128), endRadius: 128,
                                   options: [.drawsBeforeStartLocation])
        return context.makeImage()!
    }
}

// Один таймер для всех окон и кнопок. Сильного удержания views/windows нет.
private final class LivingChromeClock {
    static let shared = LivingChromeClock()
    private struct Entry { weak var view: LivingChromeView? }
    private var views: [Entry] = []
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObserver: NSObjectProtocol?
    private let epoch = ProcessInfo.processInfo.systemUptime

    private init() {
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
    }

    func add(_ view: LivingChromeView) {
        views.removeAll { $0.view == nil || $0.view === view }
        views.append(Entry(view: view))
        refresh()
    }
    func remove(_ view: LivingChromeView) {
        views.removeAll { $0.view == nil || $0.view === view }
        refresh()
    }

    func refresh() {
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let active = !NSApp.isHidden && views.contains { $0.view?.canAnimate == true }
        if reduced || !active {
            timer?.invalidate()
            timer = nil
            for entry in views { entry.view?.updateLight(time: 0, reducedMotion: true) }
        } else if timer == nil {
            let timer = Timer(timeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in self?.tick() }
            timer.tolerance = 0.012
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func tick() {
        let time = ProcessInfo.processInfo.systemUptime - epoch
        var anyVisible = false
        for entry in views {
            guard let view = entry.view, view.canAnimate else { continue }
            anyVisible = true
            view.updateLight(time: time, reducedMotion: false)
        }
        if !anyVisible { refresh() }
    }
}
