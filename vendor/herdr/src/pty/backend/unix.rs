// Modified for Tavern: reject inaccessible launch directories before starting a shell.
use std::ffi::CString;
use std::io;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

use std::os::fd::{FromRawFd, OwnedFd};

use portable_pty::{native_pty_system, Child, CommandBuilder, PtySize};

use crate::pty::fd;

pub(crate) struct SpawnedPty {
    pub master_fd: OwnedFd,
    pub child: Box<dyn Child + Send + Sync>,
}

/// Check target directory access and path traversal without changing the server cwd.
///
/// Exercise directory enumeration only for the selected directory to detect
/// filesystem/TCC denial. Ancestors need search access, not read access: a shell
/// can legitimately recover its cwd below a searchable, non-enumerable parent.
pub(crate) fn validate_launch_directory(cwd: &Path) -> io::Result<()> {
    let absolute = std::path::absolute(cwd)?;
    let check = || -> io::Result<()> {
        let canonical = std::fs::canonicalize(&absolute)?;
        // Open first so a regular file remains ENOTDIR, not an apparent
        // authorization failure merely because it is not executable.
        let mut entries = std::fs::read_dir(&absolute)?;
        if let Some(entry) = entries.next() {
            entry?;
        }
        for directory in absolute.ancestors().chain(canonical.ancestors()) {
            // Do not require enumeration permission for ancestor directories.
            let name = CString::new(directory.as_os_str().as_bytes())
                .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "directory contains NUL"))?;
            // SAFETY: name is a NUL-terminated path, valid for this call.
            if unsafe { libc::access(name.as_ptr(), libc::X_OK) } != 0 {
                return Err(io::Error::last_os_error());
            }
        }
        Ok(())
    };
    check().map_err(|err| match err.raw_os_error() {
        Some(libc::EPERM | libc::EACCES) => io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!(
                "Directory access requires authorization. TAVERN_DIRECTORY_ACCESS:{}",
                serde_json::to_string(&absolute.to_string_lossy())
                    .expect("a directory path string is JSON serializable")
            ),
        ),
        _ => err,
    })
}

pub(crate) fn spawn_with_portable_pty(
    rows: u16,
    cols: u16,
    cmd: CommandBuilder,
) -> std::io::Result<SpawnedPty> {
    if let Some(cwd) = cmd.get_cwd() {
        validate_launch_directory(Path::new(cwd))?;
    }
    let pty_system = native_pty_system();
    let pair = pty_system
        .openpty(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        })
        .map_err(|err| std::io::Error::other(err.to_string()))?;
    let master_fd = pair
        .master
        .as_raw_fd()
        .ok_or_else(|| std::io::Error::other("pty master fd is unavailable"))?;
    let actor_fd = fd::duplicate_cloexec_fd(master_fd)?;
    let actor_fd = unsafe { OwnedFd::from_raw_fd(actor_fd) };
    let child = pair
        .slave
        .spawn_command(cmd)
        .map_err(|err| std::io::Error::other(err.to_string()))?;
    drop(pair);

    Ok(SpawnedPty {
        master_fd: actor_fd,
        child,
    })
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::*;
    use std::sync::{Mutex, OnceLock};

    fn pty_fd_test_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

    fn parent_pty_fd_targets() -> Vec<String> {
        let Ok(entries) = std::fs::read_dir("/proc/self/fd") else {
            return Vec::new();
        };
        let mut targets: Vec<String> = entries
            .filter_map(Result::ok)
            .filter_map(|entry| std::fs::read_link(entry.path()).ok())
            .map(|target| target.to_string_lossy().into_owned())
            .filter(|target| target.starts_with("/dev/pts/") || target == "/dev/ptmx")
            .collect();
        targets.sort();
        targets
    }

    fn parent_pty_fd_count() -> usize {
        parent_pty_fd_targets().len()
    }

    #[test]
    fn portable_pty_setup_leaves_one_parent_pty_fd() {
        let _guard = pty_fd_test_lock().lock().expect("pty fd test lock");
        let before = parent_pty_fd_count();
        let mut cmd = CommandBuilder::new("/bin/cat");
        cmd.env(crate::HERDR_ENV_VAR, crate::HERDR_ENV_VALUE);

        let mut spawned =
            spawn_with_portable_pty(24, 80, cmd).expect("portable pty setup succeeds");
        let after_spawn = parent_pty_fd_count();

        assert_eq!(
            after_spawn,
            before + 1,
            "portable-pty setup should leave only the Herdr-owned master fd in the parent: {:?}",
            parent_pty_fd_targets()
        );

        let _ = spawned.child.kill();
        let _ = spawned.child.wait();
        drop(spawned.master_fd);
    }
}

#[cfg(test)]
mod directory_access_tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    struct TestDirectory(PathBuf);

    impl TestDirectory {
        fn new() -> Self {
            static NEXT: AtomicU64 = AtomicU64::new(0);
            let path = std::env::temp_dir().join(format!(
                "herdr-tavern-directory-access-{}-{}-{}",
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
            // Restore parent access before removing children, even after a panic.
            let _ = std::fs::set_permissions(&self.0, std::fs::Permissions::from_mode(0o700));
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn assert_authorization_error(err: io::Error, expected: &Path) {
        assert_eq!(err.kind(), io::ErrorKind::PermissionDenied);
        let message = err.to_string();
        let (_, path_json) = message.split_once("TAVERN_DIRECTORY_ACCESS:").unwrap();
        let actual: String = serde_json::from_str(path_json).unwrap();
        assert_eq!(Path::new(&actual), expected);
    }

    #[test]
    fn directory_access_accepts_normal_directory_without_changing_cwd() {
        let directory = TestDirectory::new();
        let before = std::env::current_dir().unwrap();
        validate_launch_directory(&directory.0).unwrap();
        assert_eq!(std::env::current_dir().unwrap(), before);
    }

    #[test]
    fn directory_access_preserves_missing_directory_error() {
        let directory = TestDirectory::new();
        let err = validate_launch_directory(&directory.0.join("missing")).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::NotFound);
        assert!(!err.to_string().contains("TAVERN_DIRECTORY_ACCESS:"));
    }

    #[test]
    fn directory_access_preserves_not_a_directory_error() {
        let directory = TestDirectory::new();
        let file = directory.0.join("file");
        std::fs::write(&file, b"").unwrap();
        let err = validate_launch_directory(&file).unwrap_err();
        assert_eq!(err.raw_os_error(), Some(libc::ENOTDIR));
        assert!(!err.to_string().contains("TAVERN_DIRECTORY_ACCESS:"));
    }

    #[test]
    fn directory_access_rejects_unreadable_directory_before_shell_spawn() {
        // Root bypasses POSIX permission bits; this regression requires an
        // ordinary user, as used by the native app.
        if unsafe { libc::geteuid() } == 0 {
            eprintln!("skipped: root bypasses directory permissions");
            return;
        }
        let directory = TestDirectory::new();
        std::fs::set_permissions(&directory.0, std::fs::Permissions::from_mode(0o000)).unwrap();
        let mut cmd = CommandBuilder::new("/bin/sh");
        cmd.cwd(&directory.0);
        match spawn_with_portable_pty(24, 80, cmd) {
            Err(err) => assert_authorization_error(err, &directory.0),
            Ok(mut spawned) => {
                let _ = spawned.child.kill();
                let _ = spawned.child.wait();
                panic!("an inaccessible directory must not start a shell");
            }
        }
    }

    #[test]
    fn directory_access_accepts_searchable_but_unreadable_parent() {
        if unsafe { libc::geteuid() } == 0 {
            eprintln!("skipped: root bypasses directory permissions");
            return;
        }
        let directory = TestDirectory::new();
        let child = directory.0.join("folder \"with quotes\"");
        std::fs::create_dir(&child).unwrap();
        let expected = child.canonicalize().unwrap();
        // Search permits shell startup and physical pwd without parent enumeration.
        std::fs::set_permissions(&directory.0, std::fs::Permissions::from_mode(0o300)).unwrap();
        let child_name = CString::new(child.as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { libc::access(child_name.as_ptr(), libc::X_OK) }, 0);
        validate_launch_directory(&child).unwrap();
        let output = std::process::Command::new("/bin/sh")
            .args(["-c", "pwd -P"])
            .current_dir(&child)
            .output()
            .unwrap();
        assert!(output.status.success());
        assert_eq!(
            String::from_utf8(output.stdout).unwrap().trim_end(),
            expected.to_str().unwrap()
        );
    }

    #[test]
    fn directory_access_rejects_non_searchable_parent() {
        if unsafe { libc::geteuid() } == 0 {
            eprintln!("skipped: root bypasses directory permissions");
            return;
        }
        let directory = TestDirectory::new();
        let child = directory.0.join("folder \"with quotes\"");
        std::fs::create_dir(&child).unwrap();
        std::fs::set_permissions(&directory.0, std::fs::Permissions::from_mode(0o600)).unwrap();
        let err = validate_launch_directory(&child).unwrap_err();
        assert_authorization_error(err, &child);
    }
}
