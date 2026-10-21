import AppKit
import QuartzCore

// Только оболочка. Геометрия/действия меняются сразу; Core Animation сглаживает изображение.
enum TavernMotion {
    static var enabled: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static let hoverDuration: CFTimeInterval = 0.14
    static let selectionDuration: CFTimeInterval = 0.18
    static var directLayout = false

    static func animate(_ layer: CALayer, key: String, to value: Any, duration: CFTimeInterval) {
        if enabled, let target = value as? NSObject,
           let current = layer.value(forKeyPath: key) as? NSObject, current.isEqual(target) { return }
        let previous = layer.presentation()?.value(forKeyPath: key) ?? layer.value(forKeyPath: key)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: key)
        CATransaction.commit()
        guard enabled, duration > 0 else { layer.removeAnimation(forKey: key); return }
        let transition = CABasicAnimation(keyPath: key)
        transition.fromValue = previous
        transition.toValue = value
        transition.duration = duration
        transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
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
        layer.add(fade, forKey: "appearance")
    }

    static func disappear(_ view: NSView, completion: @escaping () -> Void) {
        guard enabled, view.window?.isVisible == true, !view.isHiddenOrHasHiddenAncestor else { completion(); return }
        view.wantsLayer = true
        guard let layer = view.layer else { completion(); return }
        animate(layer, key: "opacity", to: Float(0), duration: 0.12)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: completion)
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
        layer.add(movement, forKey: "layout")
    }
}
