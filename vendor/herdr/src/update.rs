//! Update policy and version helpers for the bundled runtime.
// TAVERN MODIFICATION: standalone downloads, installers and update checks are removed;
// herdr-tavern is updated only as part of Tavern. Local server handoff remains server-owned.

/// Actionable guidance shared by CLI and runtime update surfaces.
pub(crate) const BUNDLED_UPDATE_GUIDANCE: &str =
    "herdr-tavern is bundled with Tavern; update Tavern to update its runtime";

/// Parsed semver version for comparison.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct Version {
    pub major: u32,
    pub minor: u32,
    pub patch: u32,
}

impl Version {
    pub fn parse(s: &str) -> Option<Self> {
        let s = s.strip_prefix('v').unwrap_or(s);
        let mut parts = s.split('.');
        let version = Self {
            major: parts.next()?.parse().ok()?,
            minor: parts.next()?.parse().ok()?,
            patch: parts.next()?.parse().ok()?,
        };
        parts.next().is_none().then_some(version)
    }

    pub fn current() -> Self {
        Self::parse(crate::build_info::BASE_VERSION).expect("invalid CARGO_PKG_VERSION")
    }
}

impl std::fmt::Display for Version {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}.{}.{}", self.major, self.minor, self.patch)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(crate) struct SelfUpdateOptions {
    pub(crate) live_handoff: bool,
}

pub(crate) fn parse_self_update_args(args: &[String]) -> Result<SelfUpdateOptions, String> {
    let mut options = SelfUpdateOptions::default();
    for arg in args {
        match arg.as_str() {
            "--handoff" => options.live_handoff = true,
            "--help" | "-h" => {
                return Err("usage: herdr-tavern update [--handoff]".to_string());
            }
            _ => return Err(format!("unknown update option: {arg}")),
        }
    }
    Ok(options)
}

pub fn self_update(_options: SelfUpdateOptions) -> Result<Version, String> {
    Err(format!(
        "self-update is disabled: {BUNDLED_UPDATE_GUIDANCE}"
    ))
}

pub(crate) fn update_install_command() -> &'static str {
    BUNDLED_UPDATE_GUIDANCE
}

pub(crate) fn update_install_instruction(_install_command: &str) -> String {
    BUNDLED_UPDATE_GUIDANCE.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_helpers_remain_available_for_runtime_compatibility() {
        let version = Version::parse("v1.2.3").unwrap();
        assert_eq!(version.to_string(), "1.2.3");
        assert!(version < Version::parse("1.3.0").unwrap());
        assert!(Version::parse("1.2").is_none());
        assert!(Version::parse("1.2.3.4").is_none());
        assert!(Version::parse("1.2.preview").is_none());
    }

    #[test]
    fn standalone_update_is_rejected() {
        assert_eq!(
            self_update(SelfUpdateOptions::default()).unwrap_err(),
            format!("self-update is disabled: {BUNDLED_UPDATE_GUIDANCE}")
        );
    }

    #[test]
    fn handoff_option_cannot_enable_standalone_installation() {
        let options = parse_self_update_args(&["--handoff".to_string()]).unwrap();
        assert!(options.live_handoff);
        assert!(self_update(options)
            .unwrap_err()
            .contains(BUNDLED_UPDATE_GUIDANCE));
    }

    #[test]
    fn update_help_uses_bundled_runtime_name() {
        assert_eq!(
            parse_self_update_args(&["--help".to_string()]).unwrap_err(),
            "usage: herdr-tavern update [--handoff]"
        );
    }

    #[test]
    fn update_guidance_never_reuses_stale_upstream_commands() {
        assert_eq!(update_install_command(), BUNDLED_UPDATE_GUIDANCE);
        assert_eq!(
            update_install_instruction("herdr update"),
            BUNDLED_UPDATE_GUIDANCE
        );
    }
}
