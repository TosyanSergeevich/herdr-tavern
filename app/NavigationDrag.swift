import AppKit
import QuartzCore

struct TavernDropProposal {
    let target: TavernDropTarget
    let rect: NSRect
    let title: String
    var relatedRects: [NSRect] = []
}

/// Геометрия ограничивает весь блок, а не только положение указателя.
enum TavernDragGeometry {
    static func clamped(_ frame: NSRect, inside bounds: NSRect) -> NSRect {
        let width = min(max(0, frame.width), max(0, bounds.width))
        let height = min(max(0, frame.height), max(0, bounds.height))
        return NSRect(x: min(max(frame.minX, bounds.minX), bounds.maxX - width),
                      y: min(max(frame.minY, bounds.minY), bounds.maxY - height), width: width, height: height)
    }

    static func fitted(_ frame: NSRect, inside bounds: NSRect) -> NSRect {
        let scale = min(1, max(0, bounds.width) / max(1, frame.width),
                        max(0, bounds.height) / max(1, frame.height))
        return clamped(NSRect(origin: frame.origin, size: NSSize(width: frame.width * scale,
                                                                height: frame.height * scale)), inside: bounds)
    }

    static func flight(from: NSRect, to: NSRect, progress: CGFloat, inside bounds: NSRect) -> NSRect {
        let t = min(1, max(0, progress))
        return fitted(NSRect(x: from.minX + (to.minX - from.minX) * t,
                             y: from.minY + (to.minY - from.minY) * t,
                             width: from.width + (to.width - from.width) * t,
                             height: from.height + (to.height - from.height) * t), inside: bounds)
    }

    /// Ступень 9 pt у трёх карточек; большие группы остаются в разбросе 18 pt.
    static func stackFrames(card: NSSize, count: Int) -> [NSRect] {
        let step = count > 1 ? min(9, 18 / CGFloat(count - 1)) : 0
        return (0..<max(0, count)).map {
            NSRect(x: CGFloat($0) * step, y: 12 + CGFloat($0) * step,
                   width: card.width, height: card.height)
        }
    }

    static func settling(from: NSRect, to: NSRect, elapsed: TimeInterval, inside bounds: NSRect) -> NSRect {
        guard elapsed < 0.36 else { return fitted(to, inside: bounds) }
        let t = max(0, elapsed), damping = 22.0, frequency = 20.0
        let progress = 1 - exp(-damping * t) * (cos(frequency * t) + damping / frequency * sin(frequency * t))
        let rect = NSRect(x: from.minX + (to.minX - from.minX) * progress,
                          y: from.minY + (to.minY - from.minY) * progress,
                          width: from.width + (to.width - from.width) * progress,
                          height: from.height + (to.height - from.height) * progress)
        return fitted(rect, inside: bounds)
    }
}

/// Критически затухающая пружина сохраняет скорость при смене цели.
/// В отличие от перезапуска tween, частые snapshot не останавливают движение.
struct TavernCardPlacement {
    private(set) var frame: NSRect
    private var velocity = SIMD4<Double>(repeating: 0)

    init(frame: NSRect) { self.frame = frame }

    mutating func advance(toward target: NSRect, delta: TimeInterval, inside bounds: NSRect) -> Bool {
        let goal = TavernDragGeometry.fitted(target, inside: bounds)
        let position = SIMD4(Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height))
        let destination = SIMD4(Double(goal.minX), Double(goal.minY), Double(goal.width), Double(goal.height))
        let dt = max(0, delta), rate = 28.0
        let displacement = position - destination
        let impulse = (velocity + displacement * rate) * dt
        let decay = exp(-rate * dt)
        let next = destination + (displacement + impulse) * decay
        velocity = (velocity - impulse * rate) * decay
        frame = TavernDragGeometry.fitted(NSRect(x: next[0], y: next[1], width: max(0, next[2]),
                                                height: max(0, next[3])), inside: bounds)
        let limited = SIMD4(Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height))
        var arrived = true
        for axis in 0..<4 {
            if abs(limited[axis] - next[axis]) > 0.001 { velocity[axis] = 0 }
            if abs(limited[axis] - destination[axis]) > 0.25 || abs(velocity[axis]) > 2 { arrived = false }
        }
        if arrived { frame = goal; velocity = .zero }
        return arrived
    }
}

/// Непрозрачная проекция сохраняет штатный parent карточек при живом rebuild.
/// Оригиналы скрываются лишь после готовности всей группы, до ответа и пружины.
private final class TavernLiftView: NSView {
    var images: [NSImage] = []
    var cardFrames: [NSRect] = []
    var naturalSize = NSSize.zero
    var bundled = false
    var drawCards = true
    var harnessOpacity: CGFloat = 1

    func configure(images: [NSImage], bundled: Bool) {
        guard let first = images.first else { return }
        self.images = images; self.bundled = bundled && images.count > 1
        if self.bundled {
            cardFrames = TavernDragGeometry.stackFrames(card: first.size, count: images.count)
            let union = cardFrames.reduce(NSRect.zero) { $0.union($1) }
            naturalSize = NSSize(width: union.maxX, height: union.maxY + 4)
        } else {
            cardFrames = [NSRect(origin: .zero, size: first.size)]
            naturalSize = first.size
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard naturalSize.width > 0, naturalSize.height > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.scaleX(by: bounds.width / naturalSize.width, yBy: bounds.height / naturalSize.height)
        transform.concat()
        if drawCards {
            for index in images.indices.reversed() {
                images[index].draw(in: cardFrames[index], from: .zero, operation: .sourceOver, fraction: 1)
            }
        }
        guard bundled, case .success(let materials) = TavernMaterials.bundled else { return }
        NSBezierPath(rect: NSRect(origin: .zero, size: naturalSize)).addClip()
        for x in [CGFloat(18), naturalSize.width - 26] {
            for y in stride(from: CGFloat(0), to: naturalSize.height, by: 56) {
                materials.agentChainStrap.draw(in: NSRect(x: x, y: y, width: 8, height: 56),
                                              from: .zero, operation: .sourceOver, fraction: harnessOpacity)
            }
        }
        for x in stride(from: CGFloat(0), to: naturalSize.width, by: 56) {
            materials.agentChainBelt.draw(in: NSRect(x: x, y: 2, width: 56, height: 8),
                                         from: .zero, operation: .sourceOver, fraction: harnessOpacity)
        }
    }
}

/// Карточки в полёте остаются непрозрачными; clip принадлежит общему overlay.
private final class TavernCardFlightView: NSView {
    var images: [NSImage] = []
    var frames: [NSRect] = [] { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        for index in images.indices.reversed() where index < frames.count {
            images[index].draw(in: frames[index], from: .zero, operation: .sourceOver, fraction: 1)
        }
    }
}

private final class TavernDragOverlay: NSView {
    let lift = TavernLiftView()
    let flight = TavernCardFlightView()
    var cards: [NSButton] = []
    var returning = false {
        didSet {
            if returning {
                destination.path = nil; related.path = nil
                caption.isHidden = true
            }
        }
    }
    private var gatheringFrom: [NSRect] = []
    private var gatheringStarted: TimeInterval?
    private let destination = CAShapeLayer()
    private let related = CAShapeLayer()
    private let clipping = CAShapeLayer()
    private let caption = NSTextField(labelWithString: "")
    private var lastLimits = NSRect.null
    private var lastTarget: TavernDropTarget?
    private var lastRect = NSRect.null
    private var lastRelatedRects: [NSRect] = []

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.mask = clipping
        related.fillColor = TavernAppearance.accent.withAlphaComponent(0.08).cgColor
        related.strokeColor = TavernAppearance.accent.withAlphaComponent(0.9).cgColor
        related.lineWidth = 2
        layer?.addSublayer(related)
        destination.fillColor = TavernAppearance.agentAccent.withAlphaComponent(0.12).cgColor
        destination.strokeColor = TavernAppearance.agentAccent.withAlphaComponent(0.85).cgColor
        destination.lineWidth = 2
        layer?.addSublayer(destination)
        flight.frame = bounds; flight.autoresizingMask = [.width, .height]
        addSubview(flight)
        addSubview(lift)
        caption.font = TavernAppearance.controlFont
        caption.textColor = TavernAppearance.text
        caption.backgroundColor = TavernAppearance.chrome.withAlphaComponent(0.95)
        caption.drawsBackground = true; caption.alignment = .center
        caption.wantsLayer = true; caption.layer?.cornerRadius = 4
        caption.layer?.masksToBounds = true
        addSubview(caption)
    }
    required init?(coder: NSCoder) { fatalError("TavernDragOverlay requires a frame") }

    func compactCardFrames() -> [NSRect] {
        guard lift.naturalSize.width > 0, lift.naturalSize.height > 0 else { return [] }
        let x = lift.frame.width / lift.naturalSize.width, y = lift.frame.height / lift.naturalSize.height
        return lift.cardFrames.map {
            NSRect(x: lift.frame.minX + $0.minX * x, y: lift.frame.minY + $0.minY * y,
                   width: $0.width * x, height: $0.height * y)
        }
    }

    func renderedCardFrames() -> [NSRect] {
        flight.images.isEmpty ? compactCardFrames() : flight.frames
    }

    func gather(from frames: [NSRect]) {
        guard TavernMotion.enabled, frames.count == lift.images.count else { stopFlight(); return }
        gatheringFrom = frames
        gatheringStarted = ProcessInfo.processInfo.systemUptime
        flight.images = lift.images; flight.frames = frames
        lift.drawCards = false; lift.needsDisplay = true
    }

    @discardableResult
    func advanceGather(inside bounds: NSRect) -> Bool {
        guard let started = gatheringStarted else { return false }
        let t = min(1, (ProcessInfo.processInfo.systemUptime - started) / 0.24)
        let progress = CGFloat(1 - pow(1 - t, 3))
        guard lift.cardFrames.count == gatheringFrom.count, flight.frames.count == gatheringFrom.count,
              lift.naturalSize.width > 0, lift.naturalSize.height > 0 else { stopFlight(); return false }
        let x = lift.frame.width / lift.naturalSize.width, y = lift.frame.height / lift.naturalSize.height
        for index in gatheringFrom.indices {
            let card = lift.cardFrames[index]
            let target = NSRect(x: lift.frame.minX + card.minX * x, y: lift.frame.minY + card.minY * y,
                                width: card.width * x, height: card.height * y)
            flight.frames[index] = TavernDragGeometry.flight(from: gatheringFrom[index], to: target,
                                                            progress: progress, inside: bounds)
        }
        if t >= 1 { stopFlight(); return false }
        return true
    }

    func stopFlight() {
        gatheringStarted = nil; gatheringFrom = []
        flight.images = []; flight.frames = []
        lift.drawCards = true; lift.harnessOpacity = 1; lift.needsDisplay = true
    }

    func update(limits: NSRect, proposal: TavernDropProposal?) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if lastLimits != limits {
            clipping.path = CGPath(rect: limits, transform: nil)
            lastLimits = limits
        }
        if lastTarget != proposal?.target || lastRect != proposal?.rect {
            if let area = proposal?.rect.intersection(limits), !area.isEmpty {
                destination.path = CGPath(roundedRect: area.insetBy(dx: min(1, area.width / 4), dy: min(1, area.height / 4)),
                                          cornerWidth: 5, cornerHeight: 5, transform: nil)
            } else { destination.path = nil }
            lastTarget = proposal?.target; lastRect = proposal?.rect ?? .null
        }
        let rectangles = proposal?.relatedRects ?? []
        if rectangles != lastRelatedRects {
            let path = CGMutablePath()
            for rect in rectangles {
                let area = rect.intersection(limits)
                if !area.isEmpty { path.addRoundedRect(in: area.insetBy(dx: 1, dy: 1), cornerWidth: 5, cornerHeight: 5) }
            }
            related.path = path
            lastRelatedRects = rectangles
        }
        // В узкой ленте подсказка перекрывает саму вкладку; там достаточно линии вставки.
        caption.isHidden = limits.height < 60
        caption.stringValue = proposal?.title ?? L("core.drag.cancel")
        let size = caption.intrinsicContentSize
        caption.frame = TavernDragGeometry.clamped(NSRect(x: lift.frame.midX - (size.width + 20) / 2,
                                                         y: lift.frame.minY - 26, width: size.width + 20, height: 22), inside: limits)
        CATransaction.commit()
    }
}

private final class TavernDragCaptureSession {
    var point: NSPoint
    var releasePoint: NSPoint?
    var thresholdCrossed = false
    var bundled = false
    var inFlight = false
    var latest = false
    var performed = false
    var offset = NSPoint.zero
    init(point: NSPoint) { self.point = point }
}

/// Захват реализован внутри окна: системный drag image способен выйти за контейнер.
final class TavernNavigationDrag {
    private var overlay: TavernDragOverlay?
    private var animation: Timer?
    private var refreshVisual: (() -> Void)?
    private var sessionValid: (() -> Bool)?
    private var escapeMonitor: Any?
    private var returnVisual: (() -> Void)?
    private var placeWhenLayoutChanges: (() -> Void)?
    private var suppressed: [ObjectIdentifier: (view: NSView, hidden: Bool)] = [:]
    private var cancelled = false
    private(set) var tracking = false
    private var captureGeneration: UInt64 = 0
    private var lifecycle: Timer?
    private struct CaptureKey: Hashable {
        let identity: ObjectIdentifier
        let revision: UInt64
    }
    private var imageCache: [CaptureKey: NSImage] = [:]
    private var motionObserver: NSObjectProtocol?

    init() {
        motionObserver = NotificationCenter.default.addObserver(forName: .tavernMotionDidChange, object: nil, queue: .main) {
            [weak self] _ in
            guard let self, !TavernMotion.enabled else { return }
            self.animation?.invalidate()
            self.animation = nil
            if self.overlay?.returning == true { self.finish() }
            else { self.overlay?.stopFlight() }
        }
    }

    deinit {
        if let motionObserver { NotificationCenter.default.removeObserver(motionObserver) }
    }
    #if TAVERN_RENDER_TESTING
    var requestImageForTesting: ((NSView, @escaping (Result<NSImage, Error>) -> Void) -> Void)?
    var nextEventForTesting: (() -> NSEvent?)?
    var windowAvailableForTesting: (() -> Bool)?
    var displayedCardsForTesting: [NSButton] { overlay?.lift.images.isEmpty == false ? overlay?.cards ?? [] : [] }
    var displayedImagesForTesting: [NSImage] { overlay?.lift.images ?? [] }
    #endif

    private func windowAvailable(_ window: NSWindow) -> Bool {
        #if TAVERN_RENDER_TESTING
        if let windowAvailableForTesting { return windowAvailableForTesting() }
        #endif
        return window.isVisible && window.isKeyWindow
    }

    func refresh() {
        guard sessionValid?() != false else { cancel(); return }
        refreshVisual?()
        placeWhenLayoutChanges?()
    }

    private func conceal(_ views: [NSView]) {
        let ids = Set(views.map { ObjectIdentifier($0) })
        for id in Array(suppressed.keys) where !ids.contains(id) {
            if let saved = suppressed.removeValue(forKey: id) {
                saved.view.isHidden = saved.hidden
            }
        }
        for view in views {
            let id = ObjectIdentifier(view)
            if suppressed[id] == nil { suppressed[id] = (view, view.isHidden) }
            view.isHidden = true
        }
    }

    private func finish() {
        captureGeneration &+= 1
        lifecycle?.invalidate(); lifecycle = nil
        imageCache.removeAll()
        animation?.invalidate(); animation = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil; sessionValid = nil
        returnVisual = nil
        placeWhenLayoutChanges = nil
        overlay?.removeFromSuperview(); overlay = nil; refreshVisual = nil
        conceal([])
    }

    func cancel() {
        cancelled = true
        finish()
    }

    private func requestImage(of view: NSView, completion: @escaping (Result<NSImage, Error>) -> Void) {
        #if TAVERN_RENDER_TESTING
        if let requestImageForTesting { requestImageForTesting(view, completion); return }
        #endif
        let hidden = view.isHidden
        view.isHidden = false
        defer { view.isHidden = hidden }
        if let card = view as? TavernButton { card.requestDragImage(completion: completion); return }
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            completion(.failure(NSError(domain: "TavernNavigationDrag", code: 1))); return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        completion(.success(image))
    }

    @discardableResult
    func track(button: NSButton, event: NSEvent, root: NSView,
               limits: @escaping () -> NSRect, valid: @escaping () -> Bool,
               visual: (() -> NSImage?)? = nil,
               members: (() -> [NSButton])? = nil,
               connections: (([NSButton]) -> [NSView])? = nil,
               bundleAt: ((NSPoint, TavernDropProposal?) -> Bool)? = nil,
               proposal: @escaping (NSPoint) -> TavernDropProposal?,
               autoscroll: (NSPoint) -> Void,
               perform: @escaping (TavernDropTarget, @escaping (Bool) -> Void) -> Void) -> Bool {
        guard let window = button.window, !tracking else { return false }
        finish()
        cancelled = false; tracking = true
        defer { tracking = false }
        let generation = captureGeneration
        let start = root.convert(event.locationInWindow, from: nil)
        let sourceRect = button.convert(button.bounds, to: root)
        let sourceID = button.accessibilityIdentifier()
        let state = TavernDragCaptureSession(point: start)
        let layer = TavernDragOverlay(frame: root.bounds)
        layer.autoresizingMask = [.width, .height]
        var lastScroll = ProcessInfo.processInfo.systemUptime
        var cursorPushed = false
        defer { if cursorPushed { NSCursor.pop() } }
        sessionValid = { [weak button, weak window, weak root] in
            guard let button, let window, let root, button.window === window, root.window === window,
                  button.superview != nil else { return false }
            return valid()
        }
        let alive: () -> Bool = { [weak self, weak layer, weak window] in
            guard let self, let layer, let window else { return false }
            return self.captureGeneration == generation && !self.cancelled
                && self.overlay === layer && self.sessionValid?() == true && self.windowAvailable(window)
        }
        let place: () -> Void = { [weak self, weak layer] in
            guard let self, let layer, self.overlay === layer else { return }
            let bounds = limits(), natural = layer.lift.naturalSize
            let maximumWidth = visual == nil ? bounds.width : min(bounds.width, 260)
            let maximumHeight = visual == nil ? bounds.height : min(bounds.height, 120)
            let scale = min(1, maximumWidth / max(1, natural.width), maximumHeight / max(1, natural.height))
            let size = NSSize(width: natural.width * scale, height: natural.height * scale)
            let anchorY = state.offset.y + (layer.lift.bundled ? 12 : 0)
            layer.lift.frame = TavernDragGeometry.clamped(NSRect(x: state.point.x - state.offset.x * scale,
                y: state.point.y - anchorY * scale, width: size.width, height: size.height), inside: bounds)
            layer.advanceGather(inside: bounds)
            layer.update(limits: bounds, proposal: bounds.contains(state.point) ? proposal(state.point) : nil)
        }
        let release: () -> Void = { [weak self, weak layer, weak root] in
            guard let self, let layer, let root, !state.performed, let point = state.releasePoint else { return }
            guard alive() else { self.cancel(); return }
            guard limits().contains(point), let selection = proposal(point) else {
                self.returnVisual?(); return
            }
            state.performed = true
            if visual == nil {
                let previous = layer.cards.map { $0.convert($0.bounds, to: root) }
                self.placeWhenLayoutChanges = { [weak self, weak layer, weak root] in
                    guard let self, let layer, let root, !self.tracking, !layer.returning,
                          self.overlay === layer else { return }
                    if layer.cards.enumerated().contains(where: { index, card in
                        index >= previous.count || card.convert(card.bounds, to: root) != previous[index]
                    }) { self.placeAtCards(layer, root: root, limits: limits) }
                }
            }
            perform(selection.target) { [weak self, weak layer, weak root] changed in
                guard let self, let layer, let root, alive() else { return }
                guard self.overlay === layer else { return }
                if changed, visual != nil {
                    let size = layer.lift.frame.size
                    self.settle(layer, to: NSRect(x: selection.rect.midX - size.width / 2,
                        y: selection.rect.midY - size.height / 2, width: size.width, height: size.height), limits: limits)
                } else if !layer.returning { self.placeAtCards(layer, root: root, limits: limits) }
            }
        }
        refreshVisual = { [weak self, weak layer, weak root] in
            guard let self, let layer, let root, alive(), !layer.returning, state.thresholdCrossed else { return }
            if state.inFlight { state.latest = true; return }
            let available = members?() ?? [button]
            let selected = available.first { $0.accessibilityIdentifier() == sourceID } ?? button
            let cards = state.bundled ? [selected] + available.filter { $0 !== selected } : [selected]
            let bundled = state.bundled
            let keys = cards.map { CaptureKey(identity: ObjectIdentifier($0), revision: ($0 as? TavernButton)?.dragVisualRevision ?? 0) }
            // Keep only reusable revisions for this group, not a history of
            // every title/status/feedback change during a long gesture.
            if self.imageCache.keys.contains(where: { !keys.contains($0) }) {
                self.imageCache = self.imageCache.filter { keys.contains($0.key) }
            }
            state.inFlight = true
            var images = [NSImage?](repeating: nil, count: visual == nil ? cards.count : 1)
            var remaining = images.count
            var failed = false
            let accept: (Int, Result<NSImage, Error>) -> Void = { [weak self, weak layer, weak root] index, result in
                guard let self, let layer, let root, alive(), !failed else { return }
                switch result {
                case .failure: failed = true; self.cancel(); return
                case .success(let image):
                    images[index] = image
                    if visual == nil, cards[index] is TavernButton { self.imageCache[keys[index]] = image }
                }
                remaining -= 1
                guard remaining == 0 else { return }
                state.inFlight = false
                let currentAvailable = members?() ?? [button]
                let currentSelected = currentAvailable.first { $0.accessibilityIdentifier() == sourceID } ?? button
                let currentCards = state.bundled
                    ? [currentSelected] + currentAvailable.filter { $0 !== currentSelected } : [currentSelected]
                let currentKeys = currentCards.map {
                    CaptureKey(identity: ObjectIdentifier($0), revision: ($0 as? TavernButton)?.dragVisualRevision ?? 0)
                }
                if currentKeys != keys || bundled != state.bundled { state.latest = true }
                if state.latest {
                    state.latest = false
                    self.refreshVisual?()
                    return
                }
                guard !layer.returning else { return }
                let oldFrames = layer.renderedCardFrames(), oldCards = layer.cards
                let wasBundled = layer.lift.bundled
                layer.lift.configure(images: images.compactMap { $0 }, bundled: bundled)
                layer.cards = cards
                self.conceal(cards.map { $0 as NSView } + (connections?(cards) ?? []))
                if layer.superview == nil { root.addSubview(layer) }
                state.offset = visual == nil ? NSPoint(x: start.x - sourceRect.minX, y: start.y - sourceRect.minY)
                    : NSPoint(x: layer.lift.naturalSize.width / 2, y: layer.lift.naturalSize.height - 10)
                place()
                if layer.lift.bundled && !wasBundled {
                    layer.gather(from: cards.map { card in
                        if let index = oldCards.firstIndex(where: { $0 === card }), index < oldFrames.count { return oldFrames[index] }
                        return TavernDragGeometry.fitted(card.convert(card.bounds, to: root), inside: limits())
                    })
                    self.startGatherClock(layer, limits: limits)
                } else if !layer.lift.bundled { layer.stopFlight() }
                else if !layer.flight.images.isEmpty { layer.flight.images = layer.lift.images }
                if state.releasePoint != nil { release() }
            }
            if let visual {
                if let image = visual() { accept(0, .success(image)) }
                else { accept(0, .failure(NSError(domain: "TavernNavigationDrag", code: 2))) }
            } else {
                for index in cards.indices {
                    if cards[index] is TavernButton, let image = self.imageCache[keys[index]] { accept(index, .success(image)) }
                    else { self.requestImage(of: cards[index]) { accept(index, $0) } }
                }
            }
        }
        overlay = layer
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] key in
            guard key.keyCode == 53, self?.overlay === layer else { return key }
            self?.returnVisual?()
            return nil
        }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self, weak window] _ in
            guard let self, let window else { return }
            if self.sessionValid?() != true || !self.windowAvailable(window) { self.cancel() }
        }
        lifecycle = timer; RunLoop.main.add(timer, forMode: .common)
        returnVisual = { [weak self, weak layer] in
            guard let self, let layer, self.overlay === layer else { return }
            guard !layer.lift.images.isEmpty else { self.cancel(); return }
            self.cancelled = true
            self.placeAtCards(layer, root: root, limits: limits)
        }
        while alive() {
            let next: NSEvent?
            #if TAVERN_RENDER_TESTING
            if let nextEventForTesting { next = nextEventForTesting() }
            else { next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown],
                until: Date(timeIntervalSinceNow: 1.0 / 60), inMode: .eventTracking, dequeue: true) }
            #else
            next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown],
                until: Date(timeIntervalSinceNow: 1.0 / 60), inMode: .eventTracking, dequeue: true)
            #endif
            guard alive() else { break }
            if let next {
                if next.type == .keyDown {
                    if next.keyCode == 53 { returnVisual?(); break }
                    continue
                }
                state.point = root.convert(next.locationInWindow, from: nil)
                if !state.thresholdCrossed, hypot(state.point.x - start.x, state.point.y - start.y) >= 6 {
                    state.thresholdCrossed = true
                    state.bundled = bundleAt?(state.point, proposal(state.point)) ?? false
                    refreshVisual?()
                    if !cursorPushed { NSCursor.closedHand.push(); cursorPushed = true }
                }
                if next.type == .leftMouseUp {
                    if !state.thresholdCrossed {
                        let click = button.convert(button.bounds, to: root).contains(state.point)
                        finish()
                        if click { button.performClick(nil) }
                    } else {
                        state.releasePoint = state.point
                        let bounds = limits()
                        let selection = bounds.contains(state.point) ? proposal(state.point) : nil
                        let useBundle = bundleAt?(state.point, selection) ?? false
                        if useBundle != state.bundled {
                            state.bundled = useBundle
                            refreshVisual?()
                        }
                        if alive(), !state.inFlight, !state.performed, !layer.returning { place(); release() }
                    }
                    return true
                }
            }
            guard state.thresholdCrossed else { continue }
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastScroll >= 1.0 / 30 { autoscroll(state.point); lastScroll = now }
            let selection = limits().contains(state.point) ? proposal(state.point) : nil
            let useBundle = bundleAt?(state.point, selection) ?? false
            if useBundle != state.bundled { state.bundled = useBundle; refresh() }
            if !layer.lift.images.isEmpty { place() }
        }
        if !layer.returning { cancel() }
        return true
    }

    private func startGatherClock(_ overlay: TavernDragOverlay, limits: @escaping () -> NSRect) {
        guard TavernMotion.enabled else { return }
        animation?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self, weak overlay] timer in
            guard let self, let overlay, self.overlay === overlay else { timer.invalidate(); return }
            if !overlay.advanceGather(inside: limits()) {
                timer.invalidate(); self.animation = nil
            }
        }
        animation = timer; RunLoop.main.add(timer, forMode: .common)
    }

    private func placeAtCards(_ overlay: TavernDragOverlay, root: NSView, limits: @escaping () -> NSRect) {
        placeWhenLayoutChanges = nil
        guard TavernMotion.enabled else { finish(); return }
        animation?.invalidate()
        let from = overlay.renderedCardFrames()
        let images = overlay.flight.images.isEmpty ? overlay.lift.images : overlay.flight.images
        guard from.count == images.count else { finish(); return }
        let ids = overlay.cards.map { $0.accessibilityIdentifier() }
        var motion = from.map { TavernCardPlacement(frame: $0) }
        overlay.stopFlight(); overlay.returning = true
        overlay.flight.images = images; overlay.flight.frames = from
        overlay.lift.drawCards = false; overlay.lift.needsDisplay = true
        returnVisual = nil
        var previousTick = ProcessInfo.processInfo.systemUptime
        let start = previousTick
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self, weak overlay, weak root] timer in
            guard let self, let overlay, let root, self.overlay === overlay else { timer.invalidate(); return }
            guard overlay.window?.isVisible == true, overlay.window?.isKeyWindow == true else { self.cancel(); return }
            let now = ProcessInfo.processInfo.systemUptime, delta = now - previousTick
            previousTick = now
            let progress = min(1, (now - start) / 0.24)
            let bounds = limits()
            var arrived = true
            for index in from.indices {
                let frame = from[index]
                let current = index < ids.count
                    ? overlay.cards.first { $0.accessibilityIdentifier() == ids[index] && $0.superview != nil } : nil
                let target = current.map { $0.convert($0.bounds, to: root) } ?? frame
                if !motion[index].advance(toward: target, delta: delta, inside: bounds) { arrived = false }
                overlay.flight.frames[index] = motion[index].frame
            }
            overlay.lift.frame = TavernDragGeometry.fitted(overlay.lift.frame, inside: bounds)
            overlay.lift.harnessOpacity = 1 - progress; overlay.lift.needsDisplay = true
            if arrived { self.finish() }
        }
        animation = timer; RunLoop.main.add(timer, forMode: .common)
    }

    private func settle(_ overlay: TavernDragOverlay, to target: NSRect, limits: @escaping () -> NSRect) {
        guard TavernMotion.enabled else { finish(); return }
        animation?.invalidate()
        overlay.returning = true
        let from = overlay.lift.frame
        let destination = NSRect(x: target.midX - from.width / 2, y: target.midY - from.height / 2, width: from.width, height: from.height)
        let start = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self, weak overlay] timer in
            guard let self, let overlay, self.overlay === overlay else { timer.invalidate(); return }
            guard overlay.window?.isVisible == true, overlay.window?.isKeyWindow == true else { self.cancel(); return }
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            overlay.lift.frame = TavernDragGeometry.settling(from: from, to: destination, elapsed: elapsed, inside: limits())
            overlay.advanceGather(inside: limits())
            if elapsed >= 0.36 { self.finish() }
        }
        animation = timer; RunLoop.main.add(timer, forMode: .common)
    }
}

/// Небольшой захват доступен и у обычных shell-панелей, которых нет в списке агентов.
final class TavernPaneGrip: NSButton {
    var onPress: ((NSButton, NSEvent) -> Void)?
    var contextMenu: (() -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }
    override func rightMouseDown(with event: NSEvent) {
        if let menu = contextMenu?() { TavernContextMenu.popUp(menu, with: event, for: self) }
    }
    override func mouseDown(with event: NSEvent) { onPress?(self, event) }
    override func draw(_ dirtyRect: NSRect) {
        TavernAppearance.chrome.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        TavernAppearance.secondary.setFill()
        for x in [CGFloat(7), 12, 17] {
            for y in [CGFloat(5), 9] { NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 2, height: 2)).fill() }
        }
    }
}
