// TAVERN MODIFICATION: detection updates ship with Tavern; no remote catalog or asset fetches.
// Local cached manifests and status remain readable for the detection/API contracts.
use std::{cmp::Ordering, collections::BTreeMap, fmt, fs, path::PathBuf};

use serde::{Deserialize, Serialize};

use super::{agent_label, Agent};

pub(crate) const MANIFEST_ENGINE_VERSION: u32 = 3;

#[derive(Debug, Clone)]
pub(crate) struct ManifestVersion(String);

impl ManifestVersion {
    pub(crate) fn parse(value: &str) -> Result<Self, String> {
        let trimmed = value.trim();
        if trimmed.is_empty() {
            return Err("version must not be empty".to_string());
        }
        for segment in trimmed.split('.') {
            if segment.is_empty() {
                return Err(format!("version {trimmed:?} contains an empty segment"));
            }
            if !segment.chars().all(|ch| ch.is_ascii_digit()) {
                return Err(format!("version {trimmed:?} must be dotted numeric"));
            }
            segment
                .parse::<u64>()
                .map_err(|_| format!("version {trimmed:?} contains an oversized segment"))?;
        }
        Ok(Self(trimmed.to_string()))
    }
}

impl fmt::Display for ManifestVersion {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl<'de> Deserialize<'de> for ManifestVersion {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        Self::parse(&value).map_err(serde::de::Error::custom)
    }
}

impl Serialize for ManifestVersion {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        serializer.serialize_str(&self.0)
    }
}

impl Ord for ManifestVersion {
    fn cmp(&self, other: &Self) -> Ordering {
        let mut left = self.0.split('.');
        let mut right = other.0.split('.');
        loop {
            match (left.next(), right.next()) {
                (Some(left), Some(right)) => {
                    let left = left.parse::<u64>().unwrap_or(0);
                    let right = right.parse::<u64>().unwrap_or(0);
                    match left.cmp(&right) {
                        Ordering::Equal => {}
                        ordering => return ordering,
                    }
                }
                (Some(left), None) => {
                    if left.parse::<u64>().unwrap_or(0) != 0 {
                        return Ordering::Greater;
                    }
                }
                (None, Some(right)) => {
                    if right.parse::<u64>().unwrap_or(0) != 0 {
                        return Ordering::Less;
                    }
                }
                (None, None) => return Ordering::Equal,
            }
        }
    }
}

impl PartialOrd for ManifestVersion {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl PartialEq for ManifestVersion {
    fn eq(&self, other: &Self) -> bool {
        self.cmp(other) == Ordering::Equal
    }
}

impl Eq for ManifestVersion {}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ManifestUpdateCommit {
    pub(crate) agent: Agent,
    pub(crate) version: ManifestVersion,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub(crate) struct ManifestUpdateStatus {
    pub(crate) last_check_unix: Option<u64>,
    pub(crate) last_result: Option<String>,
    #[serde(default)]
    pub(crate) agents: BTreeMap<String, AgentRemoteStatus>,
}

impl ManifestUpdateStatus {
    pub(crate) fn agent_status(&self, agent: Agent) -> Option<AgentRemoteStatus> {
        self.agents.get(agent_label(agent)).cloned()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct AgentRemoteStatus {
    pub(crate) cached_version: Option<String>,
    pub(crate) attempted_version: Option<String>,
    pub(crate) last_checked_unix: Option<u64>,
    pub(crate) last_result: String,
    pub(crate) last_error: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ManifestUpdateOutput {
    pub(crate) checked: Vec<Agent>,
    pub(crate) updated: Vec<ManifestUpdateCommit>,
    pub(crate) status: ManifestUpdateStatus,
}

pub(crate) fn check_and_update() -> Result<ManifestUpdateOutput, String> {
    Err(format!(
        "agent detection manifest updates are disabled: {}",
        crate::update::BUNDLED_UPDATE_GUIDANCE
    ))
}

pub(crate) fn load_status() -> ManifestUpdateStatus {
    let path = status_path();
    let Ok(content) = fs::read_to_string(&path) else {
        return ManifestUpdateStatus::default();
    };
    toml::from_str(&content).unwrap_or_else(|err| {
        tracing::warn!(
            path = %path.display(),
            "failed to parse agent detection manifest status: {err}"
        );
        ManifestUpdateStatus::default()
    })
}

pub(crate) fn status_path() -> PathBuf {
    state_root().join("status.toml")
}

pub(crate) fn remote_manifest_path(agent: Agent) -> PathBuf {
    state_root()
        .join("remote")
        .join(format!("{}.toml", agent_label(agent)))
}

fn state_root() -> PathBuf {
    crate::config::state_dir().join("agent-detection")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn manifest_version_compares_dotted_numeric_segments() {
        assert!(
            ManifestVersion::parse("2026.6.10.1").unwrap()
                > ManifestVersion::parse("2026.6.9.9").unwrap()
        );
        assert_eq!(
            ManifestVersion::parse("1.2.0"),
            ManifestVersion::parse("1.2")
        );
        assert!(ManifestVersion::parse("1.2.1").unwrap() > ManifestVersion::parse("1.2").unwrap());
    }

    #[test]
    fn manifest_version_rejects_invalid_segments() {
        for value in ["", "1..2", "1.preview", "18446744073709551616"] {
            assert!(ManifestVersion::parse(value).is_err(), "accepted {value:?}");
        }
    }

    #[test]
    fn explicit_manifest_update_requires_tavern_update() {
        assert_eq!(
            check_and_update().unwrap_err(),
            format!(
                "agent detection manifest updates are disabled: {}",
                crate::update::BUNDLED_UPDATE_GUIDANCE
            )
        );
    }

    #[test]
    fn local_status_contract_retains_agent_diagnostics() {
        let mut status = ManifestUpdateStatus::default();
        let remote = AgentRemoteStatus {
            cached_version: Some("1.2".to_string()),
            attempted_version: None,
            last_checked_unix: None,
            last_result: "cached".to_string(),
            last_error: None,
        };
        status
            .agents
            .insert(agent_label(Agent::Codex).to_string(), remote.clone());
        let encoded = toml::to_string(&status).unwrap();
        let decoded: ManifestUpdateStatus = toml::from_str(&encoded).unwrap();
        assert_eq!(decoded.agent_status(Agent::Codex), Some(remote));
    }
}
