use std::sync::atomic::{AtomicU8, Ordering};

#[derive(Clone, Copy)]
#[repr(u8)]
enum Language {
    English = 0,
    Russian = 1,
}

static LANGUAGE: AtomicU8 = AtomicU8::new(Language::English as u8);

/// Changes only client-authored diagnostics, never protocol or server data.
/// Unknown ABI values select English, just like an unset preference.
pub(crate) fn set_language(language: u32) {
    let language = if language == Language::Russian as u32 {
        Language::Russian
    } else {
        Language::English
    };
    LANGUAGE.store(language as u8, Ordering::Relaxed);
}

pub(crate) fn text(english: &'static str, russian: &'static str) -> &'static str {
    if is_russian() {
        russian
    } else {
        english
    }
}

pub(crate) fn is_russian() -> bool {
    LANGUAGE.load(Ordering::Relaxed) == Language::Russian as u8
}

// Choose a literal before formatting: parameters stay data, not lookup keys,
// and only the selected branch allocates or evaluates format arguments.
macro_rules! localized_format {
    ($english:literal, $russian:literal $(, $argument:expr)* $(,)?) => {
        if $crate::localization::is_russian() {
            format!($russian $(, $argument)*)
        } else {
            format!($english $(, $argument)*)
        }
    };
}
pub(crate) use localized_format;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        command, config, tavern_client_send_json, tavern_set_language, tavern_string_free,
    };
    use std::{ffi::CStr, ptr, thread};

    struct RestoreEnglish;
    impl Drop for RestoreEnglish {
        fn drop(&mut self) {
            tavern_set_language(0);
        }
    }

    fn boundary_error() -> String {
        let mut error = ptr::null_mut();
        let result =
            unsafe { tavern_client_send_json(ptr::null_mut(), ptr::null(), 0, &mut error) };
        assert_eq!(result, -1);
        assert!(!error.is_null());
        unsafe {
            let message = CStr::from_ptr(error).to_str().unwrap().to_owned();
            tavern_string_free(error);
            message
        }
    }

    fn command_bytes() -> Vec<u8> {
        let command = serde_json::from_value(serde_json::json!({
            "type": "text", "pane_id": "pane", "text": "Ж😀"
        }))
        .unwrap();
        let (message, _) = command::convert(command).unwrap();
        let mut bytes = Vec::new();
        herdr_protocol::write_message(&mut bytes, &message).unwrap();
        bytes
    }

    #[test]
    fn language_switch_changes_worker_diagnostics_not_data_or_validation() {
        // This is the only test that writes the process-wide preference.
        // All other tests assert behavior independently of diagnostic wording.
        let _restore = RestoreEnglish;
        assert!(!is_russian());
        let english_boundary = boundary_error();
        let english_command = command_bytes();
        assert!(command::geometry(0, 24, 8, 20).is_err());
        let valid = serde_json::to_vec(&serde_json::json!({
            "content": "# Настройки\n[theme]\nname = 'nord'\n"
        }))
        .unwrap();
        let english_config = config::config_json(&valid).unwrap();
        let invalid = serde_json::to_vec(&serde_json::json!({
            "content": "",
            "edit": { "kind": "theme", "value": "custom-Ж-theme" }
        }))
        .unwrap();
        let english_dynamic = config::config_json(&invalid).unwrap_err();

        tavern_set_language(1);
        assert!(is_russian());
        let russian_boundary = thread::spawn(boundary_error).join().unwrap();
        let russian_dynamic = config::config_json(&invalid).unwrap_err();
        assert_ne!(english_boundary, russian_boundary);
        assert_ne!(english_dynamic, russian_dynamic);
        for error in [&english_dynamic, &russian_dynamic] {
            assert!(error.contains("theme.name"));
            assert!(error.contains("custom-Ж-theme"));
        }
        assert!(command::geometry(0, 24, 8, 20).is_err());
        assert_eq!(command_bytes(), english_command);
        assert_eq!(config::config_json(&valid).unwrap(), english_config);

        tavern_set_language(0);
        assert_eq!(boundary_error(), english_boundary);
        tavern_set_language(u32::MAX);
        assert!(!is_russian());
        assert_eq!(boundary_error(), english_boundary);
    }
}
