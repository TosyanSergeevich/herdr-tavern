// TAVERN MODIFICATION: preserve local release-note reads and acknowledgements, without updater writes or fake previews.
use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

const PENDING_RELEASE_NOTES_PATH: &str = "release-notes.json";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReleaseNotes {
    pub version: String,
    pub body: String,
    pub preview: bool,
}

#[derive(Debug, Serialize, Deserialize)]
struct StoredReleaseNotes {
    version: String,
    body: String,
    #[serde(default = "default_show_on_startup")]
    show_on_startup: bool,
}

fn default_show_on_startup() -> bool {
    true
}

pub fn pending_path() -> PathBuf {
    let mut path = crate::config::config_path();
    path.set_file_name(PENDING_RELEASE_NOTES_PATH);
    path
}

fn write_stored_to_path(path: &Path, stored: &StoredReleaseNotes) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }

    let json = serde_json::to_string_pretty(stored).map_err(std::io::Error::other)?;
    let tmp_path = path.with_extension(format!("json.tmp.{}", std::process::id()));
    fs::write(&tmp_path, json)?;
    if let Err(err) = fs::rename(&tmp_path, path) {
        let _ = fs::remove_file(&tmp_path);
        return Err(err);
    }
    Ok(())
}

fn load_stored_from_path(path: &Path) -> Option<StoredReleaseNotes> {
    let content = fs::read_to_string(path).ok()?;
    serde_json::from_str(&content).ok()
}

pub fn load_latest() -> Option<ReleaseNotes> {
    load_latest_from_path(&pending_path(), &crate::build_info::version())
}

fn load_latest_from_path(path: &Path, current_version: &str) -> Option<ReleaseNotes> {
    let stored = load_stored_from_path(path)?;
    release_notes_from_stored(stored, current_version)
}

fn release_notes_from_stored(
    stored: StoredReleaseNotes,
    current_version: &str,
) -> Option<ReleaseNotes> {
    let body = normalize_body(&stored.body);
    if body.is_empty() {
        return None;
    }

    let preview = match (
        crate::update::Version::parse(&stored.version),
        crate::update::Version::parse(current_version),
    ) {
        (Some(stored_version), Some(current_version)) => stored_version > current_version,
        _ => false,
    };

    Some(ReleaseNotes {
        preview,
        version: stored.version,
        body,
    })
}

pub fn mark_current_version_seen() -> std::io::Result<()> {
    mark_current_version_seen_at(&pending_path(), &crate::build_info::version())
}

fn mark_current_version_seen_at(path: &Path, current_version: &str) -> std::io::Result<()> {
    let Some(mut stored) = load_stored_from_path(path) else {
        return Ok(());
    };
    if stored.version != current_version || !stored.show_on_startup {
        return Ok(());
    }
    stored.show_on_startup = false;
    write_stored_to_path(path, &stored)
}

pub fn normalize_body(body: &str) -> String {
    body.lines()
        .map(str::trim_end)
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preserves_headings() {
        assert_eq!(
            normalize_body("### Changed\n- One\n\n### Fixed\n- Two"),
            "### Changed\n- One\n\n### Fixed\n- Two"
        );
    }

    #[test]
    fn load_latest_keeps_future_version_previewable_before_restart() {
        let path = std::env::temp_dir().join(format!(
            "herdr-tavern-release-notes-{}-{}.json",
            std::process::id(),
            "preview"
        ));
        fs::write(
            &path,
            r####"{"version":"0.3.2","body":"### Changed\n- One"}"####,
        )
        .unwrap();

        let notes = load_latest_from_path(&path, "0.3.1").expect("latest notes");
        assert_eq!(notes.version, "0.3.2");
        assert_eq!(notes.body, "### Changed\n- One");
        assert!(notes.preview);

        fs::remove_file(&path).unwrap();
    }

    #[test]
    fn load_latest_does_not_mark_older_saved_version_as_preview() {
        let path = std::env::temp_dir().join(format!(
            "herdr-tavern-release-notes-{}-{}.json",
            std::process::id(),
            "stale"
        ));
        fs::write(
            &path,
            r####"{"version":"0.3.0","body":"### Changed\n- One"}"####,
        )
        .unwrap();

        let notes = load_latest_from_path(&path, "0.3.1").expect("latest notes");
        assert_eq!(notes.version, "0.3.0");
        assert_eq!(notes.body, "### Changed\n- One");
        assert!(!notes.preview);

        fs::remove_file(&path).unwrap();
    }

    #[test]
    fn marking_current_version_seen_preserves_latest_notes() {
        let path = std::env::temp_dir().join(format!(
            "herdr-tavern-release-notes-{}-{}.json",
            std::process::id(),
            "seen"
        ));
        fs::write(
            &path,
            r####"{"version":"0.3.1","body":"### Changed\n- One"}"####,
        )
        .unwrap();

        mark_current_version_seen_at(&path, "0.3.1").unwrap();

        let stored = load_stored_from_path(&path).expect("stored notes");
        assert!(!stored.show_on_startup);
        let latest = load_latest_from_path(&path, "0.3.1").expect("latest notes");
        assert_eq!(latest.version, "0.3.1");
        assert!(!latest.preview);

        fs::remove_file(&path).unwrap();
    }

    #[test]
    fn legacy_notes_without_show_on_startup_remain_available_as_latest() {
        let path = std::env::temp_dir().join(format!(
            "herdr-tavern-release-notes-{}-{}.json",
            std::process::id(),
            "legacy"
        ));
        fs::write(
            &path,
            "{\n  \"version\": \"0.3.1\",\n  \"body\": \"### Changed\\n- One\"\n}",
        )
        .unwrap();

        assert!(load_latest_from_path(&path, "0.3.1").is_some());

        fs::remove_file(&path).unwrap();
    }
}
