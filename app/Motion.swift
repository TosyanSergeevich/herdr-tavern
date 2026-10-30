import AppKit
import QuartzCore

// Только оболочка. Геометрия/действия меняются сразу; Core Animation сглаживает изображение.
enum TavernMotion {
    static var enabled: Bool {
        _ = policyObserver
        return TavernMotionSettings.shared.enabled
    }
    private static let animatedLayers = NSHashTable<CALayer>.weakObjects()
    private static let windowBehaviors = NSMapTable<NSWindow, NSNumber>.weakToStrongObjects()
    private static var removals: [UUID: () -> Void] = [:]
    private static let policyObserver = NotificationCenter.default.addObserver(
        forName: .tavernMotionDidChange, object: nil, queue: .main
    ) { _ in
        for window in windowBehaviors.keyEnumerator().allObjects as? [NSWindow] ?? [] {
            updateWindow(window)
        }
        guard !TavernMotionSettings.shared.enabled else { return }
        for layer in animatedLayers.allObjects {
            for key in ["appearance", "opacity", "layout"] { layer.removeAnimation(forKey: key) }
        }
        let completions = Array(removals.values)
        removals.removeAll()
        completions.forEach { $0() }
    }
    static let hoverDuration: CFTimeInterval = 0.14
    static let selectionDuration: CFTimeInterval = 0.18
    static var directLayout = false
    static func configureWindow(_ window: NSWindow) {
        if windowBehaviors.object(forKey: window) == nil {
            windowBehaviors.setObject(NSNumber(value: window.animationBehavior.rawValue), forKey: window)
        }
        _ = policyObserver
        updateWindow(window)
    }

    private static func updateWindow(_ window: NSWindow) {
        guard let original = windowBehaviors.object(forKey: window),
              let behavior = NSWindow.AnimationBehavior(rawValue: original.intValue) else { return }
        window.animationBehavior = TavernMotionSettings.shared.enabled ? behavior : .none
    }


    static func animate(_ layer: CALayer, key: String, to value: Any, duration: CFTimeInterval) {
        if enabled, let target = value as? NSObject,
           let current = layer.value(forKeyPath: key) as? NSObject, current.isEqual(target) { return }
        let previous = layer.presentation()?.value(forKeyPath: key) ?? layer.value(forKeyPath: key)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: key)
        CATransaction.commit()
        guard enabled, duration > 0 else {
            layer.removeAnimation(forKey: key)
            return
        }
        let transition = CABasicAnimation(keyPath: key)
        transition.fromValue = previous
        transition.toValue = value
        transition.duration = duration
        transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
        animatedLayers.add(layer)
        layer.add(transition, forKey: key)
    }

    static func appear(_ view: NSView) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let wasDisappearing = layer.opacity < 1 || layer.animation(forKey: "opacity") != nil
        let start: Float = wasDisappearing ? (layer.presentation()?.opacity ?? layer.opacity) : 0
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.opacity = 1; layer.removeAnimation(forKey: "opacity")
        CATransaction.commit()
        guard enabled, view.window?.isVisible == true, !view.isHiddenOrHasHiddenAncestor else {
            layer.removeAnimation(forKey: "appearance")
            return
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = start; fade.toValue = Float(1)
        fade.duration = 0.18; fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        animatedLayers.add(layer)
        layer.add(fade, forKey: "appearance")
    }

    static func disappear(_ view: NSView, completion: @escaping () -> Void) {
        guard enabled, view.window?.isVisible == true, !view.isHiddenOrHasHiddenAncestor else { completion(); return }
        view.wantsLayer = true
        guard let layer = view.layer else { completion(); return }
        animate(layer, key: "opacity", to: Float(0), duration: 0.12)
        let id = UUID()
        removals[id] = completion
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            removals.removeValue(forKey: id)?()
        }
    }

    static func move(_ view: NSView, to frame: NSRect) {
        guard view.frame != frame else { return }
        let shouldAnimate = enabled && !directLayout && view.frame.size == frame.size
            && view.window?.isVisible == true && view.window?.inLiveResize == false
        if shouldAnimate { view.wantsLayer = true }
        let previous = view.layer?.presentation()?.position ?? view.layer?.position
        view.frame = frame
        guard shouldAnimate, let layer = view.layer, let previous, previous != layer.position else {
            view.layer?.removeAnimation(forKey: "layout")
            return
        }
        let movement = CABasicAnimation(keyPath: "position")
        movement.fromValue = NSValue(point: previous)
        movement.toValue = NSValue(point: layer.position)
        movement.duration = 0.18; movement.timingFunction = CAMediaTimingFunction(name: .easeOut)
        animatedLayers.add(layer)
        layer.add(movement, forKey: "layout")
    }
}

/// Busy state stays visible when motion is disabled; only the spinning is stopped.
final class TavernProgressIndicator: NSProgressIndicator {
    private var running = false
    private var motionObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        isDisplayedWhenStopped = true
        motionObserver = NotificationCenter.default.addObserver(
            forName: .tavernMotionDidChange, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshMotion() }
    }

    required init?(coder: NSCoder) { fatalError("TavernProgressIndicator requires a frame") }
    deinit {
        if let motionObserver { NotificationCenter.default.removeObserver(motionObserver) }
    }

    override func startAnimation(_ sender: Any?) {
        running = true
        refreshMotion()
    }

    override func stopAnimation(_ sender: Any?) {
        running = false
        super.stopAnimation(sender)
    }

    private func refreshMotion() {
        if running && TavernMotion.enabled { super.startAnimation(nil) }
        else { super.stopAnimation(nil) }
    }
}
