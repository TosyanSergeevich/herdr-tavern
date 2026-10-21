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
/// Оригиналы полностью скрыты на всё время захвата, ответа сервера и пружины.
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

    func refresh() {
        guard sessionValid?() != false else { cancel(); return }
        refreshVisual?()
        placeWhenLayoutChanges?()
    }

    private func conceal(_ views: [NSView]) {
        let ids = Set(views.map { ObjectIdentifier($0) })
        for id in Array(suppressed.keys) where !ids.contains(id) {
            if let saved = suppressed.removeValue(forKey: id), saved.view.superview != nil {
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

    private func image(of view: NSView) -> NSImage? {
        let hidden = view.isHidden
        view.isHidden = false
        defer { view.isHidden = hidden }
        if let card = view as? TavernButton { return card.dragImage() }
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        return image
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
        // Новый захват отменяет ещё не завершённую пружину/ожидание старого.
        finish()
        cancelled = false; tracking = true
        defer { tracking = false }
        let start = root.convert(event.locationInWindow, from: nil)
        let sourceRect = button.convert(button.bounds, to: root)
        let sourceID = button.accessibilityIdentifier()
        var point = start, lifted: TavernDragOverlay?, selection: TavernDropProposal?
        var offset = NSPoint.zero, bundled = false
        var lastScroll = ProcessInfo.processInfo.systemUptime
        var cursorPushed = false
        defer { if cursorPushed { NSCursor.pop() } }
        while valid(), !cancelled, window.isVisible, window.isKeyWindow {
            var released = false
            let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown],
                                        until: Date(timeIntervalSinceNow: 1.0 / 60.0), inMode: .eventTracking, dequeue: true)
            if let next {
                if next.type == .keyDown {
                    if next.keyCode == 53 { cancelled = true; break }
                    continue
                }
                point = root.convert(next.locationInWindow, from: nil)
                if next.type == .leftMouseUp {
                    if lifted == nil {
                        if button.convert(button.bounds, to: root).contains(point) { button.performClick(nil) }
                        return true
                    }
                    released = true
                }
            }
            if lifted == nil, hypot(point.x - start.x, point.y - start.y) >= 6 {
                let layer = TavernDragOverlay(frame: root.bounds)
                layer.autoresizingMask = [.width, .height]
                selection = proposal(point)
                bundled = bundleAt?(point, selection) ?? false
                refreshVisual = { [weak self, weak layer] in
                    guard let self, let layer else { return }
                    let available = members?() ?? [button]
                    let selected = available.first { $0.accessibilityIdentifier() == sourceID } ?? button
                    // Выбранная карточка всегда лежит сверху, даже при захвате середины группы.
                    let cards = bundled ? [selected] + available.filter { $0 !== selected } : [selected]
                    let images = visual.map { $0().map { [$0] } ?? [] } ?? cards.compactMap { self.image(of: $0) }
                    guard images.count == (visual == nil ? cards.count : 1), !images.isEmpty else {
                        self.cancel(); return
                    }
                    let oldFrames = layer.renderedCardFrames()
                    let oldCards = layer.cards
                    let wasBundled = layer.lift.bundled
                    if !layer.returning {
                        layer.lift.configure(images: images, bundled: bundled)
                        if layer.lift.frame.width > 0, layer.lift.frame.height > 0 {
                            let natural = layer.lift.naturalSize
                            let scale = min(layer.lift.frame.width / natural.width, layer.lift.frame.height / natural.height)
                            layer.lift.frame = TavernDragGeometry.fitted(NSRect(origin: layer.lift.frame.origin,
                                size: NSSize(width: natural.width * scale, height: natural.height * scale)), inside: limits())
                        }
                        if layer.lift.bundled && !wasBundled {
                            let frames = cards.map { card -> NSRect in
                                if let index = oldCards.firstIndex(where: { $0 === card }), index < oldFrames.count {
                                    return oldFrames[index]
                                }
                                return TavernDragGeometry.fitted(card.convert(card.bounds, to: root), inside: limits())
                            }
                            layer.gather(from: frames)
                            self.startGatherClock(layer, limits: limits)
                        } else if !layer.lift.bundled {
                            layer.stopFlight()
                        } else if !layer.flight.images.isEmpty {
                            layer.flight.images = images
                        }
                    }
                    layer.cards = cards
                    self.conceal(cards.map { $0 as NSView } + (connections?(cards) ?? []))
                }
                overlay = layer; lifted = layer
                sessionValid = valid
                escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] key in
                    guard key.keyCode == 53, self?.overlay != nil else { return key }
                    if self?.tracking == false { self?.returnVisual?() }
                    else { self?.cancelled = true }
                    return nil
                }
                refresh()
                returnVisual = { [weak self, weak layer] in
                    guard let self, let layer, self.overlay === layer else { return }
                    self.cancelled = true
                    self.placeAtCards(layer, root: root, limits: limits)
                }
                guard !layer.lift.images.isEmpty else { finish(); return true }
                let size = layer.lift.naturalSize
                offset = visual == nil
                    ? NSPoint(x: start.x - sourceRect.minX, y: start.y - sourceRect.minY)
                    : NSPoint(x: size.width / 2, y: size.height - 10)
                root.addSubview(layer)
                NSCursor.closedHand.push(); cursorPushed = true
            }
            guard let lifted else { continue }
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastScroll >= 1.0 / 30.0 { autoscroll(point); lastScroll = now }
            let bounds = limits()
            selection = bounds.contains(point) ? proposal(point) : nil
            let useBundle = bundleAt?(point, selection) ?? false
            if useBundle != bundled {
                bundled = useBundle; refresh()
            }
            let natural = lifted.lift.naturalSize
            let maximumWidth: CGFloat = visual == nil ? bounds.width : min(bounds.width, 260)
            let maximumHeight: CGFloat = visual == nil ? bounds.height : min(bounds.height, 120)
            let scale = min(1, maximumWidth / max(1, natural.width), maximumHeight / max(1, natural.height))
            let size = NSSize(width: natural.width * scale, height: natural.height * scale)
            let anchorY = offset.y + (lifted.lift.bundled ? 12 : 0)
            lifted.lift.frame = TavernDragGeometry.clamped(NSRect(x: point.x - offset.x * scale, y: point.y - anchorY * scale,
                                                                 width: size.width, height: size.height), inside: bounds)
            lifted.advanceGather(inside: bounds)
            lifted.update(limits: bounds, proposal: selection)
            if released { break }
        }
        guard let lifted, overlay === lifted else { return true }
        if !cancelled, valid(), window.isVisible, window.isKeyWindow, let selection {
            // Сервер не ждёт пружины; оригиналы остаются скрыты до её завершения.
            if visual == nil {
                let previous = lifted.cards.map { $0.convert($0.bounds, to: root) }
                // Новая раскладка может опередить ответ публичного API.
                // Начинаем постановку сразу по её публикации, а не ждём второго канала.
                placeWhenLayoutChanges = { [weak self, weak lifted, weak root] in
                    guard let self, let lifted, let root, !self.tracking, !lifted.returning,
                          self.overlay === lifted else { return }
                    let moved = lifted.cards.enumerated().contains { index, card in
                        index >= previous.count || card.convert(card.bounds, to: root) != previous[index]
                    }
                    if moved { self.placeAtCards(lifted, root: root, limits: limits) }
                }
            }
            perform(selection.target) { [weak self, weak lifted] changed in
                guard let self, let lifted, self.overlay === lifted, !self.cancelled else { return }
                self.refresh()
                guard self.overlay === lifted else { return }
                if changed, visual != nil {
                    let size = lifted.lift.frame.size
                    let destination = NSRect(x: selection.rect.midX - size.width / 2,
                                             y: selection.rect.midY - size.height / 2, width: size.width, height: size.height)
                    self.settle(lifted, to: destination, limits: limits)
                } else if !lifted.returning {
                    self.placeAtCards(lifted, root: root, limits: limits)
                }
            }
        } else {
            placeAtCards(lifted, root: root, limits: limits)
        }
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
