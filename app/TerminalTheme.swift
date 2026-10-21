import AppKit

func rgb(_ value: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
            blue: CGFloat(value & 255) / 255, alpha: 1)
}

// Kanagawa Wave: значения из установленной темы Ghostty.
// Не требует Ghostty при запуске и не заменяет явные RGB-цвета приложений.
enum TerminalTheme {
    static let background = rgb(0x1f1f28)
    static let foreground = rgb(0xdcd7ba)
    static let cursor = rgb(0xdcd7ba)
    static let cursorText = rgb(0x1f1f28)
    static let selection = rgb(0xdcd7ba)
    static let selectionText = rgb(0x1f1f28)
    static let indexed: [NSColor] = {
        let ansi: [UInt32] = [
            0x090618, 0xc34043, 0x76946a, 0xc0a36e, 0x7e9cd8, 0x957fb8, 0x6a9589, 0xc8c093,
            0x727169, 0xe82424, 0x98bb6c, 0xe6c384, 0x7fb4ca, 0x938aa9, 0x7aa89f, 0xdcd7ba
        ]
        var colors = ansi.map(rgb)
        colors.reserveCapacity(256)
        let levels: [UInt32] = [0, 95, 135, 175, 215, 255]
        for r in levels { for g in levels { for b in levels { colors.append(rgb(r << 16 | g << 8 | b)) } } }
        for index in 0..<24 {
            let gray = UInt32(8 + index * 10)
            colors.append(rgb(gray << 16 | gray << 8 | gray))
        }
        return colors
    }()
}

func packedColor(_ value: UInt32, foreground: Bool) -> NSColor {
    if value == 0 { return foreground ? TerminalTheme.foreground : TerminalTheme.background }
    if value <= 16 { return TerminalTheme.indexed[Int(value - 1)] }
    if value & 0xff000000 == 0x02000000 { return rgb(value & 0xffffff) }
    if value & 0xff000000 == 0x01000000 { return TerminalTheme.indexed[Int(value & 255)] }
    return foreground ? TerminalTheme.foreground : TerminalTheme.background
}
