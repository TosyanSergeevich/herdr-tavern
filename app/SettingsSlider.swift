import AppKit

/// Native slider tracking, keyboard navigation and accessibility with Tavern chrome.
final class TavernSettingsSlider: NSSlider {
    var onInteraction: (() -> Void)?
    fileprivate private(set) var isTrackingMouse = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installCell()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installCell()
    }

    private func installCell() {
        let styled = TavernSettingsSliderCell()
        if let previous = cell as? NSSliderCell {
            styled.minValue = previous.minValue
            styled.maxValue = previous.maxValue
            styled.numberOfTickMarks = previous.numberOfTickMarks
            styled.tickMarkPosition = previous.tickMarkPosition
            styled.allowsTickMarkValuesOnly = previous.allowsTickMarkValuesOnly
            styled.altIncrementValue = previous.altIncrementValue
            styled.controlSize = previous.controlSize
            styled.isContinuous = previous.isContinuous
            styled.isEnabled = previous.isEnabled
            styled.target = previous.target
            styled.action = previous.action
            styled.doubleValue = previous.doubleValue
        }
        styled.sliderType = .linear
        styled.isVertical = false
        cell = styled
        focusRingType = .exterior
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: numberOfTickMarks > 0 ? 240 : 96, height: numberOfTickMarks > 0 ? 32 : 24)
    }

    override var numberOfTickMarks: Int {
        didSet { invalidateIntrinsicContentSize() }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isTrackingMouse = true
        needsDisplay = true
        defer {
            isTrackingMouse = false
            needsDisplay = true
            // Continuous target actions have already applied the final volume.
            onInteraction?()
        }
        super.mouseDown(with: event)
    }

    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        let sent = super.sendAction(action, to: target)
        // Mouse tracking can dispatch many live actions, but has one completion.
        // Native keyboard and AX actions reach this path without mouse tracking.
        if isEnabled && !isTrackingMouse { onInteraction?() }
        return sent
    }

    override var focusRingMaskBounds: NSRect {
        guard let sliderCell = cell as? NSSliderCell else { return bounds }
        return sliderCell.knobRect(flipped: isFlipped).insetBy(dx: -2, dy: -2)
    }

    override func drawFocusRingMask() {
        NSBezierPath(ovalIn: focusRingMaskBounds).fill()
    }
}

private final class TavernSettingsSliderCell: NSSliderCell {
    // Shared vector materials: no images, texture generation or resource reads.
    private static let knobGradient = NSGradient(starting: TavernAppearance.accent,
                                                ending: TavernAppearance.border)!
    private static let pressedGradient = NSGradient(starting: TavernAppearance.border,
                                                   ending: TavernAppearance.accent)!
    private static let disabledBorder = TavernAppearance.border.withAlphaComponent(0.45)
    private static let disabledGold = TavernAppearance.accent.withAlphaComponent(0.35)
    private static let recessed = NSColor.black.withAlphaComponent(0.48)
    private static let highlight = TavernAppearance.text.withAlphaComponent(0.55)

    private var pixel: CGFloat { 1 / (controlView?.window?.backingScaleFactor ?? 1) }

    private func aligned(_ rect: NSRect) -> NSRect {
        guard let view = controlView else { return rect.integral }
        let backing = view.convertToBacking(rect)
        let snapped = NSRect(x: backing.minX.rounded(), y: backing.minY.rounded(),
                             width: backing.width.rounded(), height: backing.height.rounded())
        return view.convertFromBacking(snapped)
    }

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = aligned(NSRect(x: rect.minX, y: rect.midY - 3, width: rect.width, height: 6))
        guard track.width > 0 else { return }
        let outline = NSBezierPath(roundedRect: track.insetBy(dx: pixel / 2, dy: pixel / 2),
                                   xRadius: 3, yRadius: 3)
        Self.recessed.setFill()
        outline.fill()
        (isEnabled ? TavernAppearance.border : Self.disabledBorder).setStroke()
        outline.lineWidth = pixel
        outline.stroke()

        // Native knob geometry is also used for hit testing, ticks and RTL layout.
        let knobX = knobRect(flipped: flipped).midX
        let inner = track.insetBy(dx: pixel, dy: pixel)
        let rightToLeft = controlView?.userInterfaceLayoutDirection == .rightToLeft
        let fillX = min(inner.maxX, max(inner.minX, knobX))
        let fill = aligned(NSRect(x: rightToLeft ? fillX : inner.minX, y: inner.minY,
                                  width: rightToLeft ? inner.maxX - fillX : fillX - inner.minX,
                                  height: inner.height))
        if fill.width > 0 {
            (isEnabled ? TavernAppearance.accent : Self.disabledGold).setFill()
            NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
        }
    }

    override func drawTickMarks() {
        guard numberOfTickMarks > 0 else { return }
        for index in 0..<numberOfTickMarks {
            let native = rectOfTickMark(at: index)
            let tick = aligned(NSRect(x: native.midX - pixel / 2, y: native.midY - 2,
                                      width: pixel, height: 4))
            let selected = tickMarkValue(at: index) <= doubleValue
            (isEnabled ? (selected ? TavernAppearance.accent : TavernAppearance.border)
                       : Self.disabledBorder).setFill()
            tick.fill()
        }
    }

    override func drawKnob(_ knobRect: NSRect) {
        let side = min(16, min(knobRect.width, knobRect.height))
        let knob = aligned(NSRect(x: knobRect.midX - side / 2, y: knobRect.midY - side / 2,
                                  width: side, height: side)).insetBy(dx: pixel / 2, dy: pixel / 2)
        let path = NSBezierPath(ovalIn: knob)
        let pressed = (controlView as? TavernSettingsSlider)?.isTrackingMouse == true || isHighlighted
        if isEnabled {
            (pressed ? Self.pressedGradient : Self.knobGradient).draw(in: path, angle: 90)
        } else {
            TavernAppearance.chrome.setFill()
            path.fill()
        }
        (isEnabled ? TavernAppearance.accent : Self.disabledBorder).setStroke()
        path.lineWidth = pixel
        path.stroke()
        let inset = knob.insetBy(dx: 4, dy: 4)
        (isEnabled ? (pressed ? TavernAppearance.chrome : Self.highlight) : Self.disabledGold).setFill()
        NSBezierPath(ovalIn: inset).fill()
    }
}
