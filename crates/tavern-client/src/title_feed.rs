use crate::{
    localization::text,
    transport::{connect, DeadlineWriter, MAX_JSON, REQUEST_DEADLINE},
};
use serde_json::Value;
use std::{
    ffi::CString,
    io::{self, Write},
    net::Shutdown,
    os::{fd::AsRawFd, unix::net::UnixStream},
    sync::{
        atomic::{AtomicBool, Ordering},
        Mutex,
    },
    time::{Duration, Instant},
};

const REQUEST_ID: &str = "tavern-title-feed";
const SUBSCRIBE: &[u8] = b"{\"id\":\"tavern-title-feed\",\"method\":\"events.subscribe\",\"params\":{\"subscriptions\":[{\"type\":\"pane.updated\"},{\"type\":\"pane.closed\"}]}}\n";

/// One reader; close may run concurrently. Free only after the reader returns.
pub struct TavernTitleFeed {
    stream: UnixStream,
    closed: AtomicBool,
    reader: Mutex<LineReader>,
}

struct LineReader {
    chunk: [u8; 4096],
    start: usize,
    end: usize,
    line: Vec<u8>,
}

impl Default for LineReader {
    fn default() -> Self {
        Self {
            chunk: [0; 4096],
            start: 0,
            end: 0,
            line: Vec::new(),
        }
    }
}

enum Line {
    Ready(Vec<u8>),
    Timeout,
    Closed,
}

pub enum NextTitle {
    Event(CString),
    Timeout,
    Closed,
}

impl LineReader {
    fn next(
        &mut self,
        stream: &UnixStream,
        closed: &AtomicBool,
        deadline: Instant,
    ) -> Result<Line, String> {
        let mut attempted_read = false;
        loop {
            if closed.load(Ordering::Acquire) {
                return Ok(Line::Closed);
            }
            if self.start < self.end {
                let pending = &self.chunk[self.start..self.end];
                let newline = pending.iter().position(|byte| *byte == b'\n');
                let count = newline.unwrap_or(pending.len());
                if self.line.len() + count > MAX_JSON {
                    return Err(text(
                        "Title event exceeds the 1 MiB limit",
                        "Событие заголовка превышает лимит 1 MiB",
                    )
                    .into());
                }
                self.line.extend_from_slice(&pending[..count]);
                self.start += count;
                if newline.is_some() {
                    self.start += 1;
                    return Ok(Line::Ready(std::mem::take(&mut self.line)));
                }
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if attempted_read && remaining.is_zero() {
                return Ok(Line::Timeout);
            }
            let millis = remaining
                .as_millis()
                .saturating_add(u128::from(!remaining.is_zero()))
                .min(i32::MAX as u128) as i32;
            let mut fd = libc::pollfd {
                fd: stream.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            };
            let ready = unsafe { libc::poll(&mut fd, 1, millis) };
            if ready == 0 {
                return Ok(Line::Timeout);
            }
            if ready < 0 {
                if io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
                    attempted_read = true;
                    continue;
                }
                return Err(text(
                    "Failed to wait for title events",
                    "Ошибка ожидания событий заголовков",
                )
                .into());
            }
            attempted_read = true;
            let count = unsafe {
                libc::recv(
                    stream.as_raw_fd(),
                    self.chunk.as_mut_ptr().cast(),
                    self.chunk.len(),
                    libc::MSG_DONTWAIT,
                )
            };
            if count == 0 {
                if !self.line.is_empty() && !closed.load(Ordering::Acquire) {
                    return Err(text(
                        "Incomplete title event at EOF",
                        "Незавершённое событие заголовка при EOF",
                    )
                    .into());
                }
                return Ok(Line::Closed);
            }
            if count < 0 {
                if closed.load(Ordering::Acquire) {
                    return Ok(Line::Closed);
                }
                if matches!(
                    io::Error::last_os_error().kind(),
                    io::ErrorKind::Interrupted | io::ErrorKind::WouldBlock
                ) {
                    continue;
                }
                return Err(
                    text("Title event read failed", "Ошибка чтения события заголовка").into(),
                );
            }
            self.start = 0;
            self.end = count as usize;
        }
    }
}

impl TavernTitleFeed {
    pub fn open(path: &str) -> Result<Self, String> {
        Self::subscribe(connect(path)?, REQUEST_DEADLINE)
    }

    fn subscribe(stream: UnixStream, timeout: Duration) -> Result<Self, String> {
        let deadline = Instant::now() + timeout;
        DeadlineWriter {
            stream: &stream,
            deadline,
        }
        .write_all(SUBSCRIBE)
        .map_err(|_| {
            text(
                "Title subscription write failed",
                "Ошибка записи подписки заголовков",
            )
        })?;
        let feed = Self {
            stream,
            closed: AtomicBool::new(false),
            reader: Mutex::new(LineReader::default()),
        };
        {
            let mut reader = feed
                .reader
                .lock()
                .map_err(|_| text("Title reader failed", "Ошибка reader заголовков"))?;
            let line = match reader.next(&feed.stream, &feed.closed, deadline)? {
                Line::Ready(line) => line,
                Line::Timeout => {
                    return Err(text(
                        "Title subscription timed out",
                        "Таймаут подписки заголовков",
                    )
                    .into())
                }
                Line::Closed => {
                    return Err(text(
                        "Title subscription closed before acknowledgment",
                        "Подписка заголовков закрыта до подтверждения",
                    )
                    .into())
                }
            };
            let value: Value = serde_json::from_slice(&line).map_err(|_| {
                text(
                    "Invalid title subscription JSON",
                    "Некорректный JSON подписки заголовков",
                )
            })?;
            if value.get("id").and_then(Value::as_str) != Some(REQUEST_ID) {
                return Err(text(
                    "Title subscription identity mismatch",
                    "Несовпадение идентификатора подписки заголовков",
                )
                .into());
            }
            if value.get("error").is_some() {
                return Err(text(
                    "Server rejected title subscription",
                    "Сервер отклонил подписку заголовков",
                )
                .into());
            }
            if value.pointer("/result/type").and_then(Value::as_str) != Some("subscription_started")
            {
                return Err(text(
                    "Invalid title subscription acknowledgment",
                    "Некорректное подтверждение подписки заголовков",
                )
                .into());
            }
        }
        Ok(feed)
    }

    pub fn next(&self, timeout: Duration) -> Result<NextTitle, String> {
        let result = self.read_event(timeout);
        if result.is_err() || matches!(&result, Ok(NextTitle::Closed)) {
            self.close();
        }
        result
    }

    fn read_event(&self, timeout: Duration) -> Result<NextTitle, String> {
        let mut reader = self
            .reader
            .lock()
            .map_err(|_| text("Title reader failed", "Ошибка reader заголовков"))?;
        match reader.next(&self.stream, &self.closed, Instant::now() + timeout)? {
            Line::Timeout => Ok(NextTitle::Timeout),
            Line::Closed => Ok(NextTitle::Closed),
            Line::Ready(line) => {
                let value: Value = serde_json::from_slice(&line).map_err(|_| {
                    text(
                        "Invalid title event JSON",
                        "Некорректный JSON события заголовка",
                    )
                })?;
                if !matches!(
                    value.get("event").and_then(Value::as_str),
                    Some("pane_updated" | "pane_closed")
                ) || !value.get("data").is_some_and(Value::is_object)
                    || value.get("error").is_some()
                {
                    return Err(text(
                        "Invalid title event envelope or subscription failure",
                        "Некорректная оболочка события заголовка или ошибка подписки",
                    )
                    .into());
                }
                Ok(NextTitle::Event(CString::new(line).map_err(|_| {
                    text("NUL in title event", "NUL в событии заголовка")
                })?))
            }
        }
    }

    pub fn close(&self) {
        self.closed.store(true, Ordering::Release);
        let _ = self.stream.shutdown(Shutdown::Both);
    }
}

impl Drop for TavernTitleFeed {
    fn drop(&mut self) {
        self.close();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        io::{BufRead, BufReader, Read},
        os::unix::net::UnixListener,
        path::PathBuf,
        sync::{atomic::AtomicUsize, mpsc, Arc},
        thread,
    };

    static SEQUENCE: AtomicUsize = AtomicUsize::new(0);
    const ACK: &[u8] =
        b"{\"id\":\"tavern-title-feed\",\"result\":{\"type\":\"subscription_started\"}}\n";
    const UPDATED: &[u8] = b"{\"event\":\"pane_updated\",\"data\":{\"type\":\"pane_updated\",\"pane\":{\"pane_id\":\"w1:p1\",\"terminal_id\":\"term_1\",\"revision\":3,\"terminal_title\":\"Working\"}}}\n";
    const CLOSED: &[u8] = b"{\"event\":\"pane_closed\",\"data\":{\"type\":\"pane_closed\",\"pane_id\":\"w1:p1\",\"workspace_id\":\"w1\"}}\n";
    struct Socket {
        path: PathBuf,
        listener: UnixListener,
    }
    impl Socket {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "tavern-title-{}-{}.sock",
                std::process::id(),
                SEQUENCE.fetch_add(1, Ordering::Relaxed)
            ));
            let listener = UnixListener::bind(&path).unwrap();
            Self { path, listener }
        }
        fn serve(&self, body: impl FnOnce(UnixStream) + Send + 'static) -> thread::JoinHandle<()> {
            let listener = self.listener.try_clone().unwrap();
            thread::spawn(move || {
                let (stream, _) = listener.accept().unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(2)))
                    .unwrap();
                let mut reader = BufReader::new(stream);
                let mut request = String::new();
                reader.read_line(&mut request).unwrap();
                let request: Value = serde_json::from_str(&request).unwrap();
                assert_eq!(request["method"], "events.subscribe");
                assert_eq!(
                    request["params"]["subscriptions"],
                    serde_json::json!([{"type":"pane.updated"},{"type":"pane.closed"}])
                );
                body(reader.into_inner());
            })
        }
        fn open(&self) -> Result<TavernTitleFeed, String> {
            TavernTitleFeed::open(self.path.to_str().unwrap())
        }
    }
    impl Drop for Socket {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.path);
        }
    }
    fn event(feed: &TavernTitleFeed) -> Value {
        match feed.next(Duration::from_secs(1)).unwrap() {
            NextTitle::Event(json) => serde_json::from_slice(json.as_bytes()).unwrap(),
            _ => panic!("expected event"),
        }
    }

    #[test]
    fn coalesced_ack_and_events_survive_separate_next_calls() {
        let socket = Socket::new();
        let server = socket.serve(|mut stream| {
            stream.write_all(&[ACK, UPDATED, CLOSED].concat()).unwrap();
        });
        let feed = socket.open().unwrap();
        assert_eq!(event(&feed)["data"]["pane"]["revision"], 3);
        assert_eq!(event(&feed)["event"], "pane_closed");
        assert!(matches!(
            feed.next(Duration::from_secs(1)).unwrap(),
            NextTitle::Closed
        ));
        server.join().unwrap();
    }

    #[test]
    fn partial_line_survives_timeout_then_finishes_without_loss() {
        let socket = Socket::new();
        let (resume, wait) = mpsc::channel();
        let (sent, ready) = mpsc::channel();
        let server = socket.serve(move |mut stream| {
            stream.write_all(ACK).unwrap();
            stream.write_all(&UPDATED[..30]).unwrap();
            sent.send(()).unwrap();
            wait.recv().unwrap();
            stream.write_all(&UPDATED[30..]).unwrap();
            stream.write_all(CLOSED).unwrap();
        });
        let feed = socket.open().unwrap();
        ready.recv().unwrap();
        assert!(matches!(
            feed.next(Duration::from_millis(10)).unwrap(),
            NextTitle::Timeout
        ));
        resume.send(()).unwrap();
        assert_eq!(event(&feed)["data"]["pane"]["terminal_title"], "Working");
        assert_eq!(event(&feed)["event"], "pane_closed");
        server.join().unwrap();
    }

    #[test]
    fn close_interrupts_wait_and_only_disconnects_the_subscription() {
        let socket = Socket::new();
        let server = socket.serve(|mut stream| {
            stream.write_all(ACK).unwrap();
            assert_eq!(stream.read(&mut [0; 1]).unwrap(), 0);
        });
        let feed = Arc::new(socket.open().unwrap());
        let (started, ready) = mpsc::channel();
        let worker_feed = feed.clone();
        let worker = thread::spawn(move || {
            started.send(()).unwrap();
            worker_feed.next(Duration::from_secs(60))
        });
        ready.recv().unwrap();
        feed.close();
        assert!(matches!(worker.join().unwrap().unwrap(), NextTitle::Closed));
        server.join().unwrap();
    }

    #[test]
    fn rejects_subscription_error_instead_of_accepting_open() {
        let socket = Socket::new();
        let server = socket.serve(|mut stream| {
            stream.write_all(b"{\"id\":\"tavern-title-feed\",\"error\":{\"code\":\"invalid_params\",\"message\":\"unsupported\"}}\n").unwrap();
        });
        assert!(socket.open().is_err());
        server.join().unwrap();
    }

    #[test]
    fn rejects_partial_event_at_eof() {
        let socket = Socket::new();
        let server = socket.serve(|mut stream| {
            stream.write_all(ACK).unwrap();
            stream.write_all(&UPDATED[..30]).unwrap();
        });
        let feed = socket.open().unwrap();
        assert!(feed.next(Duration::from_secs(1)).is_err());
        assert!(matches!(
            feed.next(Duration::ZERO).unwrap(),
            NextTitle::Closed
        ));
        server.join().unwrap();
    }

    #[test]
    fn rejects_event_over_line_limit() {
        let socket = Socket::new();
        let server = socket.serve(|mut stream| {
            stream.write_all(ACK).unwrap();
            // No newline: incremental accumulation must still enforce the cap.
            let _ = stream.write_all(&vec![b' '; MAX_JSON + 1]);
        });
        let feed = socket.open().unwrap();
        assert!(feed.next(Duration::from_secs(2)).is_err());
        server.join().unwrap();
    }

    #[test]
    fn accepts_exact_line_limit_and_preserves_following_event() {
        let socket = Socket::new();
        let server = socket.serve(|mut stream| {
            stream.write_all(ACK).unwrap();
            let mut line = UPDATED[..UPDATED.len() - 1].to_vec();
            line.resize(MAX_JSON, b' ');
            line.push(b'\n');
            stream.write_all(&line).unwrap();
            stream.write_all(CLOSED).unwrap();
        });
        let feed = socket.open().unwrap();
        assert_eq!(event(&feed)["event"], "pane_updated");
        assert_eq!(event(&feed)["event"], "pane_closed");
        server.join().unwrap();
    }

    #[test]
    fn rejects_acknowledgment_for_another_request() {
        let socket = Socket::new();
        let server = socket.serve(|mut stream| {
            stream.write_all(b"{\"id\":\"another-request\",\"result\":{\"type\":\"subscription_started\"}}\n").unwrap();
        });
        assert!(socket.open().is_err());
        server.join().unwrap();
    }

    #[test]
    fn subscription_runtime_error_is_terminal() {
        let socket = Socket::new();
        let server = socket.serve(|mut stream| {
            stream.write_all(ACK).unwrap();
            stream.write_all(b"{\"id\":\"tavern-title-feed\",\"error\":{\"code\":\"internal\",\"message\":\"subscription failed\"}}\n").unwrap();
        });
        let feed = socket.open().unwrap();
        assert!(feed.next(Duration::from_secs(1)).is_err());
        assert!(matches!(
            feed.next(Duration::ZERO).unwrap(),
            NextTitle::Closed
        ));
        server.join().unwrap();
    }

    #[test]
    fn subscription_ack_deadline_is_bounded() {
        let socket = Socket::new();
        let server = socket.serve(|mut stream| {
            stream.write_all(b"{\"id\":").unwrap();
            assert_eq!(stream.read(&mut [0; 1]).unwrap(), 0);
        });
        let stream = connect(socket.path.to_str().unwrap()).unwrap();
        assert!(TavernTitleFeed::subscribe(stream, Duration::from_millis(20)).is_err());
        server.join().unwrap();
    }
}
