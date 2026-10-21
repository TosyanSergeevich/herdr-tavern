import AppKit

// Звуки описывают события Tavern, а не содержимое ответа модели.
enum TavernSoundEvent: String, CaseIterable {
    case attention, complete, error, agentStarted, connected, bell, interfaceClick, interfaceMove

    var title: String {
        switch self {
        case .attention: return L("settings.sound.attention")
        case .complete: return L("settings.sound.complete")
        case .error: return L("settings.sound.error")
        case .agentStarted: return L("settings.sound.agentStarted")
        case .connected: return L("settings.sound.connected")
        case .bell: return L("settings.sound.bell")
        case .interfaceClick: return L("settings.sound.interfaceClick")
        case .interfaceMove: return L("settings.sound.interfaceMove")
        }
    }

    var symbolName: String {
        switch self {
        case .attention: return "bell.badge"
        case .complete: return "checkmark.circle"
        case .error: return "exclamationmark.triangle"
        case .agentStarted: return "person.badge.plus"
        case .connected: return "link"
        case .bell: return "terminal"
        case .interfaceClick: return "cursorarrow"
        case .interfaceMove: return "arrow.up.and.down.and.arrow.left.and.right"
        }
    }

    var defaultFilename: String {
        switch self {
        case .attention, .complete: return "iTellMessage.wav"
        case .error: return "igQuestFailed.wav"
        case .agentStarted: return "iQuestActivate.wav"
        case .connected: return "TaurenExploration.wav"
        case .bell: return "iTellMessage.wav"
        case .interfaceClick: return "iUiInterfaceButtonA.wav"
        case .interfaceMove: return "uSpellIconDrop.wav"
        }
    }

    var defaultEnabled: Bool { self != .bell }
    var defaultVolume: Double {
        switch self {
        case .complete: return 0.5
        case .interfaceMove: return 0.35
        default: return 1
        }
    }
}

struct TavernSoundChoice: Codable {
    var enabled: Bool
    var volume: Double
    var customFilename: String?
    var customDisplayName: String?
}

private enum TavernSoundError: LocalizedError {
    case unsupported(String)
    case fileOperation(String, Error)
    case cleanup(Error, Error)

    var errorDescription: String? {
        switch self {
        case .unsupported(let name):
            return L("settings.sound.unsupported", name)
        case .fileOperation(let operation, let error):
            return L("settings.sound.fileOperation", L(operation), error.localizedDescription)
        case .cleanup(let original, let cleanup):
            return L("settings.sound.cleanup", original.localizedDescription, cleanup.localizedDescription)
        }
    }
}

final class TavernSoundSettings {
    private static let keyPrefix = "HerdrTavern.sounds.v1."
    private let defaults: UserDefaults
    private let soundDirectory: URL
    private var choices: [TavernSoundEvent: TavernSoundChoice] = [:]
    private var masterEnabled: Bool
    private var masterVolume: Double
    var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard, soundDirectory: URL? = nil) {
        self.defaults = defaults
        self.soundDirectory = soundDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HerdrTavern", isDirectory: true)
            .appendingPathComponent("Sounds", isDirectory: true)
        masterEnabled = defaults.object(forKey: Self.keyPrefix + "enabled") as? Bool ?? true
        masterVolume = Self.normalizedVolume(
            (defaults.object(forKey: Self.keyPrefix + "volume") as? NSNumber)?.doubleValue ?? 0.5,
            fallback: 0.5)
        for event in TavernSoundEvent.allCases {
            let stored = defaults.dictionary(forKey: Self.keyPrefix + "event." + event.rawValue)
            choices[event] = TavernSoundChoice(
                enabled: stored?["enabled"] as? Bool ?? event.defaultEnabled,
                volume: Self.normalizedVolume((stored?["volume"] as? NSNumber)?.doubleValue
                                               ?? event.defaultVolume, fallback: event.defaultVolume),
                customFilename: stored?["customFilename"] as? String,
                customDisplayName: stored?["customDisplayName"] as? String)
        }
    }

    var enabled: Bool {
        get { masterEnabled }
        set {
            guard masterEnabled != newValue else { return }
            masterEnabled = newValue
            defaults.set(newValue, forKey: Self.keyPrefix + "enabled")
            onChange?()
        }
    }

    var volume: Double {
        get { masterVolume }
        set {
            let value = Self.normalizedVolume(newValue, fallback: 0.5)
            guard masterVolume != value else { return }
            masterVolume = value
            defaults.set(value, forKey: Self.keyPrefix + "volume")
            onChange?()
        }
    }

    func choice(for event: TavernSoundEvent) -> TavernSoundChoice {
        choices[event]!
    }

    func setEnabled(_ value: Bool, for event: TavernSoundEvent) {
        var choice = choice(for: event)
        guard choice.enabled != value else { return }
        choice.enabled = value
        save(choice, for: event)
    }

    func setVolume(_ value: Double, for event: TavernSoundEvent) {
        var choice = choice(for: event)
        let value = Self.normalizedVolume(value, fallback: event.defaultVolume)
        guard choice.volume != value else { return }
        choice.volume = value
        save(choice, for: event)
    }

    func displayName(for event: TavernSoundEvent) -> String {
        let choice = choice(for: event)
        guard let filename = choice.customFilename else { return event.defaultFilename }
        return choice.customDisplayName ?? filename
    }

    func soundURL(for event: TavernSoundEvent) -> URL? {
        guard let filename = choice(for: event).customFilename else {
            return Bundle.main.url(forResource: event.defaultFilename, withExtension: nil,
                                   subdirectory: "Sounds")
        }
        // Повреждённая пользовательская настройка не подменяется звуком по умолчанию.
        guard let url = managedURL(for: filename),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        return url
    }

    func replaceSound(for event: TavernSoundEvent, with url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let source = url.resolvingSymlinksInPath()
        guard url.isFileURL, NSSound(contentsOf: source, byReference: false) != nil else {
            throw TavernSoundError.unsupported(url.lastPathComponent)
        }
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: soundDirectory, withIntermediateDirectories: true)
        } catch {
            throw TavernSoundError.fileOperation("settings.sound.createDirectoryFailed", error)
        }
        let suffix = url.pathExtension.lowercased()
        let validSuffix = !suffix.isEmpty && suffix.count <= 12
            && suffix.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) }
        let filename = "tavern-sound-\(UUID().uuidString).\(validSuffix ? suffix : "audio")"
        let destination = soundDirectory.appendingPathComponent(filename)
        do {
            do {
                try manager.copyItem(at: source, to: destination)
            } catch {
                throw TavernSoundError.fileOperation("settings.sound.copyFailed", error)
            }
            guard NSSound(contentsOf: destination, byReference: false) != nil else {
                throw TavernSoundError.unsupported(url.lastPathComponent)
            }
            try removeManagedSound(choice(for: event).customFilename, excluding: event)
        } catch {
            // До успешного удаления прежней копии настройка остаётся прежней.
            do {
                try removeManagedSound(filename, excluding: event)
            } catch let cleanup {
                throw TavernSoundError.cleanup(error, cleanup)
            }
            throw error
        }
        var choice = choice(for: event)
        choice.customFilename = filename
        choice.customDisplayName = url.lastPathComponent
        save(choice, for: event)
    }

    func resetSound(for event: TavernSoundEvent) throws {
        var choice = choice(for: event)
        guard choice.customFilename != nil || choice.customDisplayName != nil else { return }
        try removeManagedSound(choice.customFilename, excluding: event)
        choice.customFilename = nil
        choice.customDisplayName = nil
        save(choice, for: event)
    }

    private static func normalizedVolume(_ value: Double, fallback: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : fallback
    }

    private func save(_ choice: TavernSoundChoice, for event: TavernSoundEvent) {
        choices[event] = choice
        var stored: [String: Any] = ["enabled": choice.enabled, "volume": choice.volume]
        if let filename = choice.customFilename { stored["customFilename"] = filename }
        if let name = choice.customDisplayName { stored["customDisplayName"] = name }
        defaults.set(stored, forKey: Self.keyPrefix + "event." + event.rawValue)
        onChange?()
    }

    private func managedURL(for filename: String) -> URL? {
        // Из defaults принимаются только имена нашего генератора, не внешние пути.
        let prefix = "tavern-sound-"
        guard filename.hasPrefix(prefix) else { return nil }
        let pieces = filename.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 2, let identifier = UUID(uuidString: String(pieces[0])),
              identifier.uuidString == pieces[0], !pieces[1].isEmpty, pieces[1].count <= 12,
              pieces[1].utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) }) else {
            return nil
        }
        return soundDirectory.appendingPathComponent(filename)
    }

    private func removeManagedSound(_ filename: String?, excluding event: TavernSoundEvent) throws {
        guard let filename, let url = managedURL(for: filename),
              !choices.contains(where: { $0.key != event && $0.value.customFilename == filename }) else { return }
        let manager = FileManager.default
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try manager.attributesOfItem(atPath: url.path)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) {
            return
        } catch {
            throw TavernSoundError.fileOperation("settings.sound.inspectFailed", error)
        }
        // Не следуем символьным ссылкам и не удаляем каталоги даже с подходящим именем.
        guard attributes[.type] as? FileAttributeType == .typeRegular else { return }
        do {
            try manager.removeItem(at: url)
        } catch {
            throw TavernSoundError.fileOperation("settings.sound.removeFailed", error)
        }
    }
}

final class TavernSoundPlayer: NSObject, NSSoundDelegate {
    private let settings: TavernSoundSettings
    private var activeSound: NSSound?
    private var activeEvent: TavernSoundEvent?
    private var activeURL: URL?
    private var activePreview = false
    var onError: ((String) -> Void)?

    init(settings: TavernSoundSettings) {
        self.settings = settings
        super.init()
    }

    func play(_ event: TavernSoundEvent, preview: Bool = false) {
        guard settings.enabled else { stop(); return }
        let choice = settings.choice(for: event)
        guard preview || choice.enabled else { return }
        if event != .interfaceClick, activeEvent == event, activeSound?.isPlaying == true { return }
        stop()
        guard let url = settings.soundURL(for: event) else {
            onError?(L("settings.sound.unavailable", event.title, settings.displayName(for: event)))
            return
        }
        guard let sound = NSSound(contentsOf: url, byReference: false) else {
            onError?(L("settings.sound.readFailed", event.title, settings.displayName(for: event)))
            return
        }
        sound.volume = Float(settings.volume * choice.volume)
        sound.delegate = self
        activeSound = sound
        activeEvent = event
        activeURL = url
        activePreview = preview
        if !sound.play() {
            stop()
            onError?(L("settings.sound.playFailed", event.title))
        }
    }

    func stop() {
        let sound = activeSound
        activeSound = nil
        activeEvent = nil
        activeURL = nil
        activePreview = false
        sound?.delegate = nil
        sound?.stop()
    }

    func settingsDidChange() {
        guard settings.enabled else { stop(); return }
        guard let event = activeEvent, let sound = activeSound else { return }
        let choice = settings.choice(for: event)
        guard (activePreview || choice.enabled), settings.soundURL(for: event) == activeURL else {
            stop()
            return
        }
        sound.volume = Float(settings.volume * choice.volume)
    }

    func sound(_ sound: NSSound, didFinishPlaying success: Bool) {
        guard activeSound === sound else { return }
        let event = activeEvent
        activeSound = nil
        activeEvent = nil
        activeURL = nil
        activePreview = false
        sound.delegate = nil
        if !success, let event {
            onError?(L("settings.sound.interrupted", event.title))
        }
    }
}
