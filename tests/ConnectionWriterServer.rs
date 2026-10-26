// Standalone test fixture; built by ConnectionWriterTests with release --extern dependencies.
// argv: socket path. stdin/stdout: newline JSON controls/events (never endpoint traffic).
// Initially paused after hello/welcome/snapshot. Controls: read [count], pause,
// slow {bytes,delay_ms}, partial {bytes}, close, stop. Every control is acknowledged.
use herdr_protocol::endpoint::*;
use herdr_protocol::*;
use serde_json::{json, Value};
use std::io::{self, BufRead, Read, Write};
use std::net::Shutdown;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::{Duration, Instant};

const LIFETIME: Duration = Duration::from_secs(30);

fn emit(value: Value) {
    let stdout = io::stdout();
    let mut output = stdout.lock();
    let _ = writeln!(output, "{value}");
    let _ = output.flush();
}

#[derive(Default)]
struct Control {
    running: bool,
    closed: bool,
    frames: Option<u64>,
    partial: Option<(usize, usize)>,
    chunk: usize,
    delay: Duration,
}
type Gate = Arc<(Mutex<Control>, Condvar)>;

fn control_thread(stream: UnixStream, gate: Gate) {
    thread::spawn(move || {
        for line in io::stdin().lock().lines() {
            let value = match line.ok().and_then(|line| serde_json::from_str::<Value>(&line).ok()) {
                Some(value) => value,
                None => {
                    emit(json!({"event":"error","message":"invalid control JSON"}));
                    break;
                }
            };
            let op = value["op"].as_str().unwrap_or("");
            let (lock, wake) = &*gate;
            let mut state = lock.lock().unwrap();
            let valid = match op {
                "pause" => { state.running = false; true }
                "read" => {
                    let count = value.get("count").map(Value::as_u64);
                    if matches!(count, Some(None) | Some(Some(0))) {
                        false
                    } else {
                        state.frames = count.flatten();
                        state.running = true;
                        true
                    }
                }
                "slow" => {
                    match (value["bytes"].as_u64(), value["delay_ms"].as_u64()) {
                        (Some(bytes @ 1..=65536), Some(delay @ 0..=1000)) => {
                            state.chunk = bytes as usize;
                            state.delay = Duration::from_millis(delay);
                            state.frames = None;
                            state.running = true;
                            true
                        }
                        _ => false,
                    }
                }
                "partial" => match value["bytes"].as_u64() {
                    Some(bytes) if bytes > 0 && bytes <= MAX_FRAME_SIZE as u64 => {
                        state.partial = Some((bytes as usize, bytes as usize));
                        state.running = true;
                        state.frames = None;
                        true
                    }
                    _ => false,
                },
                "close" | "stop" => { state.closed = true; true }
                _ => false,
            };
            if !valid {
                emit(json!({"event":"error","message":"invalid control operation or bounds"}));
                state.closed = true;
            } else {
                emit(json!({"event":"control","op":op}));
            }
            wake.notify_all();
            if state.closed { break; }
        }
        let (lock, wake) = &*gate;
        lock.lock().unwrap().closed = true;
        wake.notify_all();
        let _ = stream.shutdown(Shutdown::Both);
    });
}

// The public decoder retains its framing state while this reader gates raw reads.
// In particular partial stops *inside* a frame without decoding/replaying it.
struct GatedReader {
    stream: UnixStream,
    gate: Gate,
    deadline: Instant,
}
impl Read for GatedReader {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        if buffer.is_empty() { return Ok(0); }
        loop {
            let (lock, wake) = &*self.gate;
            let mut state = lock.lock().unwrap();
            while !state.running && !state.closed {
                let remaining = self.deadline.saturating_duration_since(Instant::now());
                if remaining.is_zero() {
                    return Err(io::Error::new(io::ErrorKind::TimedOut, "fixture lifetime exceeded"));
                }
                state = wake.wait_timeout(state, remaining.min(Duration::from_millis(100))).unwrap().0;
            }
            if state.closed { return Ok(0); }
            if Instant::now() >= self.deadline {
                return Err(io::Error::new(io::ErrorKind::TimedOut, "fixture lifetime exceeded"));
            }
            let count = buffer.len().min(state.chunk).min(state.partial.map(|p| p.0).unwrap_or(usize::MAX));
            let delay = state.delay;
            drop(state);
            match self.stream.read(&mut buffer[..count]) {
                Ok(bytes) => {
                    let mut state = lock.lock().unwrap();
                    if let Some((remaining, total)) = state.partial {
                        let remaining = remaining.saturating_sub(bytes);
                        if remaining == 0 {
                            state.partial = None;
                            state.running = false;
                            emit(json!({"event":"partial","bytes":total}));
                        } else {
                            state.partial = Some((remaining, total));
                        }
                    }
                    drop(state);
                    if !delay.is_zero() && bytes > 0 { thread::sleep(delay); }
                    return Ok(bytes);
                }
                Err(error) if matches!(error.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut | io::ErrorKind::Interrupted) => continue,
                Err(error) => return Err(error),
            }
        }
    }
}

fn input_records(events: Vec<ClientPaneInputEvent>, target: &str, popup: bool) -> Vec<Value> {
    events.into_iter().map(|event| {
        let mut record = match event {
            ClientPaneInputEvent::Key { code, modifiers, kind, generated_text, .. } => {
                let key = match code {
                    ClientKeyCode::Char(c) => c.to_string(),
                    ClientKeyCode::F(n) => format!("f{n}"),
                    ClientKeyCode::Esc => "escape".into(),
                    other => format!("{other:?}").to_lowercase(),
                };
                let kind = match kind { ClientKeyKind::Press => "down", ClientKeyKind::Repeat => "repeat", ClientKeyKind::Release => "up" };
                json!({"event":"command","kind":"key","key":key,"key_kind":kind,"modifiers":modifiers,"generated_text":generated_text})
            }
            ClientPaneInputEvent::Paste(text) => json!({"event":"command","kind":"paste","text":text}),
            ClientPaneInputEvent::TextCommit(text) => json!({"event":"command","kind":"text","text":text}),
            ClientPaneInputEvent::Mouse { kind, position, modifiers, lines, .. } => {
                let (phase, button) = match kind {
                    ClientMouseKind::Down(button) => ("down", Some(button)),
                    ClientMouseKind::Up(button) => ("up", Some(button)),
                    ClientMouseKind::Drag(button) => ("drag", Some(button)),
                    ClientMouseKind::Moved => ("move", None),
                    ClientMouseKind::ScrollUp => ("scrollup", None),
                    ClientMouseKind::ScrollDown => ("scrolldown", None),
                    ClientMouseKind::ScrollLeft => ("scrollleft", None),
                    ClientMouseKind::ScrollRight => ("scrollright", None),
                };
                let (col, row) = match position {
                    ClientMousePosition::Cell { column, row } | ClientMousePosition::Pixels { column, row, .. } => (column, row),
                };
                let button = button.map(|b| format!("{b:?}").to_lowercase());
                json!({"event":"command","kind":"mouse","phase":phase,"col":col,"row":row,"button":button,"modifiers":modifiers,"lines":lines})
            }
        };
        record[if popup { "terminal_id" } else { "pane_id" }] = json!(target);
        record
    }).collect()
}

fn records(message: ClientMessage) -> Result<Vec<Value>, &'static str> {
    Ok(match message {
        ClientMessage::ClientShellResize { cell_width_px, cell_height_px, surface_size, .. } => vec![json!({
            "event":"command","kind":"resize","cols":surface_size.cols,"rows":surface_size.rows,
            "cell_width_px":cell_width_px,"cell_height_px":cell_height_px
        })],
        ClientMessage::ClientShellPaneInput { pane_id, events } => input_records(events, &pane_id, false),
        ClientMessage::ClientShellPopupInput { terminal_id, events } => input_records(events, &terminal_id, true),
        ClientMessage::ClientShellEndpointRequest { boot_id, request } => {
            let request: Value = serde_json::from_str(&request).map_err(|_| "invalid endpoint request JSON")?;
            vec![json!({"event":"command","kind":"request","boot_id":boot_id,"request_id":request["id"],"method":request["method"],"params":request["params"]})]
        }
        ClientMessage::ClientShellFocus { focused } => vec![json!({"event":"command","kind":"focus","focused":focused})],
        _ => return Err("unexpected client wire message"),
    })
}

fn snapshot() -> Value {
    json!({"boot_id":"boot","revision":1,"config_diagnostic":null,"product_announcement":null,"update_available":null,
        "update_install_command":"herdr update","server_keybindings_toml":null,"latest_release_notes_available":false,
        "integration_updates_available":false,"worktree_directory":"","release_notes":null,"focused_workspace_id":null,
        "focused_tab_id":null,"focused_pane_id":null,"tab_bar_right":[],"tab_bar_right_separator":"","agent_view_label":null,
        "agent_order":[],"workspaces":[],"tabs":[],"panes":[],"agents":[],"commands":[],"future_optional":{"enabled":true}})
}

struct SocketPath(PathBuf);
impl Drop for SocketPath {
    fn drop(&mut self) { let _ = std::fs::remove_file(&self.0); }
}

fn run() -> Result<(), String> {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    if args.len() != 1 || args[0].as_bytes().is_empty() || args[0].as_bytes().len() > 103 {
        return Err("expected one socket path of 1...103 bytes".into());
    }
    let listener = UnixListener::bind(&args[0]).map_err(|_| "cannot bind fixture socket")?;
    let _cleanup = SocketPath(PathBuf::from(&args[0]));
    listener.set_nonblocking(true).map_err(|_| "cannot configure fixture listener")?;
    emit(json!({"event":"ready"}));
    let deadline = Instant::now() + LIFETIME;
    let mut stream = loop {
        match listener.accept() {
            Ok((stream, _)) => break stream,
            Err(error) if error.kind() == io::ErrorKind::WouldBlock && Instant::now() < deadline => thread::sleep(Duration::from_millis(5)),
            _ => return Err("fixture accept failed or timed out".into()),
        }
    };
    stream.set_read_timeout(Some(Duration::from_secs(5))).map_err(|_| "cannot set handshake deadline")?;
    stream.set_write_timeout(Some(Duration::from_secs(5))).map_err(|_| "cannot set write deadline")?;
    match read_message::<_, ClientMessage>(&mut stream, MAX_FRAME_SIZE).map_err(|e| e.to_string())? {
        ClientMessage::EndpointControl { kind, data } if kind == ENDPOINT_HELLO_KIND => {
            let hello: EndpointClientHello = serde_json::from_str(&data).map_err(|_| "invalid endpoint hello")?;
            if !hello.supports_required_codecs() { return Err("unsupported hello codecs".into()); }
        }
        _ => return Err("expected endpoint hello".into()),
    }
    let welcome = json!({"generation":1,"server_version":"writer-test","snapshot_codec":SNAPSHOT_CODEC_V1,
        "surface_codec":SURFACE_CODEC_V1,"input_codec":INPUT_CODEC_V1,"blob_codec":BLOB_CODEC_V1,
        "methods":["tab.focus","writer.snapshot","client_shell.surface.set"],"capabilities":[SURFACE_INTEREST_CAPABILITY],"future_optional":true});
    for (kind, data) in [(ENDPOINT_WELCOME_KIND, welcome), (ENDPOINT_SNAPSHOT_KIND, snapshot())] {
        write_message(&mut stream, &ServerMessage::EndpointControl { kind: kind.into(), data: data.to_string() }).map_err(|e| e.to_string())?;
    }
    stream.set_read_timeout(Some(Duration::from_millis(100))).map_err(|_| "cannot set reader deadline")?;
    let gate = Arc::new((Mutex::new(Control { chunk: 65536, ..Control::default() }), Condvar::new()));
    control_thread(stream.try_clone().map_err(|_| "cannot clone fixture socket")?, gate.clone());
    emit(json!({"event":"connected"}));
    let mut reader = GatedReader { stream, gate: gate.clone(), deadline };
    loop {
        match read_message::<_, ClientMessage>(&mut reader, MAX_FRAME_SIZE) {
            Ok(message) => {
                for record in records(message)? { emit(record); }
                let mut state = gate.0.lock().unwrap();
                if let Some(count) = &mut state.frames {
                    *count -= 1;
                    if *count == 0 {
                        state.running = false;
                        state.frames = None;
                        emit(json!({"event":"paused"}));
                    }
                }
            }
            Err(error) => {
                let closed = gate.0.lock().unwrap().closed;
                if closed { emit(json!({"event":"closed"})); return Ok(()); }
                if matches!(&error, FramingError::UnexpectedEof) || matches!(&error, FramingError::Io(e) if matches!(e.kind(), io::ErrorKind::ConnectionReset | io::ErrorKind::BrokenPipe)) {
                    emit(json!({"event":"eof"}));
                    return Ok(());
                }
                return Err(error.to_string());
            }
        }
    }
}

fn main() {
    if let Err(message) = run() {
        emit(json!({"event":"error","message":message}));
        std::process::exit(1);
    }
}
