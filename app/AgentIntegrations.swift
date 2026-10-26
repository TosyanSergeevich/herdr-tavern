import Foundation
import Darwin

struct AgentIntegration {
    let target: String
    let label: String
    let command: String
    let available: Bool
    let state: String
    let detailsText: () -> String
    var details: String { detailsText() }
    let supportsProfileDirectory: Bool
    let executablePath: String?
    let profileDirectory: String?
    var profileDirectoryHint: String {
        AgentIntegrationDefinition.find(target)?.profileHint ?? L("settings.integration.fixedProfile")
    }

    var installed: Bool { state == "current" || state == "outdated" }
    var needsUpdate: Bool { state == "outdated" }

    var capabilities: String {
        switch target {
        case "pi", "omp", "kimi", "opencode", "kilo", "mastracode":
            return L("settings.integration.capabilities.full")
        case "codex":
            return L("settings.integration.capabilities.codex")
        default:
            return L("settings.integration.capabilities.other")
        }
    }
}

private enum AgentIntegrationError: Error, LocalizedError {
    case message(String, [CVarArg] = [])
    var errorDescription: String? {
        if case .message(let key, let arguments) = self {
            return String(format: L(key), locale: Locale(identifier: TavernLocalization.shared.language.rawValue), arguments: arguments)
        }
        return nil
    }
}

// The socket API runs in the server's environment, excludes CLI-only Letta, and
// cannot select an agent profile. Use the selected local herdr CLI for all three
// operations instead; its status command currently has no JSON output option.
final class AgentIntegrationService {
    private let executable: () throws -> String
    private let defaults: UserDefaults
    private let worker = DispatchQueue(label: "org.local.HerdrTavern.integrations", qos: .userInitiated)
    private let executableKey = "agentIntegrations.executablePaths"
    private let profileKey = "agentIntegrations.profileDirectories"

    init(executable: @escaping () throws -> String, defaults: UserDefaults = .standard) {
        self.executable = executable
        self.defaults = defaults
    }

    func list(completion: @escaping (Result<[AgentIntegration], Error>) -> Void) {
        enqueue(completion: completion) { executable in
            let base = try self.environment()
            let statuses = try Self.parseStatus(self.run(executable, arguments: ["integration", "status"], environment: base))
            let directories = Self.searchDirectories(environment: base)
            return statuses.map { original in
                let definition = AgentIntegrationDefinition.find(original.target)
                let path = self.saved(self.executableKey, target: original.target)
                let profile = self.saved(self.profileKey, target: original.target)
                var selectedEnvironment = base
                var profileFailure: Error?
                var status = original
                if profile != nil {
                    do {
                        selectedEnvironment = try self.environment(target: original.target)
                        let selected = try Self.parseStatus(self.run(executable, arguments: ["integration", "status"], environment: selectedEnvironment))
                        guard let match = selected.first(where: { $0.target == original.target }) else {
                            throw AgentIntegrationError.message("settings.integration.profileStatusMissing", [original.target])
                        }
                        status = match
                    } catch {
                        // Keep the row and its reset-profile action accessible on
                        // the next launch; never present the default profile's
                        // status as the selected profile's status.
                        profileFailure = error
                    }
                }
                let commands = definition?.commands ?? [original.target]
                let found = path.map { Self.executableFile($0) } ?? (commands.contains { command in
                    directories.contains { Self.executableFile($0 + "/" + command) }
                } || (original.target == "codex" && Self.codexStandaloneAvailable(environment: selectedEnvironment)))
                let invalidExecutable = path != nil && !found
                // Keep diagnostic inputs, not translated snapshots: changing language
                // must not rerun CLI operations or discard the selected profile.
                let details: () -> String = {
                    var text = profileFailure.map { L("settings.integration.profileCheckFailed", $0.localizedDescription) } ?? status.line
                    if let path { text += "\n" + L("settings.integration.executablePath", path) }
                    if invalidExecutable {
                        text += "\n" + L("settings.integration.invalidExecutable")
                    } else {
                        text += "\n" + L(found ? "settings.integration.executableFound" : "settings.integration.executableMissing")
                    }
                    if let profile { text += "\n" + L("settings.integration.selectedProfile", profile) }
                    else if let variable = definition?.profileVariable, let inherited = selectedEnvironment[variable], !inherited.isEmpty {
                        text += "\n" + L("settings.integration.environmentProfile", variable, inherited)
                    }
                    if original.target == "omp", let inherited = selectedEnvironment["PI_CODING_AGENT_DIR"], !inherited.isEmpty {
                        text += "\n" + L("settings.integration.sharedPiDirectory", inherited)
                    }
                    if profileFailure == nil { text += "\n" + L("settings.integration.path", status.path) }
                    if let hint = definition?.profileHint { text += "\n" + hint }
                    if definition == nil { text += "\n" + L("settings.integration.unknownTarget") }
                    if original.target == "letta" { text += "\n" + L("settings.integration.experimental") }
                    return text
                }
                return AgentIntegration(target: original.target, label: definition?.label ?? original.target,
                                        command: commands[0], available: found, state: definition == nil || profileFailure != nil ? "unknown" : status.state,
                                        detailsText: details, supportsProfileDirectory: definition?.profileVariable != nil,
                                        executablePath: path, profileDirectory: profile)
            }
        }
    }

    func install(target: String, completion: @escaping (Result<String, Error>) -> Void) {
        change("install", target: target, completion: completion)
    }

    func uninstall(target: String, completion: @escaping (Result<String, Error>) -> Void) {
        change("uninstall", target: target, completion: completion)
    }

    func setExecutablePath(_ path: String?, for target: String) {
        save(path, key: executableKey, target: target)
    }

    func setProfileDirectory(_ path: String?, for target: String) {
        save(path, key: profileKey, target: target)
    }

    private func save(_ path: String?, key: String, target: String) {
        worker.async { [self] in
            var values = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
            values[target] = path.map { NSString(string: $0).expandingTildeInPath }
            defaults.set(values, forKey: key)
        }
    }

    private func saved(_ key: String, target: String) -> String? {
        (defaults.dictionary(forKey: key) as? [String: String])?[target]
    }

    private func change(_ action: String, target: String, completion: @escaping (Result<String, Error>) -> Void) {
        enqueue(completion: completion) { executable in
            guard AgentIntegrationDefinition.find(target) != nil else {
                throw AgentIntegrationError.message("settings.integration.unknownRules", [target])
            }
            if action == "install", let path = self.saved(self.executableKey, target: target), !Self.executableFile(path) {
                throw AgentIntegrationError.message("settings.integration.agentUnavailable", [path])
            }
            let environment = try self.environment(target: target)
            // Validate the exact selected profile before mutating anything. Do not
            // retry writes: timeout/nonzero exit may still mean a partial change.
            let statuses = try Self.parseStatus(self.run(executable, arguments: ["integration", "status"], environment: environment))
            guard statuses.contains(where: { $0.target == target }) else {
                throw AgentIntegrationError.message("settings.integration.unsupported", [target])
            }
            let output = try self.run(executable, arguments: ["integration", action, target], environment: environment)
            guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentIntegrationError.message("settings.integration.emptyResult")
            }
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func enqueue<T>(completion: @escaping (Result<T, Error>) -> Void, operation: @escaping (String) throws -> T) {
        worker.async { [self] in
            let result = Result { try operation(executable()) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func environment(target: String? = nil) throws -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        guard home.hasPrefix("/") else { throw AgentIntegrationError.message("settings.integration.absoluteHome") }
        environment["HOME"] = home
        if let target, let profile = saved(profileKey, target: target) {
            environment = try Self.applyingProfile(profile, target: target, environment: environment)
        }
        // herdr receives a deterministic absolute cwd, never a Finder launch cwd.
        // Reject relative overrides rather than silently writing to another profile.
        let pathVariables = Set(AgentIntegrationDefinition.all.compactMap(\.profileVariable))
            .union(["PI_CODING_AGENT_DIR", "PI_CONFIG_DIR", "XDG_CONFIG_HOME", "GROK_CONFIG_DIR"])
        for key in pathVariables {
            guard let raw = environment[key], !raw.isEmpty else { continue }
            let expanded = raw == "~" ? home : raw.hasPrefix("~/") ? home + String(raw.dropFirst()) : raw
            if key == "PI_CONFIG_DIR", !expanded.hasPrefix("/") {
                environment[key] = home + "/" + expanded
            } else {
                guard expanded.hasPrefix("/") else { throw AgentIntegrationError.message("settings.integration.relativeProfile", [key]) }
                environment[key] = expanded
            }
        }
        var directories = Self.searchDirectories(environment: environment)
        if let target, let path = saved(executableKey, target: target), Self.executableFile(path) {
            let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
            guard !directory.contains(":") else {
                throw AgentIntegrationError.message("settings.integration.pathColon")
            }
            directories.insert(directory, at: 0)
        }
        environment["PATH"] = directories.joined(separator: ":")
        return environment
    }

    static func applyingProfile(_ profile: String, target: String, environment: [String: String]) throws -> [String: String] {
        guard let definition = AgentIntegrationDefinition.find(target), let variable = definition.profileVariable else {
            throw AgentIntegrationError.message("settings.integration.profileUnsupported", [target])
        }
        var isDirectory: ObjCBool = false
        guard profile.hasPrefix("/"), FileManager.default.fileExists(atPath: profile, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AgentIntegrationError.message("settings.integration.profileMissing", [profile])
        }
        var result = environment
        if target == "devin" {
            let url = URL(fileURLWithPath: profile).standardizedFileURL
            guard url.lastPathComponent == "devin" else {
                throw AgentIntegrationError.message("settings.integration.devinDirectory")
            }
            result[variable] = url.deletingLastPathComponent().path
        } else {
            result[variable] = profile
        }
        if target == "omp" {
            // Setting PI_CODING_AGENT_DIR redirects both Pi and OMP and herdr
            // rightly refuses the collision. PI_CONFIG_DIR is OMP-specific.
            result.removeValue(forKey: "PI_CODING_AGENT_DIR")
        }
        if target == "grok" { result.removeValue(forKey: "GROK_CONFIG_DIR") }
        return result
    }

    private static func executableFile(_ path: String) -> Bool {
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return false }
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && !directory.boolValue
    }

    private static func searchDirectories(environment: [String: String]) -> [String] {
        let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        var paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        paths += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        paths += [".local/bin", ".cargo/bin", ".bun/bin", ".volta/bin", ".asdf/shims", ".npm-global/bin", ".opencode/bin", ".hermes/venv/bin"].map { home + "/" + $0 }
        // Finder does not inherit shell PATH. Inspect common runtime layouts,
        // without invoking a shell, sourcing rc files, or executing any agent.
        for (root, suffix) in [(home + "/.nvm/versions/node", "/bin"), (home + "/.local/share/fnm/node-versions", "/installation/bin")] {
            let versions = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            paths += versions.sorted().map { root + "/" + $0 + suffix }
        }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    private static func codexStandaloneAvailable(environment: [String: String]) -> Bool {
        let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        let root = (environment["CODEX_HOME"] ?? home + "/.codex") + "/packages/standalone/releases"
        let releases = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return releases.contains { executableFile(root + "/" + $0 + "/bin/codex") }
    }

    struct Status {
        let target: String
        let state: String
        let path: String
        let line: String
    }

    static func parseStatus(_ output: String) throws -> [Status] {
        let pattern = #"^([a-z][a-z0-9_-]*)(?: \(experimental\))?: (not installed|current \((?:v[0-9]+|legacy)\)|outdated \((?:v[0-9]+|legacy) < v[0-9]+\)|needs repair \((?:v[0-9]+|legacy)\)) \((/.*)\)$"#
        let expression = try NSRegularExpression(pattern: pattern)
        var statuses: [Status] = []
        var targets = Set<String>()
        for raw in output.components(separatedBy: .newlines) {
            guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
            guard let match = expression.firstMatch(in: raw, range: range),
                  let targetRange = Range(match.range(at: 1), in: raw),
                  let stateRange = Range(match.range(at: 2), in: raw),
                  let pathRange = Range(match.range(at: 3), in: raw) else {
                throw AgentIntegrationError.message("settings.integration.statusFormat", [raw])
            }
            let target = String(raw[targetRange])
            guard targets.insert(target).inserted else {
                throw AgentIntegrationError.message("settings.integration.duplicateTarget", [target])
            }
            let description = raw[stateRange]
            let state = description == "not installed" ? "notInstalled" : description.hasPrefix("current ") ? "current" : "outdated"
            statuses.append(Status(target: target, state: state, path: String(raw[pathRange]), line: raw))
        }
        guard !statuses.isEmpty else { throw AgentIntegrationError.message("settings.integration.emptyCatalog") }
        return statuses
    }

    private func run(_ executable: String, arguments: [String], environment: [String: String]) throws -> String {
        guard Self.executableFile(executable) else { throw AgentIntegrationError.message("settings.integration.herdrUnavailable", [executable]) }
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("tavern-integration-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("output")
        guard manager.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw AgentIntegrationError.message("settings.integration.outputPreparationFailed")
        }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: environment["HOME"]!)
        process.standardInput = FileHandle.nullDevice
        // A regular private file cannot fill up a pipe and deadlock the child.
        // Merge stderr so warnings and partial-write diagnostics are never lost.
        process.standardOutput = output
        process.standardError = output
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + 15) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
            throw AgentIntegrationError.message("settings.integration.timeout")
        }
        let attributes = try manager.attributesOfItem(atPath: outputURL.path)
        guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= 2 * 1024 * 1024 else {
            throw AgentIntegrationError.message("settings.integration.outputTooLarge")
        }
        let bytes = try Data(contentsOf: outputURL)
        guard let text = String(data: bytes, encoding: .utf8) else { throw AgentIntegrationError.message("settings.integration.invalidUTF8") }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw AgentIntegrationError.message("settings.integration.exit", [Int(process.terminationStatus), text.trimmingCharacters(in: .whitespacesAndNewlines)])
        }
        return text
    }
}

private struct AgentIntegrationDefinition {
    let target: String
    let label: String
    let commands: [String]
    let profileVariable: String?
    private let profileHintKey: String?
    var profileHint: String? {
        if let profileHintKey { return L(profileHintKey) }
        return profileVariable.map { L("settings.integration.profileHint", $0) }
    }

    static func find(_ target: String) -> AgentIntegrationDefinition? { all.first { $0.target == target } }

    private init(_ target: String, _ label: String, _ commands: [String], _ variable: String? = nil, _ hint: String? = nil) {
        self.target = target; self.label = label; self.commands = commands
        profileVariable = variable
        profileHintKey = hint
    }

    static let all: [AgentIntegrationDefinition] = [
        .init("pi", "Pi", ["pi"], "PI_CODING_AGENT_DIR", "settings.integration.profile.pi"),
        .init("omp", "OMP", ["omp"], "PI_CONFIG_DIR", "settings.integration.profile.omp"),
        .init("claude", "Claude Code", ["claude"], "CLAUDE_CONFIG_DIR"),
        .init("codex", "Codex", ["codex"], "CODEX_HOME"),
        .init("copilot", "GitHub Copilot CLI", ["copilot"], "COPILOT_HOME"),
        .init("devin", "Devin CLI", ["devin"], "XDG_CONFIG_HOME", "settings.integration.profile.devin"),
        .init("droid", "Droid", ["droid"]),
        .init("kimi", "Kimi Code CLI", ["kimi"], "KIMI_CODE_HOME"),
        .init("opencode", "OpenCode", ["opencode", "opencode2"]),
        .init("kilo", "Kilo Code CLI", ["kilo", "kilo-code"]),
        .init("hermes", "Hermes Agent", ["hermes"], "HERMES_HOME"),
        .init("qodercli", "Qoder CLI", ["qodercli"], "QODER_CONFIG_DIR"),
        .init("qwen", "Qwen Code", ["qwen"], "QWEN_HOME"),
        .init("letta", "Letta Code", ["letta"]),
        .init("cursor", "Cursor Agent CLI", ["cursor-agent"], "CURSOR_CONFIG_DIR"),
        .init("mastracode", "MastraCode", ["mastracode"]),
        .init("antigravity-cli", "Antigravity CLI", ["agy"], "ANTIGRAVITY_CLI_CONFIG_DIR"),
        .init("grok", "Grok CLI", ["grok"], "GROK_HOME")
    ]
}
