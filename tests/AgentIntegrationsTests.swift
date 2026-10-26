import Foundation

@main
struct AgentIntegrationsTests {
    static func main() throws {
        try parsesVersionedLegacyAndRepairStates()
        try preservesSpacesParenthesesAndExperimentalTargets()
        try preservesUnknownFutureTargets()
        rejectsUnknownAndDuplicateOutput()
        try profilesRespectAgentEnvironmentRules()
        try blockedProviderKeepsMainResponsive()
        try providerFailureCompletesOnMain()
        try queuedSavesPrecedeListAndInstall()
        print("AgentIntegrationsTests passed")
    }

    static func parsesVersionedLegacyAndRepairStates() throws {
        let statuses = try AgentIntegrationService.parseStatus("""
        pi: current (v9) (/tmp/pi/extensions/herdr.ts)
        omp: outdated (legacy < v10) (/tmp/omp/agent/extensions/herdr.ts)
        claude: needs repair (v10) (/tmp/claude/hooks/herdr.sh)
        codex: not installed (/tmp/codex/herdr.sh)
        """)
        precondition(statuses.map(\.state) == ["current", "outdated", "outdated", "notInstalled"])
    }

    static func preservesSpacesParenthesesAndExperimentalTargets() throws {
        let status = try AgentIntegrationService.parseStatus("letta (experimental): current (v1) (/tmp/Agent Profile (private)/hooks/herdr.sh)\n")[0]
        precondition(status.target == "letta")
        precondition(status.path == "/tmp/Agent Profile (private)/hooks/herdr.sh")
    }

    static func preservesUnknownFutureTargets() throws {
        let status = try AgentIntegrationService.parseStatus("future-agent: current (v42) (/tmp/new agent/herdr.sh)")[0]
        precondition(status.target == "future-agent")
        precondition(status.state == "current")
    }

    static func rejectsUnknownAndDuplicateOutput() {
        expectFailure { _ = try AgentIntegrationService.parseStatus("") }
        expectFailure { _ = try AgentIntegrationService.parseStatus("pi: probably installed (/tmp/pi)") }
        expectFailure { _ = try AgentIntegrationService.parseStatus("warning: unable to read configuration\npi: current (v9) (/tmp/pi)") }
        expectFailure { _ = try AgentIntegrationService.parseStatus("pi: current (v9) (/tmp/pi)\npi: not installed (/tmp/other)") }
        expectFailure { _ = try AgentIntegrationService.parseStatus("pi: current (v9) (relative/path)") }
    }

    static func profilesRespectAgentEnvironmentRules() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("Tavern profiles " + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: root) }
        let devinDirectory = root.appendingPathComponent("devin", isDirectory: true)
        try manager.createDirectory(at: devinDirectory, withIntermediateDirectories: false)
        let inherited = ["HOME": "/unchanged/home", "PI_CODING_AGENT_DIR": "/some/pi/agent", "GROK_CONFIG_DIR": "/old/grok"]

        let omp = try AgentIntegrationService.applyingProfile(root.path, target: "omp", environment: inherited)
        precondition(omp["HOME"] == inherited["HOME"])
        precondition(omp["PI_CONFIG_DIR"] == root.path)
        precondition(omp["PI_CODING_AGENT_DIR"] == nil, "OMP must not share Pi's agent directory")

        let pi = try AgentIntegrationService.applyingProfile(root.path, target: "pi", environment: inherited)
        precondition(pi["PI_CODING_AGENT_DIR"] == root.path)
        precondition(pi["HOME"] == inherited["HOME"])

        let grok = try AgentIntegrationService.applyingProfile(root.path, target: "grok", environment: inherited)
        precondition(grok["GROK_HOME"] == root.path)
        precondition(grok["GROK_CONFIG_DIR"] == nil, "A higher-priority inherited override must not redirect the selected profile")

        let devin = try AgentIntegrationService.applyingProfile(devinDirectory.path, target: "devin", environment: inherited)
        precondition(devin["XDG_CONFIG_HOME"] == root.path)
        expectFailure { _ = try AgentIntegrationService.applyingProfile(root.path, target: "devin", environment: inherited) }
        expectFailure { _ = try AgentIntegrationService.applyingProfile(root.path, target: "letta", environment: inherited) }
        expectFailure { _ = try AgentIntegrationService.applyingProfile(root.path + "/missing", target: "claude", environment: inherited) }
        expectFailure { _ = try AgentIntegrationService.applyingProfile("relative", target: "claude", environment: inherited) }
    }

    static func blockedProviderKeepsMainResponsive() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = DispatchSemaphore(value: 0)
        var entered = false
        var heartbeat = false
        var result: Result<[AgentIntegration], Error>?
        let service = AgentIntegrationService(executable: {
            precondition(!Thread.isMainThread, "Executable discovery must run off main")
            DispatchQueue.main.async { entered = true }
            precondition(gate.wait(timeout: .now() + 5) == .success, "Provider gate timed out")
            return fixture.herdr.path
        }, defaults: fixture.defaults)
        service.list {
            precondition(Thread.isMainThread)
            precondition(result == nil, "Completion must be delivered once")
            result = $0
        }
        waitUntil { entered }
        DispatchQueue.main.async {
            precondition(result == nil, "Blocked discovery must not complete early")
            heartbeat = true
            gate.signal()
        }
        waitUntil { result != nil }
        precondition(heartbeat, "Main must process events while discovery is blocked")
        let rows = try result!.get()
        precondition(rows.map(\.target) == ["claude"])
    }

    static func providerFailureCompletesOnMain() throws {
        enum DiscoveryError: Error { case unavailable }
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = AgentIntegrationService(executable: {
            precondition(!Thread.isMainThread)
            throw DiscoveryError.unavailable
        }, defaults: fixture.defaults)
        var result: Result<[AgentIntegration], Error>?
        service.list {
            precondition(Thread.isMainThread)
            precondition(result == nil)
            result = $0
        }
        waitUntil { result != nil }
        guard case .failure(let error) = result!, case DiscoveryError.unavailable = error else {
            preconditionFailure("Discovery failure must reach the caller unchanged")
        }
    }

    static func queuedSavesPrecedeListAndInstall() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = fixture.root.appendingPathComponent("First profile", isDirectory: true)
        let second = fixture.root.appendingPathComponent("Second profile", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
        let agent = fixture.root.appendingPathComponent("claude")
        try Fixture.writeExecutable("""
        #!/bin/sh
        printf '%s' "$CLAUDE_CONFIG_DIR" > "$CLAUDE_CONFIG_DIR/installed"
        """, to: agent)
        let service = AgentIntegrationService(executable: {
            precondition(!Thread.isMainThread)
            return fixture.herdr.path
        }, defaults: fixture.defaults)
        var listed: Result<[AgentIntegration], Error>?
        var installed: Result<String, Error>?
        var completions: [String] = []
        service.setExecutablePath(agent.path, for: "claude")
        service.setProfileDirectory(first.path, for: "claude")
        service.list {
            precondition(Thread.isMainThread)
            precondition(listed == nil)
            listed = $0
            completions.append("list")
        }
        service.setProfileDirectory(second.path, for: "claude")
        service.install(target: "claude") {
            precondition(Thread.isMainThread)
            precondition(installed == nil)
            installed = $0
            completions.append("install")
        }
        waitUntil { listed != nil && installed != nil }
        let rows = try listed!.get()
        precondition(rows.count == 1)
        precondition(rows[0].profileDirectory == first.path)
        precondition(rows[0].executablePath == agent.path && rows[0].available)
        _ = try installed!.get()
        precondition(completions == ["list", "install"])
        let receipt = try String(contentsOf: second.appendingPathComponent("installed"), encoding: .utf8)
        precondition(receipt == second.path, "Install must use the queued selected profile and executable")
        precondition(!FileManager.default.fileExists(atPath: first.appendingPathComponent("installed").path))
    }

    static func waitUntil(_ predicate: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: 10)
        while !predicate() && Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        }
        precondition(predicate(), "Integration operation timed out")
    }

    private struct Fixture {
        let root: URL
        let herdr: URL
        let suite: String
        let defaults: UserDefaults

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("Tavern-integrations-" + UUID().uuidString, isDirectory: true)
            herdr = root.appendingPathComponent("herdr")
            suite = "org.local.HerdrTavern.integration-tests." + UUID().uuidString
            defaults = UserDefaults(suiteName: suite)!
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            try Self.writeExecutable("""
            #!/bin/sh
            case "$1:$2" in
              integration:status)
                printf 'claude: current (v1) (%s/hooks/herdr.sh)\\n' "${CLAUDE_CONFIG_DIR:-/tmp/tavern-test-default}"
                ;;
              integration:install)
                [ "$3" = claude ] || exit 2
                agent="${0%/*}/claude"
                [ "$(command -v claude)" = "$agent" ] || exit 5
                "$agent" || exit 3
                printf 'Installed\\n'
                ;;
              *) exit 4 ;;
            esac
            """, to: herdr)
        }

        static func writeExecutable(_ source: String, to url: URL) throws {
            try Data((source + "\n").utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }

        func remove() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    static func expectFailure(_ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("Expected a visible parsing/profile error") }
        catch { precondition(!error.localizedDescription.isEmpty) }
    }
}
