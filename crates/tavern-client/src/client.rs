use crate::{
    command::{self, Command, RequestInfo},
    event::{self, Baseline, TavernEvent},
    localization::{localized_format, text},
    transport::*,
};
use herdr_protocol::{endpoint::*, *};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    collections::VecDeque,
    io::Read,
    net::Shutdown,
    os::unix::net::UnixStream,
    panic::{catch_unwind, AssertUnwindSafe},
    sync::{Arc, Condvar, Mutex, MutexGuard},
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

const QUEUE_LIMIT: usize = 4;
const CHUNK_LIMIT: usize = 128;
fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}
struct Pending {
    info: RequestInfo,
    deadline: Instant,
    bytes: Vec<u8>,
    chunks: usize,
}
struct State {
    closed: bool,
    snapshot: Option<(String, u64)>,
    pending: Option<Pending>,
    queue: VecDeque<TavernEvent>,
}
struct Shared {
    state: Mutex<State>,
    changed: Condvar,
    control: UnixStream,
}
impl Shared {
    fn cancelled(&self) -> bool {
        let s = lock(&self.state);
        s.closed
            || s.pending
                .as_ref()
                .is_some_and(|p| Instant::now() >= p.deadline)
    }
    fn push(&self, event: TavernEvent) -> Result<(), String> {
        let mut s = lock(&self.state);
        while s.queue.len() >= QUEUE_LIMIT && !s.closed {
            if s.pending
                .as_ref()
                .is_some_and(|p| Instant::now() >= p.deadline)
            {
                return Err(text(
                    "Endpoint response timed out; operation outcome is unknown, do not retry",
                    "Таймаут ответа endpoint; результат операции неизвестен, повтор запрещён",
                )
                .into());
            }
            s = self
                .changed
                .wait_timeout(s, Duration::from_millis(250))
                .unwrap_or_else(|e| e.into_inner())
                .0;
        }
        if s.closed {
            return Ok(());
        }
        s.queue.push_back(event);
        self.changed.notify_all();
        Ok(())
    }
    fn finish(&self, error: Option<String>) {
        let mut s = lock(&self.state);
        if s.closed {
            return;
        }
        let ambiguous = s.pending.as_ref().map(|p| p.info.id.clone());
        if let Some(message) = error {
            s.queue.push_back(TavernEvent::metadata(
                event::ERROR,
                json!({"type":"error","message":message,"request_id":ambiguous}),
            ));
        }
        s.pending = None;
        s.queue.push_back(TavernEvent::metadata(event::CLOSED,json!({"type":"closed","pending_request_id":ambiguous,"outcome_unknown":ambiguous.is_some()})));
        s.closed = true;
        let _ = self.control.shutdown(Shutdown::Both);
        self.changed.notify_all();
    }
}
pub enum NextEvent {
    Event(TavernEvent),
    Timeout,
    Closed,
}
pub struct TavernClient {
    shared: Arc<Shared>,
    writer: Mutex<UnixStream>,
    reader: Option<JoinHandle<()>>,
    welcome: EndpointServerWelcome,
}
impl TavernClient {
    pub fn open(path: &str, cols: u16, rows: u16, cw: u32, ch: u32) -> Result<Self, String> {
        let size = command::geometry(cols, rows, cw, ch)?;
        let stream = connect(path)?;
        let hello = EndpointClientHello {
            generation: ENDPOINT_PROTOCOL_GENERATION,
            cell_width_px: cw,
            cell_height_px: ch,
            surface_size: size,
            pixel_mouse: false,
            direct_graphics: false,
            endpoint_keybindings: true,
            mouse_capture: true,
            surface_active: true,
            surface_reuse: false,
            surface_delta: false,
            surface_scroll: false,
            snapshot_codecs: vec![SNAPSHOT_CODEC_V1.into()],
            surface_codecs: vec![SURFACE_CODEC_V1.into()],
            input_codecs: vec![INPUT_CODEC_V1.into()],
            blob_codecs: vec![BLOB_CODEC_V1.into()],
        };
        let end = Instant::now() + IO_DEADLINE;
        write_message(
            &mut DeadlineWriter {
                stream: &stream,
                deadline: end,
            },
            &ClientMessage::EndpointControl {
                kind: ENDPOINT_HELLO_KIND.into(),
                data: serde_json::to_string(&hello)
                    .map_err(|_| text("Failed to encode hello", "Не удалось кодировать hello"))?,
            },
        )
        .map_err(|_| {
            text(
                "Failed to write endpoint hello",
                "Ошибка записи endpoint hello",
            )
        })?;
        let mut reader = DeadlineReader {
            stream: &stream,
            frame_deadline: Some(end),
            cancelled: || false,
            bytes_read: 0,
        };
        let message: ServerMessage =
            read_message(&mut reader, MAX_GRAPHICS_FRAME_SIZE).map_err(|_| {
                text(
                    "Failed to read endpoint welcome or timed out",
                    "Ошибка или таймаут чтения endpoint welcome",
                )
            })?;
        let welcome: EndpointServerWelcome = match message {
            ServerMessage::EndpointControl { kind, data } if kind == ENDPOINT_WELCOME_KIND => {
                serde_json::from_str(&data).map_err(|_| {
                    text("Invalid endpoint welcome", "Некорректный endpoint welcome")
                })?
            }
            _ => {
                return Err(text(
                    "Expected generation-1 endpoint welcome",
                    "Ожидался generation-1 endpoint welcome",
                )
                .into())
            }
        };
        validate_welcome(&welcome)?;
        let control = stream.try_clone().map_err(|_| {
            text(
                "Failed to create close handle",
                "Не удалось создать close handle",
            )
        })?;
        let writer = stream.try_clone().map_err(|_| {
            text(
                "Failed to create writer handle",
                "Не удалось создать writer handle",
            )
        })?;
        let shared = Arc::new(Shared {
            state: Mutex::new(State {
                closed: false,
                snapshot: None,
                pending: None,
                queue: VecDeque::new(),
            }),
            changed: Condvar::new(),
            control,
        });
        shared.push(TavernEvent::metadata(
            event::NOTICE,
            json!({"type":"welcome","welcome":welcome}),
        ))?;
        let receiver = Arc::clone(&shared);
        let thread = thread::Builder::new()
            .name("tavern-endpoint-reader".into())
            .spawn(move || {
                let outcome = catch_unwind(AssertUnwindSafe(|| receive(&stream, &receiver)));
                match outcome {
                    Ok(Ok(())) => receiver.finish(None),
                    Ok(Err(error)) => receiver.finish(Some(error)),
                    Err(_) => receiver.finish(Some(
                        text(
                            "Internal endpoint reader error",
                            "Внутренняя ошибка endpoint reader",
                        )
                        .into(),
                    )),
                }
            })
            .map_err(|_| {
                text(
                    "Failed to start endpoint reader",
                    "Не удалось запустить endpoint reader",
                )
            })?;
        Ok(Self {
            shared,
            writer: Mutex::new(writer),
            reader: Some(thread),
            welcome,
        })
    }
    pub fn close(&self) {
        self.shared.finish(None);
    }
    pub fn next(&self, timeout: Duration) -> NextEvent {
        let end = Instant::now() + timeout;
        let mut s = lock(&self.shared.state);
        loop {
            if let Some(event) = s.queue.pop_front() {
                self.shared.changed.notify_all();
                return NextEvent::Event(event);
            }
            if s.closed {
                return NextEvent::Closed;
            }
            if Instant::now() >= end {
                return NextEvent::Timeout;
            }
            s = self
                .shared
                .changed
                .wait_timeout(s, end.saturating_duration_since(Instant::now()))
                .unwrap_or_else(|e| e.into_inner())
                .0;
        }
    }
    pub fn send(&self, bytes: &[u8]) -> Result<(), String> {
        if bytes.len() > MAX_JSON {
            return Err(text(
                "Command exceeds the 1 MiB limit",
                "Команда превышает лимит 1 MiB",
            )
            .into());
        }
        let command: Command = serde_json::from_slice(bytes)
            .map_err(|_| text("Invalid command JSON", "Некорректный JSON команды"))?;
        let (message, request) = command::convert(command)?;
        let writer = lock(&self.writer);
        {
            let mut s = lock(&self.shared.state);
            if s.closed {
                return Err(text("Endpoint is disconnected", "Endpoint отключён").into());
            }
            if let Some(info) = request {
                if s.pending.is_some() {
                    return Err(text(
                        "Previous endpoint request is still pending",
                        "Предыдущий endpoint request ещё не завершён",
                    )
                    .into());
                }
                if s.snapshot.as_ref().map(|(b, _)| b.as_str()) != Some(info.boot.as_str()) {
                    return Err(text(
                        "Request boot_id does not match the current snapshot",
                        "Request boot_id не соответствует текущему snapshot",
                    )
                    .into());
                }
                if !self.welcome.methods.contains(&info.method) {
                    return Err(text(
                        "Method is not advertised by the endpoint",
                        "Метод не объявлен endpoint",
                    )
                    .into());
                }
                if info.method == "client_shell.surface.set"
                    && !self
                        .welcome
                        .capabilities
                        .iter()
                        .any(|c| c == SURFACE_INTEREST_CAPABILITY)
                {
                    return Err(text(
                        "Endpoint does not support surface_interest",
                        "Endpoint не поддерживает surface_interest",
                    )
                    .into());
                }
                s.pending = Some(Pending {
                    info,
                    deadline: Instant::now() + REQUEST_DEADLINE,
                    bytes: Vec::new(),
                    chunks: 0,
                });
            }
        }
        if write_message(
            &mut DeadlineWriter {
                stream: &writer,
                deadline: Instant::now() + IO_DEADLINE,
            },
            &message,
        )
        .is_err()
        {
            let error = text(
                "Endpoint write failed; operation outcome is unknown, do not retry",
                "Ошибка записи endpoint; результат операции неизвестен, повтор запрещён",
            )
            .to_string();
            self.shared.finish(Some(error.clone()));
            return Err(error);
        }
        Ok(())
    }
}
impl Drop for TavernClient {
    fn drop(&mut self) {
        self.close();
        if let Some(reader) = self.reader.take() {
            let _ = reader.join();
        }
    }
}
fn validate_welcome(w: &EndpointServerWelcome) -> Result<(), String> {
    if let Some(error) = &w.error {
        return Err(localized_format!(
            "Endpoint rejected handshake: {} — {}",
            "Endpoint отклонил handshake: {} — {}",
            error.code.chars().take(80).collect::<String>(),
            error.message.chars().take(256).collect::<String>()
        ));
    }
    if w.generation != ENDPOINT_PROTOCOL_GENERATION
        || w.snapshot_codec != SNAPSHOT_CODEC_V1
        || w.surface_codec != SURFACE_CODEC_V1
        || w.input_codec != INPUT_CODEC_V1
        || w.blob_codec != BLOB_CODEC_V1
    {
        return Err(text(
            "Incompatible generation-1 endpoint or codec",
            "Несовместимый generation-1 endpoint или codec",
        )
        .into());
    }
    if !w
        .capabilities
        .iter()
        .any(|c| c == SURFACE_INTEREST_CAPABILITY)
        || !w.methods.iter().any(|m| m == "client_shell.surface.set")
    {
        return Err(text(
            "Endpoint does not support required surface_interest",
            "Endpoint не поддерживает обязательный surface_interest",
        )
        .into());
    }
    Ok(())
}

#[derive(Default)]
struct CommandPrefixes {
    profile: Option<String>,
    prefixes: Vec<String>,
}
impl CommandPrefixes {
    fn project(&mut self, profile: Option<&str>) -> Result<Value, String> {
        let Some(profile) = profile else {
            return Ok(json!([]));
        };
        if self.profile.as_deref() != Some(profile) {
            let document = profile.parse::<toml_edit::DocumentMut>().map_err(|error| {
                localized_format!(
                    "Invalid server_keybindings_toml: {error}",
                    "Некорректный server_keybindings_toml: {error}"
                )
            })?;
            let prefix = document
                .get("keys")
                .and_then(toml_edit::Item::as_table_like)
                .and_then(|keys| keys.get("prefix"))
                .and_then(toml_edit::Item::as_value)
                .ok_or(text(
                    "server_keybindings_toml requires keys.prefix: a string or an array of strings",
                    "server_keybindings_toml требует keys.prefix: строку или массив строк",
                ))?;
            let prefixes = if let Some(prefix) = prefix.as_str() {
                vec![prefix.to_owned()]
            } else if let Some(prefixes) = prefix.as_array() {
                prefixes
                    .iter()
                    .map(|prefix| {
                        prefix.as_str().map(str::to_owned).ok_or(text(
                            "server_keybindings_toml: keys.prefix must contain only strings",
                            "server_keybindings_toml: keys.prefix должен содержать только строки",
                        ))
                    })
                    .collect::<Result<Vec<_>, _>>()?
            } else {
                return Err(text(
                    "server_keybindings_toml: keys.prefix must be a string or an array of strings",
                    "server_keybindings_toml: keys.prefix должен быть строкой или массивом строк",
                )
                .into());
            };
            self.profile = Some(profile.to_owned());
            self.prefixes = prefixes;
        }
        Ok(json!(self.prefixes))
    }
}

fn receive(stream: &UnixStream, shared: &Shared) -> Result<(), String> {
    let mut baseline: Option<Baseline> = None;
    let mut future: VecDeque<(String, u64, TavernEvent)> = VecDeque::new();
    let mut command_prefixes = CommandPrefixes::default();
    loop {
        let mut reader = DeadlineReader {
            stream,
            frame_deadline: None,
            cancelled: || shared.cancelled(),
            bytes_read: 0,
        };
        let message: ServerMessage = match read_message(&mut reader, MAX_GRAPHICS_FRAME_SIZE) {
            Ok(message) => message,
            Err(FramingError::UnexpectedEof) if reader.bytes_read == 0 => {
                if lock(&shared.state).pending.is_some() {
                    return Err(text(
                        "Endpoint EOF: request outcome is unknown, do not retry",
                        "Endpoint EOF: результат запроса неизвестен, повтор запрещён",
                    )
                    .into());
                }
                return Ok(());
            }
            Err(_) => {
                let s = lock(&shared.state);
                if s.closed {
                    return Ok(());
                }
                if s.pending
                    .as_ref()
                    .is_some_and(|p| Instant::now() >= p.deadline)
                {
                    return Err(text(
                        "Endpoint request timed out; outcome is unknown, do not retry",
                        "Таймаут endpoint request; результат неизвестен, повтор запрещён",
                    )
                    .into());
                }
                return Err(text(
                    "Corrupt, incomplete, or timed-out endpoint frame",
                    "Повреждённый, незавершённый или просроченный endpoint frame",
                )
                .into());
            }
        };
        match message {
            ServerMessage::EndpointControl { kind,data } if kind==ENDPOINT_SNAPSHOT_KIND => {
                let mut value:Value = serde_json::from_str(&data).map_err(|_| text("Invalid shell.snapshot.v1", "Некорректный shell.snapshot.v1"))?;
                let snapshot = ClientShellSnapshot::deserialize(&value).map_err(|_| text("Invalid shell.snapshot.v1", "Некорректный shell.snapshot.v1"))?;
                value["command_prefixes"] = command_prefixes.project(snapshot.server_keybindings_toml.as_deref())?;
                if snapshot.boot_id.is_empty() { return Err(text("Empty snapshot boot_id", "Пустой snapshot boot_id").into()); }
                let mut s = lock(&shared.state);
                if let Some((boot,revision)) = &s.snapshot {
                    if boot!=&snapshot.boot_id || snapshot.revision<*revision { return Err(text("Snapshot changed boot_id or rolled back revision", "Snapshot сменил boot_id или откатил revision").into()); }
                }
                s.snapshot = Some((snapshot.boot_id.clone(),snapshot.revision));
                drop(s);
                shared.push(TavernEvent::metadata(event::SNAPSHOT,value))?;
                while let Some((boot,revision,e)) = future.pop_front() {
                    if boot!=snapshot.boot_id { return Err(text("Queued frame does not match the snapshot", "Ожидающий кадр не соответствует snapshot").into()); }
                    // Control может обогнать render: старый кадр того же boot
                    // теряет актуальность, но не делает соединение неисправным.
                    if revision<snapshot.revision { continue; }
                    if revision>snapshot.revision { future.push_front((boot,revision,e)); break; }
                    shared.push(e)?;
                }
            }
            ServerMessage::PaneSurface(surface) => {
                if let Some(base) = &baseline {
                    if surface.boot_id!=base.boot || surface.projection_revision<base.projection || surface.surface_revision<=base.revision {
                        return Err(text("Full frame rolled back identity/revision", "Полный кадр откатил identity/revision").into());
                    }
                }
                let new_base = Baseline::from_full(&surface);
                // Decoder baseline продвигается и для не показанного старого
                // кадра: следующие wire-патчи всё ещё ссылаются именно на него.
                let e = TavernEvent::full(surface)?;
                deliver_surface(shared,&mut future,&new_base,e)?;
                baseline = Some(new_base);
            }
            ServerMessage::PaneSurfacePatch(patch) => {
                let base = baseline.as_mut().ok_or(text("Patch without a full baseline", "Патч без полного baseline"))?;
                base.accept_patch(&patch)?;
                let e = TavernEvent::patch(patch,base.width,base.height);
                deliver_surface(shared,&mut future,base,e)?;
            }
            ServerMessage::ClientShellEndpointResponseChunk { boot_id,request_id,final_chunk,data } => {
                if let Some(e) = response_chunk(shared,&boot_id,&request_id,final_chunk,data)? { shared.push(e)?; }
            }
            ServerMessage::ServerShutdown { reason } => {
                shared.push(TavernEvent::metadata(event::NOTICE,json!({"type":"server_shutdown","reason":reason})))?;
                if lock(&shared.state).pending.is_some() { return Err(text("Server shutdown: request outcome is unknown", "Server shutdown: результат запроса неизвестен").into()); }
                return Ok(());
            }
            ServerMessage::ClientShellError { message } => {
                shared.push(TavernEvent::metadata(event::ERROR,json!({"type":"error","message":message.chars().take(512).collect::<String>()})))?;
            }
            ServerMessage::EndpointControl { kind,data } => {
                // Unknown named controls are explicitly optional in generation 1.
                let data = serde_json::from_str::<Value>(&data).unwrap_or(Value::Null);
                shared.push(TavernEvent::metadata(event::NOTICE,json!({"type":"endpoint_control","kind":kind,"data":data})))?;
            }
            ServerMessage::Notify { kind,message,body } => shared.push(TavernEvent::metadata(event::NOTICE,json!({"type":"notify","kind":kind,"message":message,"body":body})))?,
            ServerMessage::SemanticNotification(n) => shared.push(TavernEvent::metadata(event::NOTICE,json!({"type":"semantic_notification","notification":n})))?,
            ServerMessage::Clipboard { data } => shared.push(TavernEvent::metadata(event::NOTICE,json!({"type":"clipboard","data":data,"encoding":"base64"})))?,
            ServerMessage::WindowTitle { title } => shared.push(TavernEvent::metadata(event::NOTICE,json!({"type":"window_title","title":title})))?,
            ServerMessage::ReloadSoundConfig => shared.push(TavernEvent::metadata(event::NOTICE,json!({"type":"reload_sound_config"})))?,
            ServerMessage::MouseCapture { enabled,sgr_pixels } => shared.push(TavernEvent::metadata(event::NOTICE,json!({"type":"mouse_capture","enabled":enabled,"sgr_pixels":sgr_pixels})))?,
            ServerMessage::TerminalBell { count } => shared.push(TavernEvent::metadata(event::NOTICE,json!({"type":"terminal_bell","count":count})))?,
            ServerMessage::ClientShellKeyboardReportAll { enabled } => shared.push(TavernEvent::metadata(event::NOTICE,json!({"type":"keyboard_report_all","enabled":enabled})))?,
            ServerMessage::GraphicsTransmissionRetired { transfer_id,image_id } => shared.push(TavernEvent::metadata(event::NOTICE,json!({"type":"graphics_transmission_retired","transfer_id":transfer_id,"image_id":image_id})))?,
            ServerMessage::DirectTerminalKeyboardProtocol { flags,modify_other_keys_level } => shared.push(TavernEvent::metadata(event::NOTICE,json!({"type":"direct_terminal_keyboard_protocol","flags":flags,"modify_other_keys_level":modify_other_keys_level})))?,
            ServerMessage::GraphicsFile { .. } => return Err(text("GraphicsFile is forbidden: the client does not open server-supplied paths", "GraphicsFile запрещён: клиент не открывает server-supplied paths").into()),
            ServerMessage::Graphics { .. } => return Err(text("Direct Kitty graphics are unsupported", "Неподдерживаемая direct Kitty графика").into()),
            ServerMessage::Welcome { .. }|ServerMessage::Terminal(_)|ServerMessage::ClientShellSnapshot(_) => return Err(text("Received a private-protocol message instead of a stable endpoint message", "Получен private-protocol message вместо stable endpoint").into()),
        }
    }
}
fn deliver_surface(
    shared: &Shared,
    future: &mut VecDeque<(String, u64, TavernEvent)>,
    base: &Baseline,
    event: TavernEvent,
) -> Result<(), String> {
    let identity = lock(&shared.state).snapshot.clone();
    match identity {
        Some((boot, _)) if boot != base.boot => Err(text(
            "Surface does not match snapshot boot/projection",
            "Surface не соответствует snapshot boot/projection",
        )
        .into()),
        Some((_, revision)) if revision > base.projection => Ok(()),
        Some((_, revision)) if revision == base.projection => {
            if !future.is_empty() {
                return Err(text(
                    "Queued surface events are out of order",
                    "Нарушен порядок ожидающих surface events",
                )
                .into());
            }
            shared.push(event)
        }
        _ => {
            if future.len() >= QUEUE_LIMIT {
                return Err(text(
                    "Frame limit exceeded without a matching snapshot",
                    "Лимит кадров без matching snapshot превышен",
                )
                .into());
            }
            future.push_back((base.boot.clone(), base.projection, event));
            Ok(())
        }
    }
}
fn response_chunk(
    shared: &Shared,
    boot: &str,
    id: &str,
    final_chunk: bool,
    data: Vec<u8>,
) -> Result<Option<TavernEvent>, String> {
    let mut s = lock(&shared.state);
    let p = s.pending.as_mut().ok_or(text(
        "Response chunk without a pending request",
        "Response chunk без pending request",
    ))?;
    if p.info.boot != boot || p.info.id != id {
        return Err(text(
            "Response chunk identity does not match the request",
            "Response chunk identity не соответствует request",
        )
        .into());
    }
    if Instant::now() >= p.deadline {
        return Err(text(
            "Response arrived after the request deadline; outcome is unknown",
            "Response пришёл после request deadline; результат неизвестен",
        )
        .into());
    }
    p.chunks += 1;
    if p.chunks > CHUNK_LIMIT || data.len() > MAX_RESPONSE.saturating_sub(p.bytes.len()) {
        return Err(text(
            "Endpoint response exceeded the chunks/bytes limit",
            "Endpoint response превысил лимит chunks/bytes",
        )
        .into());
    }
    p.bytes.extend_from_slice(&data);
    if !final_chunk {
        return Ok(None);
    }
    let response: Value = serde_json::from_slice(&p.bytes).map_err(|_| {
        text(
            "Invalid endpoint response JSON",
            "Некорректный JSON endpoint response",
        )
    })?;
    if response.get("id").and_then(Value::as_str) != Some(id)
        || !response.is_object()
        || (response.get("result").is_some() == response.get("error").is_some())
    {
        return Err(text(
            "Invalid response envelope or request id",
            "Некорректный response envelope или request id",
        )
        .into());
    }
    let e = TavernEvent::metadata(
        event::RESPONSE,
        json!({"boot_id":boot,"request_id":id,"response":response}),
    );
    s.pending = None;
    Ok(Some(e))
}

pub fn public_json(path: &str, bytes: &[u8]) -> Result<String, String> {
    if bytes.len() > MAX_JSON {
        return Err(text(
            "Public request exceeds the 1 MiB limit",
            "Public request превышает лимит 1 MiB",
        )
        .into());
    }
    let request: Value = serde_json::from_slice(bytes).map_err(|_| {
        text(
            "Invalid public request JSON",
            "Некорректный JSON public request",
        )
    })?;
    let id = request
        .get("id")
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty() && id.len() <= 128)
        .ok_or(text(
            "Public request requires an id",
            "Public request требует id",
        ))?;
    if request.get("method").and_then(Value::as_str).is_none()
        || !request.get("params").is_some_and(Value::is_object)
    {
        return Err(text(
            "Invalid public request envelope",
            "Некорректный public request envelope",
        )
        .into());
    }
    let stream = connect(path)?;
    let mut writer = DeadlineWriter {
        stream: &stream,
        deadline: Instant::now() + IO_DEADLINE,
    };
    use std::io::Write;
    writer
        .write_all(request.to_string().as_bytes())
        .and_then(|_| writer.write_all(b"\n"))
        .map_err(|_| {
            text(
                "Public request write failed; outcome is unknown, do not retry",
                "Ошибка записи public request; результат неизвестен, повтор запрещён",
            )
        })?;
    let mut reader = DeadlineReader {
        stream: &stream,
        frame_deadline: Some(Instant::now() + REQUEST_DEADLINE),
        cancelled: || false,
        bytes_read: 0,
    };
    let mut response = Vec::new();
    let mut buffer = [0u8; 4096];
    loop {
        let n = reader.read(&mut buffer).map_err(|_| {
            text(
                "Public response timed out or failed; outcome is unknown, do not retry",
                "Таймаут/ошибка public response; результат неизвестен, повтор запрещён",
            )
        })?;
        if n == 0 {
            return Err(text(
                "Public response EOF; outcome is unknown",
                "EOF public response; результат неизвестен",
            )
            .into());
        }
        if let Some(end) = buffer[..n].iter().position(|b| *b == b'\n') {
            if response.len() + end > MAX_RESPONSE {
                return Err(text(
                    "Public response exceeds the 8 MiB limit",
                    "Public response превышает лимит 8 MiB",
                )
                .into());
            }
            response.extend_from_slice(&buffer[..end]);
            break;
        }
        if response.len() + n > MAX_RESPONSE {
            return Err(text(
                "Public response exceeds the 8 MiB limit",
                "Public response превышает лимит 8 MiB",
            )
            .into());
        }
        response.extend_from_slice(&buffer[..n]);
    }
    let value: Value = serde_json::from_slice(&response).map_err(|_| {
        text(
            "Invalid public response JSON",
            "Некорректный JSON public response",
        )
    })?;
    if value.get("id").and_then(Value::as_str) != Some(id)
        || (value.get("result").is_some() == value.get("error").is_some())
    {
        return Err(text(
            "Public response identity/envelope mismatch",
            "Несовпадение identity/envelope public response",
        )
        .into());
    }
    String::from_utf8(response).map_err(|_| {
        text(
            "Invalid public response UTF-8",
            "Некорректный UTF-8 public response",
        )
        .into()
    })
}

#[cfg(test)]
mod tests;

#[cfg(test)]
mod socket_tests;
