import Foundation

@main struct TerminalSettingsTests {
    private static func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = "TerminalSettingsTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    private static func defaultsAndPersistence() {
        withDefaults { defaults in
            let settings = TavernTerminalSettings(defaults: defaults)
            precondition(settings.typography == TerminalTypography(size: 16, weight: .medium))
            var changes: [TerminalTypography] = []
            settings.onChange = { changes.append($0) }
            settings.set(size: 19, weight: .regular)
            precondition(changes == [TerminalTypography(size: 19, weight: .regular)])
            precondition(TavernTerminalSettings(defaults: defaults).typography == settings.typography)
            settings.set(size: 19, weight: .regular)
            precondition(changes.count == 1, "An unchanged value must not notify the surface")
            settings.set(size: 19, weight: .semibold)
            precondition(changes.last == TerminalTypography(size: 19, weight: .semibold))
            settings.reset()
            precondition(settings.typography == TavernTerminalSettings.defaultTypography)
            precondition(TavernTerminalSettings(defaults: defaults).typography == settings.typography)
            precondition(changes.count == 3)
            settings.reset()
            precondition(changes.count == 3, "Reset at defaults must not notify again")
        }
        print("PASS: defaults, persistence, weight-only changes, reset and unchanged notifications")
    }

    private static func setterBounds() {
        withDefaults { defaults in
            let settings = TavernTerminalSettings(defaults: defaults)
            settings.set(size: Int.min, weight: .regular)
            precondition(settings.typography.size == 12)
            precondition(TavernTerminalSettings(defaults: defaults).typography.size == 12)
            settings.set(size: Int.max, weight: .semibold)
            precondition(settings.typography.size == 24)
            precondition(TavernTerminalSettings(defaults: defaults).typography.size == 24)
        }
        print("PASS: setter clamps extreme integer sizes and persists the clamped result")
    }

    private static func persistedSize(_ raw: Any, expected: Int, scenario: String) {
        withDefaults { defaults in
            defaults.set(raw, forKey: "HerdrTavern.terminal.fontSize")
            precondition(TavernTerminalSettings(defaults: defaults).typography.size == expected, scenario)
        }
        print("PASS: \(scenario)")
    }

    private static func unknownWeightAndSuiteIsolation() {
        withDefaults { first in
            withDefaults { second in
                first.set("heavy", forKey: "HerdrTavern.terminal.fontWeight")
                precondition(TavernTerminalSettings(defaults: first).typography.weight == .medium)
                TavernTerminalSettings(defaults: first).set(size: 24, weight: .semibold)
                precondition(TavernTerminalSettings(defaults: second).typography == TavernTerminalSettings.defaultTypography)
            }
        }
        print("PASS: unknown weights default to Medium and UserDefaults suites remain isolated")
    }

    private static func everyWeightPersists() {
        withDefaults { defaults in
            let settings = TavernTerminalSettings(defaults: defaults)
            for weight in TerminalFontWeight.allCases {
                settings.set(size: 18, weight: weight)
                precondition(TavernTerminalSettings(defaults: defaults).typography ==
                    TerminalTypography(size: 18, weight: weight),
                    "Every selectable weight must survive a new settings instance")
            }
        }
        print("PASS: all selectable weights persist without changing the selected size")
    }

    static func main() {
        defaultsAndPersistence()
        setterBounds()
        everyWeightPersists()
        persistedSize(-100, expected: 12, scenario: "persisted sizes below range clamp to 12")
        persistedSize(100, expected: 24, scenario: "persisted sizes above range clamp to 24")
        persistedSize(1e100, expected: 24, scenario: "oversized integral numeric values clamp before Int conversion")
        persistedSize(13.5, expected: 16, scenario: "fractional persisted sizes use the default")
        persistedSize("large", expected: 16, scenario: "corrupt string sizes use the default")
        persistedSize(true, expected: 16, scenario: "Boolean sizes are not treated as integers")
        persistedSize([12], expected: 16, scenario: "invalid collection sizes use the default")
        unknownWeightAndSuiteIsolation()
    }
}
