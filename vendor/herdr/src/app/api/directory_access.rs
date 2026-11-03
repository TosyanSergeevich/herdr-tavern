use std::path::Path;

use crate::api::schema::{ResponseResult, ServerDirectoryAccessParams};

use super::responses;

pub(super) fn handle_request(id: String, params: ServerDirectoryAccessParams) -> String {
    let directory = Path::new(&params.path);
    if !directory.is_absolute() || params.path.contains('\0') {
        return responses::encode_error(
            id,
            "invalid_params",
            "path must be an absolute directory path without NUL",
        );
    }

    #[cfg(unix)]
    let checked = crate::pty::backend::validate_launch_directory(directory);
    #[cfg(not(unix))]
    let checked: std::io::Result<()> = Err(std::io::Error::new(
        std::io::ErrorKind::Unsupported,
        "directory access checks are unavailable on this platform",
    ));

    if let Err(error) = checked {
        let code = if error.kind() == std::io::ErrorKind::PermissionDenied {
            "directory_access_denied"
        } else {
            "directory_access_failed"
        };
        return responses::encode_error(id, code, error.to_string());
    }

    responses::encode_success(id, ResponseResult::DirectoryAccess { path: params.path })
}

#[cfg(all(test, unix))]
mod tests {
    use std::os::unix::fs::PermissionsExt;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    use crate::api::schema::Request;
    use crate::app::App;

    struct TestDirectory(PathBuf);

    impl TestDirectory {
        fn new() -> Self {
            static NEXT: AtomicU64 = AtomicU64::new(0);
            let path = std::env::temp_dir().join(format!(
                "herdr-tavern-public-directory-access-{}-{}-{}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_nanos(),
                NEXT.fetch_add(1, Ordering::Relaxed),
            ));
            std::fs::create_dir(&path).unwrap();
            Self(path)
        }
    }

    impl Drop for TestDirectory {
        fn drop(&mut self) {
            let _ = std::fs::set_permissions(&self.0, std::fs::Permissions::from_mode(0o700));
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn request(path: &str) -> serde_json::Value {
        let (_api_tx, api_rx) = tokio::sync::mpsc::unbounded_channel();
        let mut app = App::new(
            &crate::config::Config::default(),
            crate::app::AppPolicy::TEST,
            None,
            api_rx,
            crate::api::EventHub::default(),
        );
        let request: Request = serde_json::from_value(serde_json::json!({
            "id": "directory-access",
            "method": "server.directory_access",
            "params": {"path": path},
        }))
        .unwrap();
        let response = app.handle_api_request(request);
        let response: serde_json::Value = serde_json::from_str(&response).unwrap();
        response
    }

    #[test]
    fn directory_access_returns_only_requested_path_without_changing_cwd() {
        let directory = TestDirectory::new();
        std::fs::write(directory.0.join("not-returned"), b"content").unwrap();
        let before = std::env::current_dir().unwrap();
        let path = directory.0.to_str().unwrap();
        assert_eq!(
            request(path),
            serde_json::json!({
                "id": "directory-access",
                "result": {"type": "directory_access", "path": path},
            })
        );
        assert_eq!(std::env::current_dir().unwrap(), before);
    }

    #[test]
    fn directory_access_rechecks_real_denial_after_permissions_are_restored() {
        if unsafe { libc::geteuid() } == 0 {
            eprintln!("skipped: root bypasses directory permissions");
            return;
        }
        let directory = TestDirectory::new();
        let path = directory.0.to_str().unwrap();
        std::fs::set_permissions(&directory.0, std::fs::Permissions::from_mode(0o000)).unwrap();
        let denied = request(path);
        assert_eq!(denied["error"]["code"], "directory_access_denied");
        let message = denied["error"]["message"].as_str().unwrap();
        let (_, path_json) = message.split_once("TAVERN_DIRECTORY_ACCESS:").unwrap();
        assert_eq!(serde_json::from_str::<String>(path_json).unwrap(), path);

        std::fs::set_permissions(&directory.0, std::fs::Permissions::from_mode(0o700)).unwrap();
        assert_eq!(request(path)["result"]["type"], "directory_access");
    }

    #[test]
    fn directory_access_preserves_missing_path_failure() {
        let directory = TestDirectory::new();
        let missing = directory.0.join("missing");
        let response = request(missing.to_str().unwrap());
        assert_eq!(response["error"]["code"], "directory_access_failed");
    }

    #[test]
    fn directory_access_rejects_relative_path() {
        assert_eq!(request("relative")["error"]["code"], "invalid_params");
    }

    #[test]
    fn directory_access_rejects_nul_path() {
        assert_eq!(request("/invalid\0path")["error"]["code"], "invalid_params");
    }

    #[test]
    fn directory_access_requires_path_parameter() {
        assert!(serde_json::from_value::<Request>(serde_json::json!({
            "id": "missing-path",
            "method": "server.directory_access",
            "params": {},
        }))
        .is_err());
    }
}
