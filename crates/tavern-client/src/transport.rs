use crate::localization::{localized_format, text};
use std::{
    ffi::CString,
    io::{self, Read},
    mem,
    os::{
        fd::{AsRawFd, FromRawFd, OwnedFd},
        unix::net::UnixStream,
    },
    time::{Duration, Instant},
};

pub const IO_DEADLINE: Duration = Duration::from_secs(10);
pub const REQUEST_DEADLINE: Duration = Duration::from_secs(15);
pub const MAX_JSON: usize = 1024 * 1024;
pub const MAX_RESPONSE: usize = 8 * 1024 * 1024;

pub fn connect(path: &str) -> Result<UnixStream, String> {
    let path = CString::new(path).map_err(|_| text("NUL in socket path", "NUL в пути сокета"))?;
    // AF_UNIX connect can block when the accept backlog is full. Nonblocking
    // connect + poll gives it the same bounded deadline as handshake and writes.
    unsafe {
        let mut addr: libc::sockaddr_un = mem::zeroed();
        let bytes = path.as_bytes_with_nul();
        if bytes.len() > addr.sun_path.len() {
            return Err(text(
                "Unix socket path is too long",
                "Слишком длинный путь Unix socket",
            )
            .into());
        }
        addr.sun_family = libc::AF_UNIX as _;
        for (to, from) in addr.sun_path.iter_mut().zip(bytes) {
            *to = *from as _;
        }
        #[cfg(target_os = "macos")]
        {
            addr.sun_len = mem::size_of::<libc::sockaddr_un>() as u8;
        }
        let raw = libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0);
        if raw < 0 {
            return Err(text(
                "Failed to create Unix socket",
                "Не удалось создать Unix socket",
            )
            .into());
        }
        let fd = OwnedFd::from_raw_fd(raw);
        #[cfg(target_os = "macos")]
        {
            // This socket bypasses UnixStream::connect's setup. A cancelled
            // write must return EPIPE, not terminate the hosting Swift process.
            let enabled: libc::c_int = 1;
            if libc::setsockopt(
                raw,
                libc::SOL_SOCKET,
                libc::SO_NOSIGPIPE,
                &enabled as *const _ as *const _,
                mem::size_of_val(&enabled) as libc::socklen_t,
            ) < 0
            {
                return Err(text(
                    "Failed to configure Unix socket",
                    "Не удалось настроить Unix socket",
                )
                .into());
            }
        }
        if libc::fcntl(raw, libc::F_SETFD, libc::FD_CLOEXEC) < 0
            || libc::fcntl(raw, libc::F_SETFL, libc::O_NONBLOCK) < 0
        {
            return Err(text(
                "Failed to configure Unix socket",
                "Не удалось настроить Unix socket",
            )
            .into());
        }
        if libc::connect(
            raw,
            &addr as *const _ as *const libc::sockaddr,
            mem::size_of_val(&addr) as _,
        ) < 0
        {
            let error = io::Error::last_os_error();
            if error.raw_os_error() != Some(libc::EINPROGRESS) {
                return Err(localized_format!(
                    "Unix socket connection: {}",
                    "Подключение Unix socket: {}",
                    error.kind()
                ));
            }
            let mut pollfd = libc::pollfd {
                fd: raw,
                events: libc::POLLOUT,
                revents: 0,
            };
            let end = Instant::now() + IO_DEADLINE;
            loop {
                let remaining = end.saturating_duration_since(Instant::now());
                if remaining.is_zero() {
                    return Err(text(
                        "Unix socket connection timed out",
                        "Таймаут подключения Unix socket",
                    )
                    .into());
                }
                let result = libc::poll(
                    &mut pollfd,
                    1,
                    remaining.as_millis().min(i32::MAX as u128) as i32,
                );
                if result > 0 {
                    break;
                }
                if result == 0 {
                    return Err(text(
                        "Unix socket connection timed out",
                        "Таймаут подключения Unix socket",
                    )
                    .into());
                }
                if io::Error::last_os_error().kind() != io::ErrorKind::Interrupted {
                    return Err(text(
                        "Failed to wait for Unix socket",
                        "Ошибка ожидания Unix socket",
                    )
                    .into());
                }
            }
            let mut error: libc::c_int = 0;
            let mut size = mem::size_of_val(&error) as libc::socklen_t;
            if libc::getsockopt(
                raw,
                libc::SOL_SOCKET,
                libc::SO_ERROR,
                &mut error as *mut _ as *mut _,
                &mut size,
            ) < 0
                || error != 0
            {
                return Err(text(
                    "Unix socket connection refused",
                    "Unix socket отклонил подключение",
                )
                .into());
            }
        }
        if libc::fcntl(fd.as_raw_fd(), libc::F_SETFL, 0) < 0 {
            return Err(text(
                "Failed to enable blocking Unix socket",
                "Не удалось включить blocking Unix socket",
            )
            .into());
        }
        let stream = UnixStream::from(fd);
        stream
            .set_write_timeout(Some(Duration::from_millis(250)))
            .map_err(|_| {
                text(
                    "Failed to configure write timeout",
                    "Не удалось настроить write timeout",
                )
            })?;
        stream
            .set_read_timeout(Some(Duration::from_millis(250)))
            .map_err(|_| {
                text(
                    "Failed to configure read timeout",
                    "Не удалось настроить read timeout",
                )
            })?;
        Ok(stream)
    }
}

pub struct DeadlineWriter<'a> {
    pub stream: &'a UnixStream,
    pub deadline: Instant,
}
impl io::Write for DeadlineWriter<'_> {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        loop {
            if Instant::now() >= self.deadline {
                return Err(io::ErrorKind::TimedOut.into());
            }
            match self.stream.write(bytes) {
                Err(e)
                    if matches!(
                        e.kind(),
                        io::ErrorKind::WouldBlock
                            | io::ErrorKind::TimedOut
                            | io::ErrorKind::Interrupted
                    ) =>
                {
                    continue
                }
                result => return result,
            }
        }
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

pub struct DeadlineReader<'a, F: Fn() -> bool> {
    pub stream: &'a UnixStream,
    pub frame_deadline: Option<Instant>,
    pub cancelled: F,
    pub bytes_read: usize,
}
impl<F: Fn() -> bool> Read for DeadlineReader<'_, F> {
    fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        loop {
            if (self.cancelled)() {
                return Err(io::ErrorKind::ConnectionAborted.into());
            }
            if self.frame_deadline.is_some_and(|end| Instant::now() >= end) {
                return Err(io::ErrorKind::TimedOut.into());
            }
            match self.stream.read(bytes) {
                Ok(n) => {
                    if n > 0 {
                        self.bytes_read += n;
                        if self.frame_deadline.is_none() {
                            self.frame_deadline = Some(Instant::now() + IO_DEADLINE);
                        }
                    }
                    return Ok(n);
                }
                Err(e)
                    if matches!(
                        e.kind(),
                        io::ErrorKind::WouldBlock
                            | io::ErrorKind::TimedOut
                            | io::ErrorKind::Interrupted
                    ) =>
                {
                    continue
                }
                Err(e) => return Err(e),
            }
        }
    }
}
