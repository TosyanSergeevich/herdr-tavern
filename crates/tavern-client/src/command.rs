use crate::localization::text;
use herdr_protocol::*;
use serde::Deserialize;
use serde_json::{json, Value};

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "lowercase", deny_unknown_fields)]
pub enum Command {
    Resize {
        cols: u16,
        rows: u16,
        cell_width_px: u32,
        cell_height_px: u32,
    },
    Text {
        #[serde(default)]
        pane_id: Option<String>,
        #[serde(default)]
        terminal_id: Option<String>,
        text: String,
    },
    Paste {
        #[serde(default)]
        pane_id: Option<String>,
        #[serde(default)]
        terminal_id: Option<String>,
        text: String,
    },
    Key {
        #[serde(default)]
        pane_id: Option<String>,
        #[serde(default)]
        terminal_id: Option<String>,
        key: String,
        #[serde(default)]
        modifiers: u8,
        #[serde(default)]
        kind: u8,
        #[serde(default)]
        shifted_codepoint: Option<u32>,
        #[serde(default)]
        generated_text: Option<String>,
        #[serde(default)]
        physical_key_id: Option<u32>,
        #[serde(default = "tracks_release_default")]
        tracks_release: bool,
    },
    Mouse {
        #[serde(default)]
        pane_id: Option<String>,
        #[serde(default)]
        terminal_id: Option<String>,
        phase: String,
        col: u16,
        row: u16,
        #[serde(default)]
        button: Option<String>,
        #[serde(default)]
        modifiers: u8,
        #[serde(default = "one")]
        lines: u16,
    },
    Request {
        request_id: String,
        boot_id: String,
        method: String,
        params: Value,
    },
    Active {
        request_id: String,
        boot_id: String,
        active: bool,
    },
    Focus {
        focused: bool,
    },
}
fn one() -> u16 {
    1
}
fn tracks_release_default() -> bool {
    true
}
pub struct RequestInfo {
    pub id: String,
    pub boot: String,
    pub method: String,
}
pub fn geometry(
    cols: u16,
    rows: u16,
    width: u32,
    height: u32,
) -> Result<ClientSurfaceSize, String> {
    if cols == 0
        || rows == 0
        || width == 0
        || height == 0
        || usize::from(cols) * usize::from(rows) > 1024 * 1024
    {
        return Err(text(
            "Invalid surface or cell size",
            "Некорректный размер поверхности или ячейки",
        )
        .into());
    }
    Ok(ClientSurfaceSize { cols, rows })
}
fn input(
    pane: Option<String>,
    popup: Option<String>,
    event: ClientPaneInputEvent,
) -> Result<ClientMessage, String> {
    match (pane, popup) {
        (Some(id), None) if !id.is_empty() && id.len() <= 512 => {
            Ok(ClientMessage::ClientShellPaneInput {
                pane_id: id,
                events: vec![event],
            })
        }
        (None, Some(id)) if !id.is_empty() && id.len() <= 512 => {
            Ok(ClientMessage::ClientShellPopupInput {
                terminal_id: id,
                events: vec![event],
            })
        }
        _ => Err(text(
            "Input requires exactly one stable pane_id or terminal_id",
            "Ввод требует ровно один стабильный pane_id или terminal_id",
        )
        .into()),
    }
}
fn key_code(key: &str) -> Result<ClientKeyCode, String> {
    Ok(match key {
        "backspace" => ClientKeyCode::Backspace,
        "enter" => ClientKeyCode::Enter,
        "left" => ClientKeyCode::Left,
        "right" => ClientKeyCode::Right,
        "up" => ClientKeyCode::Up,
        "down" => ClientKeyCode::Down,
        "home" => ClientKeyCode::Home,
        "end" => ClientKeyCode::End,
        "pageup" => ClientKeyCode::PageUp,
        "pagedown" => ClientKeyCode::PageDown,
        "tab" => ClientKeyCode::Tab,
        "backtab" => ClientKeyCode::BackTab,
        "delete" => ClientKeyCode::Delete,
        "insert" => ClientKeyCode::Insert,
        "escape" => ClientKeyCode::Esc,
        "null" => ClientKeyCode::Null,
        _ if key.chars().count() == 1 => ClientKeyCode::Char(key.chars().next().unwrap()),
        _ => {
            let n = key
                .strip_prefix('f')
                .and_then(|s| s.parse::<u8>().ok())
                .filter(|n| *n > 0)
                .ok_or(text(
                    "Unsupported semantic key",
                    "Неподдерживаемая semantic key",
                ))?;
            ClientKeyCode::F(n)
        }
    })
}
pub fn convert(command: Command) -> Result<(ClientMessage, Option<RequestInfo>), String> {
    let message = match command {
        Command::Resize {
            cols,
            rows,
            cell_width_px,
            cell_height_px,
        } => ClientMessage::ClientShellResize {
            cell_width_px,
            cell_height_px,
            surface_size: geometry(cols, rows, cell_width_px, cell_height_px)?,
            pixel_mouse: false,
        },
        Command::Text {
            pane_id,
            terminal_id,
            text,
        } => input(pane_id, terminal_id, ClientPaneInputEvent::TextCommit(text))?,
        Command::Paste {
            pane_id,
            terminal_id,
            text,
        } => input(pane_id, terminal_id, ClientPaneInputEvent::Paste(text))?,
        Command::Key {
            pane_id,
            terminal_id,
            key,
            modifiers,
            kind,
            shifted_codepoint,
            generated_text,
            physical_key_id,
            tracks_release,
        } => {
            if modifiers & !63 != 0 {
                return Err(text("Invalid key modifiers", "Некорректные key modifiers").into());
            }
            let kind = match kind {
                0 => ClientKeyKind::Press,
                1 => ClientKeyKind::Repeat,
                2 => ClientKeyKind::Release,
                _ => return Err(text("Invalid key kind", "Некорректный key kind").into()),
            };
            input(
                pane_id,
                terminal_id,
                ClientPaneInputEvent::Key {
                    code: key_code(&key)?,
                    modifiers,
                    kind,
                    repeat_count: 1,
                    shifted_codepoint,
                    generated_text,
                    tracks_release,
                    physical_key_id,
                    windows_record: None,
                },
            )?
        }
        Command::Mouse {
            pane_id,
            terminal_id,
            phase,
            col,
            row,
            button,
            modifiers,
            lines,
        } => {
            if modifiers & !63 != 0 || lines == 0 {
                return Err(text(
                    "Invalid mouse modifiers/lines",
                    "Некорректные mouse modifiers/lines",
                )
                .into());
            }
            let button = match button.as_deref().unwrap_or("left") {
                "left" => ClientMouseButton::Left,
                "right" => ClientMouseButton::Right,
                "middle" => ClientMouseButton::Middle,
                _ => return Err(text("Invalid mouse button", "Некорректная mouse button").into()),
            };
            let kind = match phase.as_str() {
                "down" => ClientMouseKind::Down(button),
                "up" => ClientMouseKind::Up(button),
                "drag" => ClientMouseKind::Drag(button),
                "move" => ClientMouseKind::Moved,
                "upward" => ClientMouseKind::ScrollUp,
                "downward" => ClientMouseKind::ScrollDown,
                "leftward" => ClientMouseKind::ScrollLeft,
                "rightward" => ClientMouseKind::ScrollRight,
                _ => return Err(text("Invalid mouse phase", "Некорректная mouse phase").into()),
            };
            input(
                pane_id,
                terminal_id,
                ClientPaneInputEvent::Mouse {
                    kind,
                    position: ClientMousePosition::Cell { column: col, row },
                    geometry: None,
                    modifiers,
                    lines,
                },
            )?
        }
        Command::Request {
            request_id,
            boot_id,
            method,
            params,
        } => return request(request_id, boot_id, method, params),
        Command::Active {
            request_id,
            boot_id,
            active,
        } => {
            return request(
                request_id,
                boot_id,
                "client_shell.surface.set".into(),
                json!({"active":active}),
            )
        }
        Command::Focus { focused } => ClientMessage::ClientShellFocus { focused },
    };
    Ok((message, None))
}
fn request(
    id: String,
    boot: String,
    method: String,
    params: Value,
) -> Result<(ClientMessage, Option<RequestInfo>), String> {
    if id.is_empty()
        || id.len() > 128
        || boot.is_empty()
        || boot.len() > 512
        || method.is_empty()
        || method.len() > 128
        || !params.is_object()
    {
        return Err(text("Invalid request envelope", "Некорректный request envelope").into());
    }
    let request = json!({"id":id,"method":method,"params":params}).to_string();
    Ok((
        ClientMessage::ClientShellEndpointRequest {
            boot_id: boot.clone(),
            request,
        },
        Some(RequestInfo { id, boot, method }),
    ))
}
