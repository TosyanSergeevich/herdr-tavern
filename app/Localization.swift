import Foundation

struct TavernShellError: LocalizedError {
    private let render: () -> String
    init(_ render: @escaping () -> String) { self.render = render }
    var errorDescription: String? { render() }
}

enum TavernLanguage: String, CaseIterable {
    case english = "en"
    case russian = "ru"

    var displayName: String {
        switch self {
        case .english: return "English"
        case .russian: return "Русский"
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }
    var nativeValue: UInt32 { self == .russian ? 1 : 0 }
}

extension Notification.Name {
    static let tavernLanguageDidChange = Notification.Name("HerdrTavern.languageDidChange")
}

private enum TavernLocalizationError: LocalizedError {
    case missingTable(String)
    case invalidTable(String)
    case duplicateKey(String)
    case mismatchedKeys(String)

    var errorDescription: String? {
        switch self {
        case .missingTable(let path): return "Missing language resource: \(path)"
        case .invalidTable(let path): return "Invalid language resource: \(path)"
        case .duplicateKey(let key): return "Duplicate translation key: \(key)"
        case .mismatchedKeys(let table): return "English and Russian translation keys differ in \(table)"
        }
    }
}

/// Loads immutable catalogs once; changing language does not recreate app state.
final class TavernLocalization {
    static let preferenceKey = "tavern.language"
    private static let tableNames = ["Shell", "Settings", "Core", "Installer"]

    static let shared: TavernLocalization = {
        do {
            let localization = try TavernLocalization(defaults: .standard, bundle: .main)
            localization.defaults.set([localization.language.rawValue], forKey: "AppleLanguages")
            return localization
        } catch {
            // A broken package must not silently display internal translation keys.
            fatalError("Unable to load Herdr Tavern language resources: \(error.localizedDescription)")
        }
    }()

    private let defaults: UserDefaults
    private let catalogs: [TavernLanguage: [String: String]]
    private let lock = NSLock()
    private var selectedLanguage: TavernLanguage

    var language: TavernLanguage {
        lock.lock()
        defer { lock.unlock() }
        return selectedLanguage
    }

    init(defaults: UserDefaults, bundle: Bundle) throws {
        self.defaults = defaults
        selectedLanguage = defaults.string(forKey: Self.preferenceKey)
            .flatMap(TavernLanguage.init(rawValue:)) ?? .english
        var loaded: [TavernLanguage: [String: String]] = [:]
        var englishKeys: [String: Set<String>] = [:]
        for language in TavernLanguage.allCases {
            var translations: [String: String] = [:]
            for table in Self.tableNames {
                let relativePath = "\(language.rawValue).lproj/\(table).strings"
                guard let root = bundle.resourceURL else {
                    throw TavernLocalizationError.missingTable(relativePath)
                }
                let url = root.appendingPathComponent(relativePath)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw TavernLocalizationError.missingTable(relativePath)
                }
                let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: url),
                                                                      options: [], format: nil)
                guard let entries = value as? [String: String], !entries.isEmpty else {
                    throw TavernLocalizationError.invalidTable(relativePath)
                }
                let keys = Set(entries.keys)
                if language == .english {
                    englishKeys[table] = keys
                } else if englishKeys[table] != keys {
                    throw TavernLocalizationError.mismatchedKeys(table)
                }
                for (key, text) in entries {
                    guard translations.updateValue(text, forKey: key) == nil else {
                        throw TavernLocalizationError.duplicateKey(key)
                    }
                }
            }
            loaded[language] = translations
        }
        catalogs = loaded
    }

    func text(_ key: String, arguments: [CVarArg] = []) -> String {
        let selected = language
        guard let format = catalogs[selected]?[key] else {
            preconditionFailure("Unknown Herdr Tavern translation key: \(key)")
        }
        if arguments.isEmpty { return format }
        return String(format: format, locale: selected.locale, arguments: arguments)
    }

    func setLanguage(_ language: TavernLanguage) {
        precondition(Thread.isMainThread, "Change the interface language on the main thread")
        lock.lock()
        let changed = selectedLanguage != language
        selectedLanguage = language
        lock.unlock()
        defaults.set(language.rawValue, forKey: Self.preferenceKey)
        // App-specific preference, not the global macOS language setting.
        defaults.set([language.rawValue], forKey: "AppleLanguages")
        if changed {
            NotificationCenter.default.post(name: .tavernLanguageDidChange, object: self)
        }
    }

}

func L(_ key: String, _ arguments: CVarArg...) -> String {
    TavernLocalization.shared.text(key, arguments: arguments)
}
