import AppKit

private final class TerminalSettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

final class TerminalSettingsView: NSView, NSTextFieldDelegate {
    private let settings: TavernTerminalSettings
    private let fonts: TerminalFonts
    private let sizeField = NSTextField(string: "")
    private let sizeStepper = NSStepper()
    private let weightSlider = TavernSettingsSlider(frame: .zero)
    private let weightName = NSTextField(labelWithString: "")
    private let preview = NSStackView()
    private let ordinarySample = NSTextField(labelWithString: "")
    private let boldSample = NSTextField(labelWithString: "")
    private let obliqueSample = NSTextField(labelWithString: "")
    private let resetButton = TavernButton(title: "", target: nil, action: nil)
    private var languageUpdates: [() -> Void] = []
    private var previewTypography: TerminalTypography?
    var onInteraction: (() -> Void)?

    init(settings: TavernTerminalSettings, fonts: TerminalFonts) {
        self.settings = settings
        self.fonts = fonts
        super.init(frame: .zero)
        setAccessibilityIdentifier("terminalSettings.content")
        buildContent()
        refreshLanguage()
    }

    required init?(coder: NSCoder) { fatalError("TerminalSettingsView requires terminal settings and fonts") }

    func refresh() {
        let typography = settings.typography
        sizeField.integerValue = typography.size
        sizeStepper.integerValue = typography.size
        weightSlider.doubleValue = Double(TerminalFontWeight.allCases.firstIndex(of: typography.weight) ?? 0)
        weightName.stringValue = L("settings.terminal.weight.\(typography.weight.rawValue)")
        weightSlider.setAccessibilityValueDescription(weightName.stringValue)
        resetButton.isEnabled = typography != TavernTerminalSettings.defaultTypography
        updatePreview()
    }

    func refreshLanguage() {
        languageUpdates.forEach { $0() }
        sizeField.setAccessibilityLabel(L("settings.terminal.size"))
        sizeField.toolTip = L("settings.terminal.sizeHint")
        sizeStepper.setAccessibilityLabel(L("settings.terminal.size"))
        weightSlider.setAccessibilityLabel(L("settings.terminal.weight"))
        resetButton.title = L("settings.terminal.reset")
        resetButton.setAccessibilityLabel(resetButton.title)
        preview.setAccessibilityLabel(L("settings.terminal.preview"))
        ordinarySample.stringValue = L("settings.terminal.sample.ordinary")
        boldSample.stringValue = L("settings.terminal.sample.bold")
        obliqueSample.stringValue = L("settings.terminal.sample.oblique")
        refresh()
    }

    private func updatePreview() {
        let typography = settings.typography
        guard previewTypography != typography else { return }
        let configured = fonts.configured(size: CGFloat(typography.size), weight: typography.weight)
        ordinarySample.font = configured.regular
        boldSample.font = configured.bold
        obliqueSample.font = configured.italic
        previewTypography = typography
    }

    private func buildContent() {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        let document = TerminalSettingsDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        let content = NSStackView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        document.addSubview(content)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20)
        ])
        addFullWidth(localizedLabel("settings.terminal", font: TavernAppearance.headingFont), to: content)
        addFullWidth(localizedLabel("settings.terminal.description"), to: content)

        sizeField.delegate = self
        sizeField.font = TavernAppearance.smallFont
        sizeField.textColor = TavernAppearance.text
        sizeField.backgroundColor = TavernAppearance.chrome
        sizeField.alignment = .right
        sizeField.setAccessibilityIdentifier("terminalSettings.size")
        sizeField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        sizeStepper.minValue = Double(TavernTerminalSettings.sizeRange.lowerBound)
        sizeStepper.maxValue = Double(TavernTerminalSettings.sizeRange.upperBound)
        sizeStepper.increment = 1
        sizeStepper.valueWraps = false
        sizeStepper.target = self
        sizeStepper.action = #selector(changeSize(_:))
        sizeStepper.setAccessibilityIdentifier("terminalSettings.sizeStepper")
        let sizeControls = NSStackView(views: [sizeField, sizeStepper, localizedLabel("settings.terminal.points")])
        sizeControls.orientation = .horizontal
        sizeControls.alignment = .centerY
        sizeControls.spacing = 8
        weightSlider.target = self
        weightSlider.action = #selector(changeWeight(_:))
        weightSlider.minValue = 0
        weightSlider.maxValue = Double(TerminalFontWeight.allCases.count - 1)
        weightSlider.numberOfTickMarks = TerminalFontWeight.allCases.count
        weightSlider.tickMarkPosition = .below
        weightSlider.allowsTickMarkValuesOnly = true
        weightSlider.isContinuous = true
        weightSlider.onInteraction = { [weak self] in self?.onInteraction?() }
        weightSlider.setAccessibilityIdentifier("terminalSettings.weight")
        weightSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        weightName.font = TavernAppearance.smallFont
        weightName.textColor = TavernAppearance.text
        weightName.setAccessibilityIdentifier("terminalSettings.weight.name")
        let weightControls = NSStackView(views: [weightName, weightSlider])
        weightControls.orientation = .vertical
        weightControls.alignment = .leading
        weightControls.spacing = 4
        weightSlider.widthAnchor.constraint(equalTo: weightControls.widthAnchor).isActive = true
        let controls = NSGridView(views: [
            [localizedLabel("settings.terminal.size"), sizeControls],
            [localizedLabel("settings.terminal.weight"), weightControls]
        ])
        controls.columnSpacing = 18
        controls.rowSpacing = 12
        controls.yPlacement = .center
        addFullWidth(boardPanel(containing: controls), to: content)

        addFullWidth(localizedLabel("settings.terminal.preview"), to: content)
        preview.orientation = .vertical
        preview.alignment = .leading
        preview.spacing = 10
        preview.setAccessibilityIdentifier("terminalSettings.preview")
        for (sample, suffix) in [(ordinarySample, "ordinary"), (boldSample, "bold"), (obliqueSample, "oblique")] {
            sample.textColor = TavernAppearance.text
            sample.setAccessibilityIdentifier("terminalSettings.preview.\(suffix)")
            sample.setContentCompressionResistancePriority(.required, for: .vertical)
            sample.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addFullWidth(sample, to: preview)
        }
        addFullWidth(boardPanel(containing: preview), to: content)
        resetButton.prepare(style: .utility)
        resetButton.target = self
        resetButton.action = #selector(resetTypography(_:))
        resetButton.setAccessibilityIdentifier("terminalSettings.reset")
        resetButton.heightAnchor.constraint(equalToConstant: 34).isActive = true
        content.addArrangedSubview(resetButton)
        addFullWidth(localizedLabel("settings.terminal.immediate"), to: content)
    }

    private func localizedLabel(_ key: String, font: NSFont = TavernAppearance.detailFont) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: L(key))
        label.font = font
        label.textColor = font == TavernAppearance.headingFont ? TavernAppearance.text : TavernAppearance.secondary
        label.maximumNumberOfLines = 0
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        languageUpdates.append { [weak label] in label?.stringValue = L(key) }
        return label
    }

    private func addFullWidth(_ view: NSView, to stack: NSStackView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func boardPanel(containing content: NSView) -> NSView {
        let panel = TavernBoardPanel()
        panel.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: panel.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -12)
        ])
        return panel
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === sizeField else { return }
        let text = sizeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let size = Int(text), TavernTerminalSettings.sizeRange.contains(size) {
            if size != settings.typography.size { onInteraction?() }
            settings.set(size: size, weight: settings.typography.weight)
        } else {
            NSSound.beep()
        }
        refresh()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === sizeField, commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        refresh()
        window?.makeFirstResponder(sizeField)
        return true
    }

    @objc private func changeSize(_ sender: NSStepper) {
        onInteraction?()
        settings.set(size: sender.integerValue, weight: settings.typography.weight)
        refresh()
    }

    @objc private func changeWeight(_ sender: NSSlider) {
        let weights = TerminalFontWeight.allCases
        let index = min(max(Int(sender.doubleValue.rounded()), 0), weights.count - 1)
        sender.doubleValue = Double(index)
        guard settings.typography.weight != weights[index] else { return }
        settings.set(size: settings.typography.size, weight: weights[index])
        refresh()
    }

    @objc private func resetTypography(_ sender: NSButton) {
        onInteraction?()
        settings.reset()
        refresh()
    }
}
