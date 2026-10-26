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

struct TavernSoundResource: Equatable {
    let url: URL
    let revision: UInt64
}

// All filesystem work, including playback reads, shares one serial worker.
private enum TavernSoundIO {
    static let queue = DispatchQueue(label: "org.herdr.tavern.sound-io", qos: .userInitiated)

    static func regularData(at url: URL) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        return try Data(contentsOf: url)
    }

    static func checkDirectory(_ directory: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
    }

    static func remove(_ url: URL?, directory: URL) throws {
        guard let url else { return }
        let manager = FileManager.default
        let attributes: [FileAttributeKey: Any]
        do {
            try checkDirectory(directory)
            attributes = try manager.attributesOfItem(atPath: url.path)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) {
            return
        } catch {
            throw TavernSoundError.fileOperation("settings.sound.inspectFailed", error)
        }
        // Never remove a symlink or directory, even if defaults contain its name.
        guard attributes[.type] as? FileAttributeType == .typeRegular else { return }
        do {
            try manager.removeItem(at: url)
        } catch {
            throw TavernSoundError.fileOperation("settings.sound.removeFailed", error)
        }
    }
}

final class TavernSoundSettings {
    private static let keyPrefix = "HerdrTavern.sounds.v1."
    private let defaults: UserDefaults
    private let soundDirectory: URL
    private let bundledURLs: [TavernSoundEvent: URL]
    private var choices: [TavernSoundEvent: TavernSoundChoice] = [:]
    private var revisions: [TavernSoundEvent: UInt64] = [:]
    private var mutations: [() -> Void] = []
    private var mutating = false
    private var masterEnabled: Bool
    private var masterVolume: Double
    var onChange: (() -> Void)?
    #if TAVERN_RENDER_TESTING
    var ioGate: (() -> Void)?
    #endif

    init(defaults: UserDefaults = .standard, soundDirectory: URL? = nil) {
        self.defaults = defaults
        self.soundDirectory = soundDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HerdrTavern", isDirectory: true)
            .appendingPathComponent("Sounds", isDirectory: true)
        var bundled: [TavernSoundEvent: URL] = [:]
        for event in TavernSoundEvent.allCases {
            bundled[event] = Bundle.main.url(forResource: event.defaultFilename,
                                            withExtension: nil, subdirectory: "Sounds")
        }
        bundledURLs = bundled
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

    func choice(for event: TavernSoundEvent) -> TavernSoundChoice { choices[event]! }

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

    func resource(for event: TavernSoundEvent) -> TavernSoundResource? {
        let url: URL?
        if let filename = choice(for: event).customFilename {
            url = managedURL(for: filename)
        } else {
            url = bundledURLs[event]
        }
        return url.map { TavernSoundResource(url: $0, revision: revisions[event, default: 0]) }
    }

    fileprivate func performIO<T>(_ work: @escaping () throws -> T,
                                  completion: @escaping (Result<T, Error>) -> Void) {
        #if TAVERN_RENDER_TESTING
        let gate = ioGate
        #endif
        TavernSoundIO.queue.async {
            #if TAVERN_RENDER_TESTING
            gate?()
            #endif
            let result = Result { try work() }
            DispatchQueue.main.async { completion(result) }
        }
    }

    fileprivate func read(_ resource: TavernSoundResource,
                          completion: @escaping (Result<Data, Error>) -> Void) {
        let directory = soundDirectory
        let managed = resource.url.deletingLastPathComponent().path == directory.path
        performIO({
            if managed { try TavernSoundIO.checkDirectory(directory) }
            return try TavernSoundIO.regularData(at: resource.url)
        }, completion: completion)
    }

    func replaceSound(for event: TavernSoundEvent, with url: URL,
                      completion: @escaping (Result<Void, Error>) -> Void) {
        enqueueMutation { self.beginReplace(for: event, with: url, completion: completion) }
    }

    private func beginReplace(for event: TavernSoundEvent, with url: URL,
                              completion: @escaping (Result<Void, Error>) -> Void) {
        let scoped = url.startAccessingSecurityScopedResource()
        let directory = soundDirectory
        let oldURL = removableURL(for: event)
        let suffix = url.pathExtension.lowercased()
        let validSuffix = !suffix.isEmpty && suffix.count <= 12
            && suffix.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) }
        let filename = "tavern-sound-\(UUID().uuidString).\(validSuffix ? suffix : "audio")"
        let destination = directory.appendingPathComponent(filename, isDirectory: false)
        let finish: (Result<Void, Error>) -> Void = { result in
            if scoped { url.stopAccessingSecurityScopedResource() }
            self.finishMutation(result, completion: completion)
        }
        performIO({
            guard url.isFileURL else { throw TavernSoundError.unsupported(url.lastPathComponent) }
            let source = url.resolvingSymlinksInPath()
            return (source, try TavernSoundIO.regularData(at: source))
        }) { result in
            switch result {
            case .failure(let error): finish(.failure(error))
            case .success(let (source, data)):
                guard NSSound(data: data) != nil else {
                    finish(.failure(TavernSoundError.unsupported(url.lastPathComponent)))
                    return
                }
                self.performIO({
                    do {
                        try FileManager.default.createDirectory(at: directory,
                                                                withIntermediateDirectories: true)
                        try TavernSoundIO.checkDirectory(directory)
                    } catch {
                        throw TavernSoundError.fileOperation("settings.sound.createDirectoryFailed", error)
                    }
                    do {
                        try FileManager.default.copyItem(at: source, to: destination)
                    } catch {
                        throw TavernSoundError.fileOperation("settings.sound.copyFailed", error)
                    }
                    return try TavernSoundIO.regularData(at: destination)
                }) { copied in
                    switch copied {
                    case .failure(let error):
                        self.rollback(destination, original: error, finish: finish)
                    case .success(let copiedData):
                        guard NSSound(data: copiedData) != nil else {
                            self.rollback(destination,
                                          original: TavernSoundError.unsupported(url.lastPathComponent),
                                          finish: finish)
                            return
                        }
                        self.performIO({
                            try TavernSoundIO.remove(oldURL, directory: directory)
                        }) { removed in
                            switch removed {
                            case .failure(let error):
                                self.rollback(destination, original: error, finish: finish)
                            case .success:
                                var choice = self.choice(for: event)
                                choice.customFilename = filename
                                choice.customDisplayName = url.lastPathComponent
                                self.revisions[event, default: 0] &+= 1
                                self.save(choice, for: event)
                                finish(.success(()))
                            }
                        }
                    }
                }
            }
        }
    }

    private func rollback(_ destination: URL, original: Error,
                          finish: @escaping (Result<Void, Error>) -> Void) {
        let directory = soundDirectory
        performIO({ try TavernSoundIO.remove(destination, directory: directory) }) { cleanup in
            switch cleanup {
            case .success: finish(.failure(original))
            case .failure(let error): finish(.failure(TavernSoundError.cleanup(original, error)))
            }
        }
    }

    func resetSound(for event: TavernSoundEvent,
                    completion: @escaping (Result<Void, Error>) -> Void) {
        enqueueMutation {
            let previous = self.choice(for: event)
            guard previous.customFilename != nil || previous.customDisplayName != nil else {
                self.finishMutation(.success(()), completion: completion)
                return
            }
            let oldURL = self.removableURL(for: event)
            let directory = self.soundDirectory
            self.performIO({ try TavernSoundIO.remove(oldURL, directory: directory) }) { result in
                if case .success = result {
                    var choice = self.choice(for: event)
                    choice.customFilename = nil
                    choice.customDisplayName = nil
                    if previous.customFilename != nil { self.revisions[event, default: 0] &+= 1 }
                    self.save(choice, for: event)
                }
                self.finishMutation(result, completion: completion)
            }
        }
    }

    private func enqueueMutation(_ operation: @escaping () -> Void) {
        mutations.append(operation)
        startNextMutation()
    }

    private func startNextMutation() {
        guard !mutating, !mutations.isEmpty else { return }
        mutating = true
        mutations.removeFirst()()
    }

    private func finishMutation(_ result: Result<Void, Error>,
                                completion: (Result<Void, Error>) -> Void) {
        // Remain busy during completion: a reentrant caller joins the same FIFO.
        completion(result)
        mutating = false
        startNextMutation()
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
        let prefix = "tavern-sound-"
        guard filename.hasPrefix(prefix) else { return nil }
        let pieces = filename.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 2, let identifier = UUID(uuidString: String(pieces[0])),
              identifier.uuidString == pieces[0], !pieces[1].isEmpty, pieces[1].count <= 12,
              pieces[1].utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) }) else {
            return nil
        }
        return soundDirectory.appendingPathComponent(filename, isDirectory: false)
    }

    private func removableURL(for event: TavernSoundEvent) -> URL? {
        guard let filename = choice(for: event).customFilename,
              !choices.contains(where: { $0.key != event && $0.value.customFilename == filename }) else {
            return nil
        }
        return managedURL(for: filename)
    }
}

final class TavernSoundPlayer: NSObject, NSSoundDelegate {
    private final class PreparedSound {
        let data: Data
        let template: NSSound
        init(data: Data, template: NSSound) { self.data = data; self.template = template }
    }

    private struct Intent {
        let token: UInt64
        let event: TavernSoundEvent
        let resource: TavernSoundResource
        let preview: Bool
    }

    private struct Load {
        let resource: TavernSoundResource
        var completion: (Result<PreparedSound, Error>) -> Void
    }

    private let settings: TavernSoundSettings
    private let cache = NSCache<NSString, PreparedSound>()
    private let cacheBudget = 32 * 1024 * 1024
    private var resources: [TavernSoundEvent: TavernSoundResource] = [:]
    private var loading: Load?
    private var pendingLoad: Load?
    private var warmResource: TavernSoundResource?
    private var intent: Intent?
    private var generation: UInt64 = 0
    private var activeSound: NSSound?
    private var activeEvent: TavernSoundEvent?
    private var activeResource: TavernSoundResource?
    private var activePreview = false
    private var pressureObserver: NSObjectProtocol?
    var onError: ((String) -> Void)?
    #if TAVERN_RENDER_TESTING
    var playSound: ((NSSound) -> Bool)?
    var isSoundPlaying: ((NSSound) -> Bool)?
    var testingActiveSound: NSSound? { activeSound }
    func testingTemplate(for resource: TavernSoundResource) -> NSSound? {
        cache.object(forKey: "\(resource.revision):\(resource.url.absoluteString)" as NSString)?.template
    }
    #endif

    init(settings: TavernSoundSettings) {
        self.settings = settings
        super.init()
        cache.countLimit = 8
        cache.totalCostLimit = cacheBudget
        captureResources()
        pressureObserver = NotificationCenter.default.addObserver(
            forName: .tavernMemoryPressure, object: nil, queue: .main) { [weak self] _ in
                self?.cache.removeAllObjects()
            }
        // The player is created at interface startup, not while collecting settings.
        if settings.enabled, settings.choice(for: .interfaceClick).enabled,
           settings.choice(for: .interfaceClick).customFilename == nil,
           let resource = settings.resource(for: .interfaceClick) {
            warmResource = resource
            load(resource) { [weak self] _ in self?.warmResource = nil }
        }
    }

    deinit {
        if let pressureObserver { NotificationCenter.default.removeObserver(pressureObserver) }
    }

    private func captureResources() {
        resources.removeAll(keepingCapacity: true)
        for event in TavernSoundEvent.allCases { resources[event] = settings.resource(for: event) }
    }

    private func wanted(_ resource: TavernSoundResource) -> Bool {
        let currentIntent = intent.map {
            $0.resource == resource && settings.resource(for: $0.event) == resource
                && settings.enabled && ($0.preview || settings.choice(for: $0.event).enabled)
        } ?? false
        let warming = warmResource == resource && settings.enabled
            && settings.choice(for: .interfaceClick).enabled
            && settings.choice(for: .interfaceClick).customFilename == nil
            && settings.resource(for: .interfaceClick) == resource
        return currentIntent || warming
    }

    private func load(_ resource: TavernSoundResource,
                      completion: @escaping (Result<PreparedSound, Error>) -> Void) {
        guard wanted(resource) else { return }
        let key = "\(resource.revision):\(resource.url.absoluteString)" as NSString
        if let prepared = cache.object(forKey: key) {
            completion(.success(prepared))
            return
        }
        if loading?.resource == resource {
            loading?.completion = completion
            return
        }
        if loading != nil {
            pendingLoad = Load(resource: resource, completion: completion)
            return
        }
        loading = Load(resource: resource, completion: completion)
        settings.read(resource) { [weak self] result in
            guard let self else { return }
            let callback = self.loading?.completion
            self.loading = nil
            // Obsolete data must not even construct an AppKit template.
            if self.wanted(resource) {
                let prepared: Result<PreparedSound, Error> = result.flatMap { data in
                    guard let template = NSSound(data: data) else {
                        return .failure(TavernSoundError.unsupported(resource.url.lastPathComponent))
                    }
                    return .success(PreparedSound(data: data, template: template))
                }
                if self.wanted(resource) {
                    if case .success(let sound) = prepared, sound.data.count <= self.cacheBudget {
                        self.cache.setObject(sound, forKey: key, cost: sound.data.count)
                    }
                    callback?(prepared)
                }
            }
            if let next = self.pendingLoad {
                self.pendingLoad = nil
                guard self.wanted(next.resource) else { return }
                self.load(next.resource, completion: next.completion)
            }
        }
    }

    func play(_ event: TavernSoundEvent, preview: Bool = false) {
        guard settings.enabled else { stop(); return }
        let choice = settings.choice(for: event)
        guard preview || choice.enabled else { return }
        if event != .interfaceClick, activeEvent == event, let sound = activeSound {
            #if TAVERN_RENDER_TESTING
            if isSoundPlaying?(sound) ?? sound.isPlaying { return }
            #else
            if sound.isPlaying { return }
            #endif
        }
        stop()
        guard let resource = settings.resource(for: event) else {
            onError?(L("settings.sound.unavailable", event.title, settings.displayName(for: event)))
            return
        }
        let request = Intent(token: generation, event: event, resource: resource, preview: preview)
        intent = request
        load(resource) { [weak self] result in
            guard let self, self.intent?.token == request.token,
                  self.wanted(resource) else { return }
            switch result {
            case .failure:
                self.intent = nil
                self.onError?(L("settings.sound.readFailed", event.title, self.settings.displayName(for: event)))
            case .success(let prepared):
                let copied = prepared.template.copy() as? NSSound
                guard let sound = (copied !== prepared.template ? copied : nil)
                    ?? NSSound(data: prepared.data) else {
                    self.intent = nil
                    self.onError?(L("settings.sound.readFailed", event.title, self.settings.displayName(for: event)))
                    return
                }
                sound.volume = Float(self.settings.volume * self.settings.choice(for: event).volume)
                sound.delegate = self
                self.activeSound = sound
                self.activeEvent = event
                self.activeResource = resource
                self.activePreview = preview
                #if TAVERN_RENDER_TESTING
                let played = self.playSound?(sound) ?? sound.play()
                #else
                let played = sound.play()
                #endif
                if !played {
                    self.stop()
                    self.onError?(L("settings.sound.playFailed", event.title))
                }
            }
        }
    }

    func stop() {
        generation &+= 1
        intent = nil
        warmResource = nil
        pendingLoad = nil
        let sound = activeSound
        activeSound = nil
        activeEvent = nil
        activeResource = nil
        activePreview = false
        sound?.delegate = nil
        sound?.stop()
    }

    func settingsDidChange() {
        let oldResources = resources
        captureResources()
        if oldResources != resources { cache.removeAllObjects() }
        guard settings.enabled else { stop(); return }
        if let request = intent {
            guard settings.resource(for: request.event) == request.resource,
                  request.preview || settings.choice(for: request.event).enabled else {
                stop()
                return
            }
        }
        guard let event = activeEvent, let sound = activeSound else { return }
        let choice = settings.choice(for: event)
        guard (activePreview || choice.enabled), settings.resource(for: event) == activeResource else {
            stop()
            return
        }
        sound.volume = Float(settings.volume * choice.volume)
    }

    func sound(_ sound: NSSound, didFinishPlaying success: Bool) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.sound(sound, didFinishPlaying: success) }
            return
        }
        guard activeSound === sound else { return }
        let event = activeEvent
        activeSound = nil
        activeEvent = nil
        activeResource = nil
        activePreview = false
        intent = nil
        sound.delegate = nil
        if !success, let event { onError?(L("settings.sound.interrupted", event.title)) }
    }
}
