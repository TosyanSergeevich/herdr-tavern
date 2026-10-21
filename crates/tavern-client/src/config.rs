//! Чтение и точечные правки config.toml без файлового IO и подключения к herdr.
use crate::localization::{localized_format, text};
use serde::{Deserialize, Serialize};
use std::borrow::Cow;
use toml_edit::{DocumentMut, InlineTable, Item, Table, TableLike, Value};

const THEMES: &[&str] = &[
    "catppuccin",
    "catppuccin-latte",
    "terminal",
    "tokyo-night",
    "tokyo-night-day",
    "dracula",
    "nord",
    "gruvbox",
    "gruvbox-light",
    "one-dark",
    "one-light",
    "solarized",
    "solarized-light",
    "kanagawa",
    "kanagawa-lotus",
    "rose-pine",
    "rose-pine-dawn",
    "vesper",
];
const INDICATORS: &[&str] = &["dots", "symbols"];
const TOAST: &[&str] = &["off", "herdr", "terminal", "system"];

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request<'a> {
    #[serde(borrow)]
    content: Cow<'a, str>,
    #[serde(borrow)]
    edit: Option<Edit<'a>>,
}

#[derive(Deserialize)]
#[serde(
    tag = "kind",
    content = "value",
    rename_all = "lowercase",
    deny_unknown_fields
)]
enum Edit<'a> {
    Theme(#[serde(borrow)] Cow<'a, str>),
    Indicators(#[serde(borrow)] Cow<'a, str>),
    Sound(bool),
    Toast(#[serde(borrow)] Cow<'a, str>),
}

#[derive(Debug, Serialize)]
struct Settings<'a> {
    theme: &'a str,
    auto_switch: bool,
    indicators: &'a str,
    sound: bool,
    toast: &'a str,
}

#[derive(Serialize)]
struct Response<'a> {
    content: &'a str,
    settings: Settings<'a>,
}

fn table_at<'a>(root: &'a Item, path: &[&str]) -> Result<Option<&'a dyn TableLike>, String> {
    let mut item = root;
    for key in path {
        let table = item.as_table_like().ok_or_else(|| {
            localized_format!(
                "Expected configuration table: {}",
                "Ожидалась таблица конфигурации: {}",
                path.join(".")
            )
        })?;
        let Some(child) = table.get(key) else {
            return Ok(None);
        };
        item = child;
    }
    item.as_table_like().map(Some).ok_or_else(|| {
        localized_format!(
            "Expected configuration table: {}",
            "Ожидалась таблица конфигурации: {}",
            path.join(".")
        )
    })
}

fn field<'a>(root: &'a Item, path: &[&str], key: &str) -> Result<Option<&'a Item>, String> {
    Ok(table_at(root, path)?.and_then(|table| table.get(key)))
}

fn string<'a>(
    root: &'a Item,
    path: &[&str],
    key: &str,
    default: &'a str,
) -> Result<&'a str, String> {
    match field(root, path, key)? {
        Some(item) => item.as_str().ok_or_else(|| {
            localized_format!(
                "Expected string: {}.{key}",
                "Ожидалась строка: {}.{key}",
                path.join(".")
            )
        }),
        None => Ok(default),
    }
}

fn boolean(root: &Item, path: &[&str], key: &str, default: bool) -> Result<bool, String> {
    match field(root, path, key)? {
        Some(item) => item.as_bool().ok_or_else(|| {
            localized_format!(
                "Expected boolean: {}.{key}",
                "Ожидалось логическое значение: {}.{key}",
                path.join(".")
            )
        }),
        None => Ok(default),
    }
}

fn allowed(value: &str, choices: &[&str], field: &str) -> Result<(), String> {
    if choices.contains(&value) {
        Ok(())
    } else {
        Err(localized_format!(
            "Invalid value for {field}: {value}",
            "Недопустимое значение {field}: {value}"
        ))
    }
}

fn settings(root: &Item) -> Result<Settings<'_>, String> {
    let indicators = string(root, &["ui"], "status_indicators", "dots")?;
    allowed(indicators, INDICATORS, "ui.status_indicators")?;
    // В herdr явная delivery приоритетнее устаревшего enabled; true означает herdr.
    let legacy_toast = boolean(root, &["ui", "toast"], "enabled", false)?;
    let toast = string(
        root,
        &["ui", "toast"],
        "delivery",
        if legacy_toast { "herdr" } else { "off" },
    )?;
    allowed(toast, TOAST, "ui.toast.delivery")?;
    Ok(Settings {
        theme: string(root, &["theme"], "name", "catppuccin")?,
        auto_switch: boolean(root, &["theme"], "auto_switch", false)?,
        indicators,
        sound: boolean(root, &["ui", "sound"], "enabled", true)?,
        toast,
    })
}

fn table_at_mut<'a>(root: &'a mut Item, path: &[&str]) -> Result<&'a mut dyn TableLike, String> {
    let inline = root.is_inline_table();
    let table = root.as_table_like_mut().ok_or_else(|| {
        localized_format!(
            "Expected configuration table: {}",
            "Ожидалась таблица конфигурации: {}",
            path.join(".")
        )
    })?;
    let Some((key, rest)) = path.split_first() else {
        return Ok(table);
    };
    if !table.contains_key(key) {
        // TableLike::insert для inline-таблицы принимает только Value, не Table.
        let child = if inline {
            Item::Value(Value::InlineTable(InlineTable::new()))
        } else {
            Item::Table(Table::new())
        };
        table.insert(key, child);
    }
    let child = table.get_mut(key).ok_or_else(|| {
        text(
            "Failed to create configuration table",
            "Не удалось создать таблицу конфигурации",
        )
        .to_string()
    })?;
    table_at_mut(child, rest)
}

fn set(root: &mut Item, path: &[&str], key: &str, mut value: Value) -> Result<(), String> {
    let table = table_at_mut(root, path)?;
    if let Some(old) = table.get(key) {
        let old = old
            .as_value()
            .filter(|value| !value.is_inline_table() && !value.is_array())
            .ok_or_else(|| {
                localized_format!(
                    "Expected scalar value: {}.{key}",
                    "Ожидалось скалярное значение: {}.{key}",
                    path.join(".")
                )
            })?;
        *value.decor_mut() = old.decor().clone();
    }
    table.insert(key, Item::Value(value));
    Ok(())
}

fn apply(root: &mut Item, edit: Edit<'_>) -> Result<(), String> {
    match edit {
        Edit::Theme(name) => {
            allowed(&name, THEMES, "theme.name")?;
            set(root, &["theme"], "name", Value::from(name.as_ref()))?;
            set(root, &["theme"], "auto_switch", Value::from(false))
        }
        Edit::Indicators(style) => {
            allowed(&style, INDICATORS, "ui.status_indicators")?;
            set(
                root,
                &["ui"],
                "status_indicators",
                Value::from(style.as_ref()),
            )
        }
        Edit::Sound(enabled) => set(root, &["ui", "sound"], "enabled", Value::from(enabled)),
        Edit::Toast(delivery) => {
            allowed(&delivery, TOAST, "ui.toast.delivery")?;
            set(
                root,
                &["ui", "toast"],
                "delivery",
                Value::from(delivery.as_ref()),
            )?;
            table_at_mut(root, &["ui", "toast"])?.remove("enabled");
            Ok(())
        }
    }
}

pub(crate) fn config_json(json: &[u8]) -> Result<String, String> {
    let request: Request<'_> = serde_json::from_slice(json).map_err(|error| {
        localized_format!(
            "Invalid settings request: {error}",
            "Некорректный запрос настроек: {error}"
        )
    })?;
    let mut document = request.content.parse::<DocumentMut>().map_err(|error| {
        localized_format!("Invalid TOML: {error}", "Некорректный TOML: {error}")
    })?;
    let edited_content;
    let content = if let Some(edit) = request.edit {
        // Не исправляем другие некорректные настройки молча при точечной правке.
        settings(document.as_item())?;
        apply(document.as_item_mut(), edit)?;
        edited_content = document.to_string();
        edited_content.as_str()
    } else {
        request.content.as_ref()
    };
    let response = Response {
        content,
        settings: settings(document.as_item())?,
    };
    serde_json::to_string(&response).map_err(|error| {
        localized_format!(
            "Failed to serialize settings: {error}",
            "Не удалось сериализовать настройки: {error}"
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value as Json};

    fn request(content: &str, edit: Option<Json>) -> Result<Json, String> {
        let json = serde_json::to_vec(&json!({ "content": content, "edit": edit })).unwrap();
        config_json(&json).map(|response| serde_json::from_str(&response).unwrap())
    }

    fn edited(content: &str, kind: &str, value: Json) -> Json {
        request(content, Some(json!({ "kind": kind, "value": value }))).unwrap()
    }

    #[test]
    fn empty_config_has_herdr_defaults_without_adding_fields() {
        let response = request("", None).unwrap();
        assert_eq!(response["content"], "");
        assert_eq!(
            response["settings"],
            json!({
                "theme": "catppuccin", "auto_switch": false,
                "indicators": "dots", "sound": true, "toast": "off"
            })
        );
    }

    #[test]
    fn read_only_preserves_config_byte_for_byte() {
        let content = "# Настройки\n\n[theme]\nname = 'nord' # любимая тема\n";
        let response = request(content, None).unwrap();
        assert_eq!(response["content"], content);
        assert_eq!(response["settings"]["theme"], "nord");
    }

    #[test]
    fn theme_edit_disables_auto_switch_and_preserves_custom_fields_and_comments() {
        let content = "# Начало\n[theme] # Тема\nname = 'nord' # название\nauto_switch = true # автоматически\ndark_name = 'dracula'\n[theme.custom]\naccent = '#abcdef'\n\n[terminal]\ndefault_shell = '/bin/zsh' # оболочка\n";
        let response = edited(content, "theme", json!("kanagawa"));
        assert_eq!(response["settings"]["theme"], "kanagawa");
        assert_eq!(response["settings"]["auto_switch"], false);
        let result = response["content"].as_str().unwrap();
        assert!(result.contains("name = \"kanagawa\" # название"));
        assert!(result.contains("auto_switch = false # автоматически"));
        assert!(result.contains("dark_name = 'dracula'\n[theme.custom]\naccent = '#abcdef'"));
        assert!(result.contains("[terminal]\ndefault_shell = '/bin/zsh' # оболочка\n"));
        assert!(result.starts_with("# Начало\n[theme] # Тема\n"));
    }

    #[test]
    fn inline_tables_keep_unrelated_settings_when_adding_nested_sound() {
        let content = "ui = { status_indicators = 'symbols', toast = { enabled = true }, accent = 'cyan' } # UI\n";
        let response = edited(content, "sound", json!(false));
        let result = response["content"].as_str().unwrap();
        let reread = request(result, None).unwrap();
        assert_eq!(reread["settings"]["sound"], false);
        assert_eq!(reread["settings"]["indicators"], "symbols");
        assert_eq!(reread["settings"]["toast"], "herdr");
        assert!(result.contains("accent = 'cyan'"));
        assert!(result.ends_with("# UI\n"));
        assert!(!result.contains("[ui.sound]"));
    }

    #[test]
    fn dotted_keys_remain_valid_and_preserve_their_comments() {
        let content = "ui.status_indicators = 'dots' # значки\nui.sound.enabled = true # звук\nui.toast.enabled = true\ntheme.name = 'nord'\ntheme.auto_switch = true\n";
        let indicators = edited(content, "indicators", json!("symbols"));
        let sound = edited(
            indicators["content"].as_str().unwrap(),
            "sound",
            json!(false),
        );
        let theme = edited(sound["content"].as_str().unwrap(), "theme", json!("vesper"));
        let toast = edited(theme["content"].as_str().unwrap(), "toast", json!("system"));
        let result = toast["content"].as_str().unwrap();
        assert!(result.contains("ui.status_indicators = \"symbols\" # значки"));
        assert!(result.contains("ui.sound.enabled = false # звук"));
        assert!(!result.contains("ui.toast.enabled"));
        assert_eq!(
            request(result, None).unwrap()["settings"],
            toast["settings"]
        );
        assert_eq!(
            toast["settings"],
            json!({
                "theme": "vesper", "auto_switch": false,
                "indicators": "symbols", "sound": false, "toast": "system"
            })
        );
    }

    #[test]
    fn toast_delivery_overrides_legacy_enabled_and_migration_preserves_nested_tables() {
        let content = "[ui.toast]\nenabled = true\ndelivery = 'terminal' # доставка\ndelay_seconds = 3\n[ui.toast.clipboard]\nenabled = false # буфер\n";
        assert_eq!(
            request(content, None).unwrap()["settings"]["toast"],
            "terminal"
        );
        let response = edited(content, "toast", json!("off"));
        let result = response["content"].as_str().unwrap();
        assert!(result.contains("delivery = \"off\" # доставка"));
        assert!(result.contains("delay_seconds = 3\n[ui.toast.clipboard]\nenabled = false # буфер"));
        let parsed = result.parse::<DocumentMut>().unwrap();
        assert!(field(parsed.as_item(), &["ui", "toast"], "enabled")
            .unwrap()
            .is_none());
        assert_eq!(response["settings"]["toast"], "off");
    }

    #[test]
    fn legacy_toast_boolean_matches_herdr_semantics() {
        assert_eq!(
            request("[ui.toast]\nenabled = true\n", None).unwrap()["settings"]["toast"],
            "herdr"
        );
        assert_eq!(
            request("[ui.toast]\nenabled = false\n", None).unwrap()["settings"]["toast"],
            "off"
        );
    }

    #[test]
    fn inline_toast_migration_does_not_replace_its_siblings() {
        let response = edited("ui = { toast = { enabled = true, delay_seconds = 2, clipboard = { enabled = false } }, accent = 'cyan' }\n", "toast", json!("herdr"));
        let result = response["content"].as_str().unwrap();
        let parsed = result.parse::<DocumentMut>().unwrap();
        assert!(field(parsed.as_item(), &["ui", "toast"], "enabled")
            .unwrap()
            .is_none());
        assert_eq!(
            field(parsed.as_item(), &["ui", "toast", "clipboard"], "enabled")
                .unwrap()
                .unwrap()
                .as_bool(),
            Some(false)
        );
        assert!(result.contains("delay_seconds = 2"));
        assert!(result.contains("accent = 'cyan'"));
        assert_eq!(request(result, None).unwrap()["settings"]["toast"], "herdr");
    }

    #[test]
    fn malformed_toml_is_refused_even_for_read_only_requests() {
        assert!(request("[ui\n", None).is_err());
        assert!(request(
            "[theme]\nname = 'nord'\nname = 'vesper'\n",
            Some(json!({ "kind": "sound", "value": true }))
        )
        .is_err());
    }

    #[test]
    fn scalar_and_array_table_conflicts_are_refused_without_replacement() {
        for content in [
            "ui = false\n",
            "ui = []\n",
            "ui.sound = 'on'\n",
            "theme = 'nord'\n",
            "[ui]\ntoast = false\n",
        ] {
            assert!(
                request(content, Some(json!({ "kind": "sound", "value": false }))).is_err(),
                "{content}"
            );
        }
    }

    #[test]
    fn invalid_edit_kinds_types_and_values_are_refused() {
        for edit in [
            json!({ "kind": "theme", "value": "unknown" }),
            json!({ "kind": "theme", "value": false }),
            json!({ "kind": "sound", "value": "true" }),
            json!({ "kind": "indicators", "value": "emoji" }),
            json!({ "kind": "toast", "value": "all" }),
            json!({ "kind": "integrations", "value": true }),
        ] {
            assert!(request("", Some(edit.clone())).is_err(), "{edit}");
        }
    }

    #[test]
    fn incorrect_setting_types_are_not_silently_overwritten() {
        assert!(request(
            "[ui.sound]\nenabled = 'yes'\n",
            Some(json!({ "kind": "sound", "value": false }))
        )
        .is_err());
        assert!(request(
            "[theme]\nauto_switch = {}\n",
            Some(json!({ "kind": "theme", "value": "nord" }))
        )
        .is_err());
    }

    #[test]
    fn missing_sections_are_created_without_dropping_existing_dotted_keys() {
        let response = edited("ui.accent = 'cyan' # цвет\n", "sound", json!(false));
        let result = response["content"].as_str().unwrap();
        assert!(result.contains("ui.accent = 'cyan' # цвет"));
        assert_eq!(request(result, None).unwrap()["settings"]["sound"], false);
        let theme = edited("", "theme", json!("nord"));
        assert_eq!(
            request(theme["content"].as_str().unwrap(), None).unwrap()["settings"]["theme"],
            "nord"
        );
    }

    #[test]
    fn ffi_returns_owned_json_and_clears_error() {
        let json = br#"{"content":"","edit":{"kind":"theme","value":"\u006eord"}}"#;
        unsafe {
            let mut response = std::ptr::null_mut();
            let mut error = std::ptr::dangling_mut();
            assert_eq!(
                crate::tavern_config_json(json.as_ptr(), json.len(), &mut response, &mut error),
                0
            );
            assert!(error.is_null());
            let result: Json =
                serde_json::from_str(std::ffi::CStr::from_ptr(response).to_str().unwrap()).unwrap();
            assert_eq!(result["settings"]["theme"], "nord");
            crate::tavern_string_free(response);
        }
    }

    #[test]
    fn ffi_invalid_toml_returns_error_and_no_response() {
        let json = br#"{"content":"ui = ["}"#;
        unsafe {
            let mut response = std::ptr::dangling_mut();
            let mut error = std::ptr::null_mut();
            assert_eq!(
                crate::tavern_config_json(json.as_ptr(), json.len(), &mut response, &mut error),
                -1
            );
            assert!(response.is_null());
            assert!(!error.is_null());
            crate::tavern_string_free(error);
        }
    }

    #[test]
    fn ffi_rejects_null_and_oversized_input_before_reading_it() {
        unsafe {
            let mut response = std::ptr::null_mut();
            let mut error = std::ptr::null_mut();
            assert_eq!(
                crate::tavern_config_json(std::ptr::null(), 1, &mut response, &mut error),
                -1
            );
            assert!(response.is_null());
            assert!(!error.is_null());
            crate::tavern_string_free(error);
            assert_eq!(
                crate::tavern_config_json(
                    std::ptr::dangling(),
                    crate::transport::MAX_JSON + 1,
                    &mut response,
                    &mut error
                ),
                -1
            );
            assert!(response.is_null());
            assert!(!error.is_null());
            crate::tavern_string_free(error);
        }
    }

    #[test]
    fn ffi_rejects_missing_output_and_invalid_utf8() {
        let json = br#"{"content":""}"#;
        unsafe {
            let mut error = std::ptr::null_mut();
            assert_eq!(
                crate::tavern_config_json(
                    json.as_ptr(),
                    json.len(),
                    std::ptr::null_mut(),
                    &mut error
                ),
                -1
            );
            assert!(!error.is_null());
            crate::tavern_string_free(error);
            let mut response = std::ptr::null_mut();
            assert_eq!(
                crate::tavern_config_json([0xff].as_ptr(), 1, &mut response, &mut error),
                -1
            );
            assert!(response.is_null());
            assert!(!error.is_null());
            crate::tavern_string_free(error);
        }
    }
}
