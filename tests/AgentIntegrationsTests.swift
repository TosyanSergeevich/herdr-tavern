import Foundation

@main
struct AgentIntegrationsTests {
    static func main() throws {
        try parsesVersionedLegacyAndRepairStates()
        try preservesSpacesParenthesesAndExperimentalTargets()
        try preservesUnknownFutureTargets()
        rejectsUnknownAndDuplicateOutput()
        try profilesRespectAgentEnvironmentRules()
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

    static func expectFailure(_ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("Expected a visible parsing/profile error") }
        catch { precondition(!error.localizedDescription.isEmpty) }
    }
}
