import Foundation
import CoreFoundation

enum TerminalFontWeight: String, CaseIterable {
    case thin, extraLight, light, regular, medium, semibold, bold, extraBold
}

struct TerminalTypography: Equatable {
    let size: Int
    let weight: TerminalFontWeight
}

final class TavernTerminalSettings {
    static let sizeRange = 12...24
    static let defaultTypography = TerminalTypography(size: 16, weight: .medium)
    private static let sizeKey = "HerdrTavern.terminal.fontSize"
    private static let weightKey = "HerdrTavern.terminal.fontWeight"

    private let defaults: UserDefaults
    private(set) var typography: TerminalTypography
    var onChange: ((TerminalTypography) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var size = Self.defaultTypography.size
        if let number = defaults.object(forKey: Self.sizeKey) as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID() {
            let value = number.doubleValue
            if value.isFinite && value.rounded() == value {
                // Clamp before conversion so even corrupt, oversized numbers are safe.
                size = Int(min(Double(Self.sizeRange.upperBound), max(Double(Self.sizeRange.lowerBound), value)))
            }
        }
        let weight = defaults.string(forKey: Self.weightKey)
            .flatMap(TerminalFontWeight.init(rawValue:)) ?? Self.defaultTypography.weight
        typography = TerminalTypography(size: size, weight: weight)
    }

    func set(size: Int, weight: TerminalFontWeight) {
        let value = TerminalTypography(size: min(Self.sizeRange.upperBound, max(Self.sizeRange.lowerBound, size)),
                                       weight: weight)
        defaults.set(value.size, forKey: Self.sizeKey)
        defaults.set(value.weight.rawValue, forKey: Self.weightKey)
        guard value != typography else { return }
        typography = value
        onChange?(value)
    }

    func reset() {
        set(size: Self.defaultTypography.size, weight: Self.defaultTypography.weight)
    }
}
