import AppKit
import QuartzCore

// Только фактический статус агента. Unread/connection не означают question/error.
enum TavernAgentVisualStatus: String, CaseIterable {
    case progress, success, question, error, waiting

    init?(agentStatus: String) {
        switch agentStatus {
        case "working": self = .progress
        case "done": self = .waiting
        case "blocked": self = .question
        default: return nil
        }
    }

    fileprivate var color: NSColor {
        switch self {
        case .progress: return NSColor(srgbRed: 0.15, green: 0.72, blue: 1, alpha: 1)
        case .success: return NSColor(srgbRed: 0.23, green: 0.85, blue: 0.45, alpha: 1)
        case .question: return NSColor(srgbRed: 1, green: 0.65, blue: 0.13, alpha: 1)
        case .error: return NSColor(srgbRed: 1, green: 0.12, blue: 0.09, alpha: 1)
        case .waiting: return NSColor(srgbRed: 0.65, green: 0.35, blue: 1, alpha: 1)
        }
    }
}

// Нулевой/первый снимок и повторная конфигурация не являются переходом.
struct TavernTalismanTransition {
    private(set) var status: TavernAgentVisualStatus?

    mutating func update(_ next: TavernAgentVisualStatus?) -> Bool {
        let shouldBurst = status != nil && next != nil && status != next
        status = next
        return shouldBurst
    }
}

/// Декоративный подвес над карточкой; hit testing и accessibility остаются у NSButton.
final class TavernTalismanView: NSView, TavernEffectsClockClient {
    static func validateResources() throws { _ = try TavernTalismanResources.load() }

    static func visualScale(forCardHeight height: CGFloat) -> CGFloat {
        max(0, min(1, height / 140))
    }

    private let resources: TavernTalismanResources
    private let assembly = CALayer()
    private let body = CALayer()
    private let mount = CALayer()
    private let links = (0..<6).map { _ in CALayer() }
    private let outerGlow = CALayer()
    private let innerGlow = CALayer()
    private let hoverGlow = CALayer()
    private let cloud = (0..<11).map { _ in TavernMoteLayers() }
    private let burstLayers = (0..<78).map { _ in TavernMoteLayers() }
    private var transition = TavernTalismanTransition()
    private var burst: [TavernBurstParticle] = []
    private var burstStart: TimeInterval?
    private var hoverStart: TimeInterval?
    private var hovered = false
    private var time: TimeInterval = 0
    // Разные подвесы не синхронизированы; фаза выбирается один раз, не в кадре.
    private let phase = Double.random(in: 0..<(2 * .pi))
    private var motionAllowed = false
    private var lightColour = SIMD3<Float>(repeating: 0)
    private(set) var materialLight: (position: CGPoint, colour: SIMD3<Float>, power: Float)?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        do { resources = try TavernTalismanResources.load() }
        catch { fatalError(L("core.talisman.resourcesUnavailable", error.localizedDescription)) }
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(false)
        // Все координаты ниже — top-left points, как в эталоне Canvas. Положительный
        // угол поворачивает по часовой стрелке; pivot тела сохранён пропорционально.
        layer?.isGeometryFlipped = true
        layer?.masksToBounds = false
        assembly.masksToBounds = false
        layer?.addSublayer(assembly)
        // Укороченная цепь: шесть звеньев, неподвижная накладка поверх первого.
        assembly.addSublayer(body)
        for (index, link) in links.enumerated() {
            link.contents = resources.chain[index % 2]
            assembly.addSublayer(link)
        }
        mount.contents = resources.mount
        assembly.addSublayer(mount)
        body.anchorPoint = CGPoint(x: 0.5, y: 3.0 / 40.0)
        body.shadowColor = NSColor.black.cgColor
        body.shadowOpacity = 0.65
        body.shouldRasterize = true
        body.minificationFilter = .trilinear
        for mote in burstLayers { mote.attach(to: layer!, core: resources.core) }
        for glow in [outerGlow, innerGlow, hoverGlow] {
            glow.compositingFilter = "screenBlendMode"
            layer?.addSublayer(glow)
        }
        hoverGlow.contents = resources.hoverGlow
        for mote in cloud { mote.attach(to: layer!, core: resources.core) }
        assembly.isHidden = true
        burst.reserveCapacity(78)
        render()
    }

    required init?(coder: NSCoder) { fatalError("TavernTalismanView requires init(frame:)") }

    func configure(status: TavernAgentVisualStatus?) {
        precondition(Thread.isMainThread)
        guard transition.status != status else { return }
        let changed = transition.update(status)
        clearBurst()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let status {
            let colour = status.color
            lightColour = SIMD3(Float(colour.redComponent), Float(colour.greenComponent), Float(colour.blueComponent))
            body.contents = resources.bodies[status]
            outerGlow.contents = resources.glows[status]
            innerGlow.contents = resources.glows[status]
            for mote in cloud { mote.soft.contents = resources.soft[status] }
            for mote in burstLayers { mote.soft.contents = resources.soft[status] }
            if changed && effectsVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                for _ in 0..<78 { burst.append(TavernBurstParticle()) }
                burstStart = time
            }
        }
        CATransaction.commit()
        render()
        TavernEffectsClock.shared.refresh()
    }

    func setHovered(_ value: Bool) {
        precondition(Thread.isMainThread)
        guard hovered != value else { return }
        hovered = value
        if value && transition.status != nil && effectsVisible
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            hoverStart = time
        }
        render()
        TavernEffectsClock.shared.refresh()
    }

    override func layout() {
        super.layout()
        render()
        TavernEffectsClock.shared.refresh()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { TavernEffectsClock.shared.remove(self) }
        else { TavernEffectsClock.shared.add(self) }
    }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        TavernEffectsClock.shared.refresh()
    }
    override func viewDidHide() { super.viewDidHide(); TavernEffectsClock.shared.refresh() }
    override func viewDidUnhide() { super.viewDidUnhide(); TavernEffectsClock.shared.refresh() }
    deinit { TavernEffectsClock.shared.remove(self) }

    fileprivate var effectsVisible: Bool { TavernEffectsClock.visible(self) }
    fileprivate var effectsAnimating: Bool {
        transition.status != nil && (transition.status != .success || burstStart != nil || hoverStart != nil)
    }

    fileprivate func setEffectsMotionAllowed(_ allowed: Bool) {
        guard motionAllowed != allowed || (!allowed && (burstStart != nil || hoverStart != nil)) else { return }
        motionAllowed = allowed
        if !allowed {
            clearBurst()
            hoverStart = nil
        }
        render()
    }

    fileprivate func advanceEffects(by delta: TimeInterval) {
        time += delta
        if let start = burstStart, time - start >= 0.5 { clearBurst() }
        if let start = hoverStart, time - start >= 4 { hoverStart = nil }
        render()
    }

    private func clearBurst() {
        burst.removeAll(keepingCapacity: true)
        burstStart = nil
    }

    private func render() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let status = transition.status else {
            materialLight = nil
            assembly.isHidden = true
            outerGlow.opacity = 0; innerGlow.opacity = 0; hoverGlow.opacity = 0
            for mote in cloud { mote.hide() }
            for mote in burstLayers { mote.hide() }
            return
        }
        assembly.isHidden = false
        assembly.frame = bounds
        let card = bounds.insetBy(dx: 3, dy: 3)
        let scale = Self.visualScale(forCardHeight: card.height)
        body.shadowRadius = 1.5 * scale
        body.shadowOffset = CGSize(width: -1.5 * scale, height: 2.5 * scale)
        body.rasterizationScale = window?.backingScaleFactor ?? 2
        let amplitude: CGFloat = motionAllowed ? 1.8 * .pi / 180 : 0
        let idle: CGFloat = status == .success ? 0 : 1
        let reaction: CGFloat
        if let start = hoverStart, motionAllowed {
            let age = time - start
            reaction = CGFloat(sin(age * 3.4) * exp(-age * 1.7)) * amplitude * 1.2
        } else { reaction = 0 }
        let angle = amplitude * CGFloat(sin(time * 1.05 + phase)) * idle + reaction
        let mountPoint = CGPoint(x: card.maxX - 38 * scale, y: card.minY + 14 * scale)
        mount.bounds = CGRect(x: 0, y: 0, width: 16 * scale, height: 16 * scale)
        mount.position = mountPoint
        var node = CGPoint(x: mountPoint.x, y: mountPoint.y + 4 * scale)
        for index in links.indices {
            let k = CGFloat(index + 1)
            let bend = angle * (0.72 + 0.28 * k / CGFloat(links.count))
                + amplitude * 0.12 * CGFloat(sin(time * 1.05 + phase - Double(k) * 0.09)) * idle
            let next = CGPoint(x: node.x + sin(bend) * 4.3 * scale,
                               y: node.y + cos(bend) * 4.3 * scale)
            let link = links[index]
            link.bounds = CGRect(x: 0, y: 0, width: 5 * scale, height: 7 * scale)
            link.position = CGPoint(x: (node.x + next.x) / 2, y: (node.y + next.y) / 2)
            link.setAffineTransform(CGAffineTransform(rotationAngle: -atan2(next.x - node.x, next.y - node.y)))
            node = next
        }
        let bodyAngle = -angle - amplitude * 0.22 * CGFloat(sin(time * 1.05 + phase - 0.5)) * idle
        body.bounds = CGRect(x: 0, y: 0, width: 48 * scale, height: 60 * scale)
        body.position = node
        body.setAffineTransform(CGAffineTransform(rotationAngle: bodyAngle))
        let light = CGPoint(x: node.x - sin(bodyAngle) * 28.5 * scale,
                            y: node.y + cos(bodyAngle) * 28.5 * scale)
        let strength: Double
        if !motionAllowed { strength = status == .success ? 0 : 0.65 }
        else {
            switch status {
            case .progress: strength = 0.75 + 0.16 * sin(time * 1.4)
            case .success: strength = 0
            case .question: strength = 0.55 + 0.22 * sin(time * 0.9)
            case .error: strength = 0.65
            case .waiting: strength = 0.45 + 0.2 * sin(time * 0.55)
            }
        }
        materialLight = status == .success ? nil : (light, lightColour, Float(strength))
        setGlow(outerGlow, center: light, radius: 54 * scale, alpha: strength * 0.8 * 0.8)
        setGlow(innerGlow, center: light, radius: 24 * scale, alpha: strength * 0.8 * 0.65)
        setGlow(hoverGlow, center: CGPoint(x: card.minX + 200 * scale, y: card.minY + 50 * scale),
                radius: 160 * scale, alpha: hovered && status != .success ? 0.05 : 0)
        let count = motionAllowed && status != .success ? (status == .progress || status == .waiting ? 11 : 9) : 0
        for (index, mote) in cloud.enumerated() {
            guard index < count else { mote.hide(); continue }
            let k = Double(index)
            let phase = time * (0.42 + Double(index % 4) * 0.07) + k * 2.399
            let radius = CGFloat(16 + (index % 4) * 4) * scale
            let point = CGPoint(x: light.x + CGFloat(sin(phase)) * radius,
                                y: light.y + CGFloat(cos(phase * 0.71 + k)) * 32 * scale)
            let shimmer = 0.45 + 0.45 * (0.5 + 0.5 * sin(time * (0.8 + k * 0.07) + k))
            mote.update(point: point, size: CGFloat(1.05 + Double(index % 3) * 0.2) * scale,
                        alpha: 0.8 * strength * shimmer)
        }
        renderBurst(card: card, scale: scale)
    }

    private func renderBurst(card: CGRect, scale: CGFloat) {
        guard let start = burstStart, motionAllowed else {
            for mote in burstLayers { mote.hide() }
            return
        }
        let age = time - start
        let inset = card.insetBy(dx: 6 * scale, dy: 6 * scale)
        let w = max(0, inset.width), h = max(0, inset.height)
        let perimeter = 2 * (w + h)
        for (index, particle) in burst.enumerated() {
            let mote = burstLayers[index]
            let t = (age - particle.delay) / (0.5 - particle.delay)
            guard t > 0 && t < 1 else { mote.hide(); continue }
            let envelope = min(t / 0.16, 1) * (1 - t) * (1 - t)
            let travel = CGFloat(1 - (1 - t) * (1 - t))
            let along = particle.along * perimeter
            let drift = (particle.offset + travel * particle.speed) * scale
            let slide = travel * particle.slide * scale
            let point: CGPoint
            if along < w { point = CGPoint(x: inset.minX + along + slide, y: inset.minY - drift) }
            else if along < w + h { point = CGPoint(x: inset.maxX + drift, y: inset.minY + along - w + slide) }
            else if along < 2 * w + h { point = CGPoint(x: inset.maxX - (along - w - h) + slide, y: inset.maxY + drift) }
            else { point = CGPoint(x: inset.minX - drift, y: inset.maxY - (along - 2 * w - h) + slide) }
            mote.update(point: point, size: particle.size * scale, alpha: envelope * 0.8 * 1.1 * particle.alpha)
        }
    }
}

/// Только голубая пыль/свечение; саму руну и её native control рисует родитель.
/// runeCenter задан в top-left координатах полноразмерного root overlay.
final class TavernRuneParticlesView: NSView, TavernEffectsClockClient {
    static func validateResources() throws { _ = try TavernTalismanResources.load() }
    var runeCenter: CGPoint = .zero { didSet { render() } }
    var visualScale: CGFloat = 1 { didSet { render() } }
    private let resources: TavernTalismanResources
    private let glow = CALayer()
    private let motes = (0..<9).map { _ in TavernMoteLayers() }
    private var time: TimeInterval = 0
    private var pulseStart: TimeInterval?
    private var motionAllowed = false
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        do { resources = try TavernTalismanResources.load() }
        catch { fatalError(L("core.talisman.particleResourcesUnavailable", error.localizedDescription)) }
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(false)
        layer?.isGeometryFlipped = true
        layer?.masksToBounds = false
        glow.contents = resources.runeGlow
        glow.compositingFilter = "screenBlendMode"
        layer?.addSublayer(glow)
        for mote in motes {
            mote.attach(to: layer!, core: resources.core)
            mote.soft.contents = resources.runeSoft
        }
        render()
    }
    required init?(coder: NSCoder) { fatalError("TavernRuneParticlesView requires init(frame:)") }
    func pulse() {
        precondition(Thread.isMainThread)
        guard effectsVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        pulseStart = time
        render()
    }
    override func layout() { super.layout(); render(); TavernEffectsClock.shared.refresh() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { TavernEffectsClock.shared.remove(self) }
        else { TavernEffectsClock.shared.add(self) }
    }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); TavernEffectsClock.shared.refresh() }
    override func viewDidHide() { super.viewDidHide(); TavernEffectsClock.shared.refresh() }
    override func viewDidUnhide() { super.viewDidUnhide(); TavernEffectsClock.shared.refresh() }
    deinit { TavernEffectsClock.shared.remove(self) }
    fileprivate var effectsVisible: Bool { TavernEffectsClock.visible(self) }
    fileprivate var effectsAnimating: Bool { true }
    fileprivate func setEffectsMotionAllowed(_ allowed: Bool) {
        guard allowed != motionAllowed else { return }
        motionAllowed = allowed
        if !allowed { pulseStart = nil }
        render()
    }
    fileprivate func advanceEffects(by delta: TimeInterval) { time += delta; render() }
    private func render() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let pulse = motionAllowed ? pulseStart.map { exp(-(time - $0) * 2.5) } ?? 0 : 0
        setGlow(glow, center: runeCenter, radius: 67 * visualScale, alpha: 0.8 * (0.35 + pulse * 0.45))
        for (index, mote) in motes.enumerated() {
            guard motionAllowed else { mote.hide(); continue }
            let i = Double(index), angle = i * 2.399
            let phase = time * (0.35 + Double(index % 4) * 0.03)
            let radius = Double(42 + (index % 3) * 9)
            let point = CGPoint(x: runeCenter.x + CGFloat(cos(angle) * radius + sin(phase + i * 1.3) * 7) * visualScale,
                                y: runeCenter.y + CGFloat(sin(angle) * radius * 0.65 + sin(phase * 0.71 + i) * 8) * visualScale)
            let alpha = (0.25 + 0.65 * (0.5 + 0.5 * sin(time * (0.8 + i * 0.019) + i))) * 0.8
            mote.update(point: point, size: CGFloat(1.2 + Double(index % 3) * 0.25) * visualScale, alpha: alpha)
        }
    }
}

private struct TavernBurstParticle {
    let along = CGFloat.random(in: 0...1)
    let offset = CGFloat.random(in: -9...9)
    let slide = CGFloat.random(in: -14...14)
    let speed = CGFloat.random(in: 8...26)
    let size = CGFloat.random(in: 0.8...2.4)
    let delay = Double.random(in: 0...0.08)
    let alpha = Double.random(in: 0.5...1)
}

private func setGlow(_ layer: CALayer, center: CGPoint, radius: CGFloat, alpha: Double) {
    layer.bounds = CGRect(x: 0, y: 0, width: 2 * radius, height: 2 * radius)
    layer.position = center
    layer.opacity = Float(max(0, min(1, alpha)))
}

private final class TavernMoteLayers {
    let soft = CALayer()
    private let core = CALayer()
    func attach(to parent: CALayer, core image: CGImage) {
        core.contents = image
        soft.compositingFilter = "screenBlendMode"
        core.compositingFilter = "screenBlendMode"
        soft.opacity = 0; core.opacity = 0
        parent.addSublayer(soft); parent.addSublayer(core)
    }
    func update(point: CGPoint, size: CGFloat, alpha: Double) {
        soft.position = point; core.position = point
        soft.bounds = CGRect(x: 0, y: 0, width: size * 8, height: size * 8)
        core.bounds = CGRect(x: 0, y: 0, width: size * 2, height: size * 2)
        let opacity = Float(max(0, min(1, alpha)))
        soft.opacity = opacity; core.opacity = opacity
    }
    func hide() { soft.opacity = 0; core.opacity = 0 }
}

private final class TavernTalismanResources {
    private static var cached: TavernTalismanResources?
    let mount: CGImage
    let bodies: [TavernAgentVisualStatus: CGImage]
    let core: CGImage
    let soft: [TavernAgentVisualStatus: CGImage]
    let glows: [TavernAgentVisualStatus: CGImage]
    let chain: [CGImage]
    let runeGlow: CGImage
    let runeSoft: CGImage
    let hoverGlow: CGImage

    static func load() throws -> TavernTalismanResources {
        precondition(Thread.isMainThread)
        if let cached { return cached }
        let resources = try TavernTalismanResources()
        cached = resources
        return resources
    }
    private init() throws {
        mount = try Self.image("mount", directory: "chained")
        core = try Self.image("particle-core", directory: "sprites")
        let softImage = try Self.image("particle-soft", directory: "sprites")
        let glowImage = try Self.image("glow", directory: "sprites")
        var bodies: [TavernAgentVisualStatus: CGImage] = [:]
        var soft: [TavernAgentVisualStatus: CGImage] = [:]
        var glows: [TavernAgentVisualStatus: CGImage] = [:]
        for status in TavernAgentVisualStatus.allCases {
            let original = try Self.image("\(status.rawValue)-body", directory: "chained")
            bodies[status] = status == .success ? try Self.dimmed(original) : original
            soft[status] = try Self.tint(softImage, color: status.color)
            glows[status] = try Self.tint(glowImage, color: status.color)
        }
        self.bodies = bodies; self.soft = soft; self.glows = glows
        runeGlow = try Self.tint(glowImage, color: NSColor(srgbRed: 0.06, green: 0.51, blue: 1, alpha: 1))
        runeSoft = try Self.tint(softImage, color: NSColor(srgbRed: 0.22, green: 0.72, blue: 1, alpha: 1))
        hoverGlow = try Self.tint(glowImage, color: NSColor(srgbRed: 0.65, green: 0.47, blue: 0.2, alpha: 1))
        chain = try [Self.chainLink(edge: false), Self.chainLink(edge: true)]
    }
    private static func image(_ name: String, directory: String) throws -> CGImage {
        let path = "Textures/TavernVisuals/\(directory)/\(name).png"
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Textures/TavernVisuals/\(directory)"),
              let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw NSError(domain: "TavernTalismanResources", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: L("core.talisman.invalidResource", path)])
        }
        return image
    }
    private static func context(width: Int, height: Int) throws -> CGContext {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NSError(domain: "TavernTalismanResources", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: L("core.talisman.rasterUnavailable")])
        }
        return context
    }
    // Приглушаем пигмент один раз, не делая камень прозрачным.
    private static func dimmed(_ image: CGImage) throws -> CGImage {
        let context = try context(width: image.width, height: image.height)
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: rect)
        context.setBlendMode(.sourceAtop)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.28))
        context.fill(rect)
        guard let result = context.makeImage() else { throw rasterError }
        return result
    }
    private static func tint(_ image: CGImage, color: NSColor) throws -> CGImage {
        let context = try context(width: image.width, height: image.height)
        let rect = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        context.draw(image, in: rect)
        context.setBlendMode(.sourceIn)
        context.setFillColor(color.cgColor)
        context.fill(rect)
        guard let tinted = context.makeImage() else { throw rasterError }
        return tinted
    }
    // Точный procedural link из makeChainLinks(): 40×56, rx 10/4, ry19, stroke5.
    private static func chainLink(edge: Bool) throws -> CGImage {
        let context = try context(width: 40, height: 56)
        context.translateBy(x: 0, y: 56); context.scaleBy(x: 1, y: -1)
        let radius: CGFloat = edge ? 4 : 10
        let path = CGPath(ellipseIn: CGRect(x: 20 - radius, y: 9, width: radius * 2, height: 38), transform: nil)
        context.addPath(path); context.setLineWidth(5); context.replacePathWithStrokedPath(); context.clip()
        let colors = [NSColor(srgbRed: 61.0 / 255, green: 41.0 / 255, blue: 21.0 / 255, alpha: 1).cgColor,
                      NSColor(srgbRed: 220.0 / 255, green: 194.0 / 255, blue: 139.0 / 255, alpha: 1).cgColor,
                      NSColor(srgbRed: 136.0 / 255, green: 96.0 / 255, blue: 55.0 / 255, alpha: 1).cgColor]
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray,
                                        locations: [0, 0.5, 1]) else { throw rasterError }
        context.drawLinearGradient(gradient, start: CGPoint(x: 7, y: 0), end: CGPoint(x: 29, y: 42),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        guard let image = context.makeImage() else { throw rasterError }
        return image
    }
    private static var rasterError: NSError {
        NSError(domain: "TavernTalismanResources", code: 3,
                userInfo: [NSLocalizedDescriptionKey: L("core.talisman.rasterPreparationFailed")])
    }
}

private protocol TavernEffectsClockClient: AnyObject {
    var effectsVisible: Bool { get }
    var effectsAnimating: Bool { get }
    func setEffectsMotionAllowed(_ allowed: Bool)
    func advanceEffects(by delta: TimeInterval)
}

// Один main-run-loop clock только для декоративных слоёв. Никакой инвалидизации
// SurfaceView/текста; registry не удерживает controls, окно или их владельца.
private final class TavernEffectsClock {
    static let shared = TavernEffectsClock()
    private struct Entry { weak var client: TavernEffectsClockClient? }
    private var entries: [Entry] = []
    private var timer: Timer?
    private var previous: TimeInterval = 0
    private var observers: [NSObjectProtocol] = []
    private var workspaceObserver: NSObjectProtocol?
    private init() {
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in self?.refresh()
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            if note.object is NSClipView { self?.refresh() }
        })
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
    }
    static func visible(_ view: NSView) -> Bool {
        guard let window = view.window else { return false }
        return !NSApp.isHidden && window.isVisible && !window.isMiniaturized
            && window.occlusionState.contains(.visible) && !view.isHiddenOrHasHiddenAncestor
            && !view.visibleRect.isEmpty
    }
    func add(_ client: TavernEffectsClockClient) {
        entries.removeAll { $0.client == nil || $0.client === client }
        entries.append(Entry(client: client))
        refresh()
    }
    func remove(_ client: TavernEffectsClockClient) {
        entries.removeAll { $0.client == nil || $0.client === client }
        refresh()
    }
    func refresh() {
        precondition(Thread.isMainThread)
        entries.removeAll { $0.client == nil }
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var active = false
        for entry in entries {
            guard let client = entry.client else { continue }
            let allowed = !reduced && client.effectsVisible
            client.setEffectsMotionAllowed(allowed)
            active = active || (allowed && client.effectsAnimating)
        }
        if !active {
            timer?.invalidate(); timer = nil; previous = 0
        } else if timer == nil {
            previous = ProcessInfo.processInfo.systemUptime
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
            timer.tolerance = 0.006
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let delta = min(0.1, max(0, now - previous))
        previous = now
        var refreshNeeded = false
        for entry in entries {
            guard let client = entry.client else { refreshNeeded = true; continue }
            guard client.effectsVisible else { client.setEffectsMotionAllowed(false); refreshNeeded = true; continue }
            guard client.effectsAnimating else { continue }
            client.advanceEffects(by: delta)
            if !client.effectsAnimating { refreshNeeded = true }
        }
        if refreshNeeded { refresh() }
    }
}
