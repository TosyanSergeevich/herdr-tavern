//! Постоянный Unix-клиент stable generation-1 herdr endpoint.
//! ABI и lifetime описаны в include/TavernClient.h. GUI указатели не сохраняются.
mod client;
mod command;
mod config;
mod event;
mod localization;
mod title_feed;
mod transport;

pub use client::TavernClient;
pub use event::TavernEvent;
use localization::text;
use std::{
    ffi::{c_char, CStr, CString},
    panic::{catch_unwind, AssertUnwindSafe},
    ptr,
    time::Duration,
};
pub use title_feed::TavernTitleFeed;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct TavernBytes {
    pub ptr: *const u8,
    pub len: usize,
}
impl TavernBytes {
    fn borrowed(bytes: &[u8]) -> Self {
        Self {
            ptr: bytes.as_ptr(),
            len: bytes.len(),
        }
    }
    fn empty() -> Self {
        Self {
            ptr: ptr::null(),
            len: 0,
        }
    }
}
#[repr(C)]
pub struct TavernSegment {
    pub x: u16,
    pub y: u16,
    pub count: usize,
    pub target: u8,
}
#[repr(C)]
pub struct TavernCell {
    pub symbol: TavernBytes,
    pub fg: u32,
    pub bg: u32,
    pub modifier: u16,
    pub skip: u8,
    pub hyperlink_present: u8,
    pub hyperlink: u32,
}
#[repr(C)]
pub struct TavernAsset {
    pub id: TavernBytes,
    pub data: TavernBytes,
    pub width: u32,
    pub height: u32,
    pub format: u32,
}

unsafe fn path<'a>(p: *const c_char) -> Result<&'a str, String> {
    if p.is_null() {
        return Err(text("Missing socket path", "Отсутствует путь сокета").into());
    }
    CStr::from_ptr(p)
        .to_str()
        .map_err(|_| text("Socket path is not UTF-8", "Путь сокета не UTF-8").into())
}
unsafe fn bytes<'a>(p: *const u8, len: usize) -> Result<&'a [u8], String> {
    if p.is_null() || len == 0 || len > transport::MAX_JSON {
        return Err(text(
            "Missing JSON or the 1 MiB limit was exceeded",
            "Отсутствует JSON или превышен лимит 1 MiB",
        )
        .into());
    }
    Ok(std::slice::from_raw_parts(p, len))
}
unsafe fn set_error(out: *mut *mut c_char, message: String) {
    if !out.is_null() {
        let short: String = message.chars().filter(|c| *c != '\0').take(512).collect();
        *out = CString::new(short).unwrap_or_default().into_raw();
    }
}
unsafe fn boundary<T>(
    error: *mut *mut c_char,
    fallback: T,
    f: impl FnOnce() -> Result<T, String>,
) -> T {
    if !error.is_null() {
        *error = ptr::null_mut();
    }
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(Ok(value)) => value,
        Ok(Err(message)) => {
            set_error(error, message);
            fallback
        }
        Err(_) => {
            set_error(
                error,
                text(
                    "Internal Rust client error",
                    "Внутренняя ошибка Rust client",
                )
                .into(),
            );
            fallback
        }
    }
}
/// Selects client diagnostic language: 0 = English (default), 1 = Russian.
/// Does not reconnect clients or change any herdr session state.
#[no_mangle]
pub extern "C" fn tavern_set_language(language: u32) {
    localization::set_language(language);
}

#[no_mangle]
pub unsafe extern "C" fn tavern_title_feed_open(
    socket_path: *const c_char,
    error: *mut *mut c_char,
) -> *mut TavernTitleFeed {
    boundary(error, ptr::null_mut(), || {
        Ok(Box::into_raw(Box::new(TavernTitleFeed::open(path(
            socket_path,
        )?)?)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn tavern_title_feed_next(
    feed: *mut TavernTitleFeed,
    timeout_ms: u32,
    out_json: *mut *mut c_char,
    error: *mut *mut c_char,
) -> i32 {
    if !out_json.is_null() {
        *out_json = ptr::null_mut();
    }
    boundary(error, -1, || {
        let feed = feed
            .as_ref()
            .ok_or(text("Missing title feed", "Отсутствует поток заголовков"))?;
        if out_json.is_null() {
            return Err(text(
                "Missing title event output",
                "Отсутствует output события заголовка",
            )
            .into());
        }
        match feed.next(Duration::from_millis(u64::from(timeout_ms.min(60000))))? {
            title_feed::NextTitle::Event(json) => {
                *out_json = json.into_raw();
                Ok(1)
            }
            title_feed::NextTitle::Timeout => Ok(0),
            title_feed::NextTitle::Closed => Ok(2),
        }
    })
}

#[no_mangle]
pub unsafe extern "C" fn tavern_title_feed_close(feed: *mut TavernTitleFeed) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if let Some(feed) = feed.as_ref() {
            feed.close();
        }
    }));
}

#[no_mangle]
pub unsafe extern "C" fn tavern_title_feed_free(feed: *mut TavernTitleFeed) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !feed.is_null() {
            drop(Box::from_raw(feed));
        }
    }));
}

#[no_mangle]
pub unsafe extern "C" fn tavern_client_open(
    socket_path: *const c_char,
    cols: u16,
    rows: u16,
    cw: u32,
    ch: u32,
    error: *mut *mut c_char,
) -> *mut TavernClient {
    boundary(error, ptr::null_mut(), || {
        Ok(Box::into_raw(Box::new(TavernClient::open(
            path(socket_path)?,
            cols,
            rows,
            cw,
            ch,
        )?)))
    })
}
#[no_mangle]
pub unsafe extern "C" fn tavern_client_close(client: *mut TavernClient) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if let Some(client) = client.as_ref() {
            client.close();
        }
    }));
}
#[no_mangle]
pub unsafe extern "C" fn tavern_client_free(client: *mut TavernClient) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !client.is_null() {
            drop(Box::from_raw(client));
        }
    }));
}
#[no_mangle]
pub unsafe extern "C" fn tavern_client_next_event(
    client: *mut TavernClient,
    timeout_ms: u32,
    out: *mut *mut TavernEvent,
    error: *mut *mut c_char,
) -> i32 {
    if !out.is_null() {
        *out = ptr::null_mut();
    }
    boundary(error, -1, || {
        let client = client
            .as_ref()
            .ok_or(text("Missing client", "Отсутствует client"))?;
        if out.is_null() {
            return Err(text("Missing event output", "Отсутствует event output").into());
        }
        match client.next(Duration::from_millis(u64::from(timeout_ms.min(60000)))) {
            client::NextEvent::Event(event) => {
                *out = Box::into_raw(Box::new(event));
                Ok(1)
            }
            client::NextEvent::Timeout => Ok(0),
            client::NextEvent::Closed => Ok(2),
        }
    })
}
#[no_mangle]
pub unsafe extern "C" fn tavern_client_send_json(
    client: *mut TavernClient,
    json: *const u8,
    len: usize,
    error: *mut *mut c_char,
) -> i32 {
    boundary(error, -1, || {
        client
            .as_ref()
            .ok_or(text("Missing client", "Отсутствует client"))?
            .send(bytes(json, len)?)?;
        Ok(0)
    })
}
#[no_mangle]
pub unsafe extern "C" fn tavern_event_kind(event: *const TavernEvent) -> u32 {
    event.as_ref().map_or(0, |e| e.kind)
}
#[no_mangle]
pub unsafe extern "C" fn tavern_event_json(event: *const TavernEvent) -> TavernBytes {
    event
        .as_ref()
        .map_or(TavernBytes::empty(), |e| TavernBytes::borrowed(&e.json))
}
#[no_mangle]
pub unsafe extern "C" fn tavern_event_segment_count(event: *const TavernEvent) -> usize {
    event.as_ref().map_or(0, |e| e.segments.len())
}
#[no_mangle]
pub unsafe extern "C" fn tavern_event_segment(
    event: *const TavernEvent,
    index: usize,
    out: *mut TavernSegment,
) -> i32 {
    let Some(segment) = event.as_ref().and_then(|e| e.segments.get(index)) else {
        return -1;
    };
    if out.is_null() {
        return -1;
    }
    ptr::write(
        out,
        TavernSegment {
            x: segment.x,
            y: segment.y,
            count: segment.cells.len(),
            target: segment.target,
        },
    );
    0
}
#[no_mangle]
pub unsafe extern "C" fn tavern_event_cell(
    event: *const TavernEvent,
    segment: usize,
    index: usize,
    out: *mut TavernCell,
) -> i32 {
    let Some(cell) = event
        .as_ref()
        .and_then(|e| e.segments.get(segment))
        .and_then(|s| s.cells.get(index))
    else {
        return -1;
    };
    if out.is_null() {
        return -1;
    }
    ptr::write(
        out,
        TavernCell {
            symbol: TavernBytes::borrowed(cell.symbol.as_bytes()),
            fg: cell.fg,
            bg: cell.bg,
            modifier: cell.modifier,
            skip: cell.skip as u8,
            hyperlink_present: cell.hyperlink.is_some() as u8,
            hyperlink: cell.hyperlink.unwrap_or(0),
        },
    );
    0
}
#[no_mangle]
pub unsafe extern "C" fn tavern_event_asset_count(event: *const TavernEvent) -> usize {
    event.as_ref().map_or(0, |e| e.assets.len())
}
#[no_mangle]
pub unsafe extern "C" fn tavern_event_asset(
    event: *const TavernEvent,
    index: usize,
    out: *mut TavernAsset,
) -> i32 {
    let Some(a) = event.as_ref().and_then(|e| e.assets.get(index)) else {
        return -1;
    };
    if out.is_null() {
        return -1;
    }
    use herdr_protocol::SurfaceGraphicsFormat;
    ptr::write(
        out,
        TavernAsset {
            id: TavernBytes::borrowed(a.id.as_bytes()),
            data: TavernBytes::borrowed(&a.asset.data),
            width: a.asset.key.image_width,
            height: a.asset.key.image_height,
            format: match a.asset.key.format {
                SurfaceGraphicsFormat::Rgb => 0,
                SurfaceGraphicsFormat::Rgba => 1,
                SurfaceGraphicsFormat::Png => 2,
            },
        },
    );
    0
}
#[no_mangle]
pub unsafe extern "C" fn tavern_event_free(event: *mut TavernEvent) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !event.is_null() {
            drop(Box::from_raw(event));
        }
    }));
}
#[no_mangle]
pub unsafe extern "C" fn tavern_public_json(
    socket_path: *const c_char,
    json: *const u8,
    len: usize,
    response: *mut *mut c_char,
    error: *mut *mut c_char,
) -> i32 {
    if !response.is_null() {
        *response = ptr::null_mut();
    }
    boundary(error, -1, || {
        if response.is_null() {
            return Err(text(
                "Missing public response output",
                "Отсутствует public response output",
            )
            .into());
        }
        let result = client::public_json(path(socket_path)?, bytes(json, len)?)?;
        *response = CString::new(result)
            .map_err(|_| text("NUL in public response", "NUL в public response"))?
            .into_raw();
        Ok(0)
    })
}
#[no_mangle]
pub unsafe extern "C" fn tavern_config_json(
    json: *const u8,
    len: usize,
    response: *mut *mut c_char,
    error: *mut *mut c_char,
) -> i32 {
    if !response.is_null() {
        *response = ptr::null_mut();
    }
    boundary(error, -1, || {
        if response.is_null() {
            return Err(text(
                "Missing configuration result output",
                "Отсутствует результат обработки конфигурации",
            )
            .into());
        }
        let result = config::config_json(bytes(json, len)?)?;
        *response = CString::new(result)
            .map_err(|_| {
                text(
                    "NUL in configuration result",
                    "NUL в результате обработки конфигурации",
                )
            })?
            .into_raw();
        Ok(0)
    })
}
#[no_mangle]
pub unsafe extern "C" fn tavern_string_free(string: *mut c_char) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !string.is_null() {
            drop(CString::from_raw(string));
        }
    }));
}
