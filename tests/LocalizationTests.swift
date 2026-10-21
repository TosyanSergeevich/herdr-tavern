import Foundation

@main
struct LocalizationTests {
    static func main() throws {
        guard CommandLine.arguments.count == 2,
              let bundle = Bundle(path: CommandLine.arguments[1]) else {
            fatalError("Pass the path to a built Herdr Tavern.app")
        }
        let suiteName = "HerdrTavern.LocalizationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = try TavernLocalization(defaults: defaults, bundle: bundle)
        precondition(initial.language == .english)
        initial.setLanguage(.russian)
        let reopened = try TavernLocalization(defaults: defaults, bundle: bundle)
        precondition(reopened.language == .russian, "The explicit choice must survive reopening")
        reopened.setLanguage(.english)
        let reopenedAgain = try TavernLocalization(defaults: defaults, bundle: bundle)
        precondition(reopenedAgain.language == .english, "Switching back must also persist")
        print("PASS: explicit language selection survives reopening")

        defaults.set("unsupported-language", forKey: TavernLocalization.preferenceKey)
        let unsupported = try TavernLocalization(defaults: defaults, bundle: bundle)
        precondition(unsupported.language == .english, "An unsupported saved language must not break startup")
        print("PASS: unsupported saved language uses English")

        defaults.set("ru", forKey: TavernLocalization.preferenceKey)
        defaults.set(["en"], forKey: "AppleLanguages")
        let explicitChoice = try TavernLocalization(defaults: defaults, bundle: bundle)
        precondition(explicitChoice.language == .russian, "The app selection takes precedence over system language hints")
        print("PASS: the explicit app choice takes precedence")
    }
}
