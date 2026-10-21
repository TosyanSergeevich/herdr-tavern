use super::*;
use std::{
    io::{BufRead, BufReader},
    os::unix::net::UnixListener,
    path::PathBuf,
    sync::atomic::{AtomicUsize, Ordering},
};
static SEQUENCE: AtomicUsize = AtomicUsize::new(0);
struct SocketFixture {
    path: PathBuf,
    listener: UnixListener,
}
impl SocketFixture {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "tavern-client-{}-{}.sock",
            std::process::id(),
            SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        let listener = UnixListener::bind(&path).unwrap();
        Self { path, listener }
    }
    fn path(&self) -> &str {
        self.path.to_str().unwrap()
    }
}
impl Drop for SocketFixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}
fn welcome_json() -> Value {
    json!({"generation":1,"server_version":"test","snapshot_codec":SNAPSHOT_CODEC_V1,"surface_codec":SURFACE_CODEC_V1,
        "input_codec":INPUT_CODEC_V1,"blob_codec":BLOB_CODEC_V1,"methods":["tab.focus","client_shell.surface.set"],
        "capabilities":[SURFACE_INTEREST_CAPABILITY],"future_optional":true})
}
pub(super) fn snapshot_json() -> Value {
    json!({"boot_id":"boot","revision":1,"config_diagnostic":null,"product_announcement":null,"update_available":null,
        "update_install_command":"herdr update","server_keybindings_toml":null,"latest_release_notes_available":false,
        "integration_updates_available":false,"worktree_directory":"","release_notes":null,"focused_workspace_id":null,
        "focused_tab_id":null,"focused_pane_id":null,"tab_bar_right":[],"tab_bar_right_separator":"","agent_view_label":null,
        "agent_order":[],"workspaces":[],"tabs":[],"panes":[],"agents":[],"commands":[],"future_optional":{"enabled":true}})
}
#[test]
fn actual_connect_handshake_snapshot_request_response_and_close() {
    let socket = SocketFixture::new();
    let listener = socket.listener.try_clone().unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        let hello: ClientMessage = read_message(&mut stream, MAX_FRAME_SIZE).unwrap();
        match hello {
            ClientMessage::EndpointControl { kind, data } => {
                assert_eq!(kind, ENDPOINT_HELLO_KIND);
                let hello: EndpointClientHello = serde_json::from_str(&data).unwrap();
                assert!(hello.supports_required_codecs());
                assert!(!hello.surface_delta && !hello.surface_reuse && !hello.surface_scroll);
            }
            _ => panic!("expected stable endpoint hello"),
        }
        write_message(
            &mut stream,
            &ServerMessage::EndpointControl {
                kind: ENDPOINT_WELCOME_KIND.into(),
                data: welcome_json().to_string(),
            },
        )
        .unwrap();
        write_message(
            &mut stream,
            &ServerMessage::EndpointControl {
                kind: ENDPOINT_SNAPSHOT_KIND.into(),
                data: snapshot_json().to_string(),
            },
        )
        .unwrap();
        let request: ClientMessage = read_message(&mut stream, MAX_FRAME_SIZE).unwrap();
        match request {
            ClientMessage::ClientShellEndpointRequest { boot_id, request } => {
                assert_eq!(boot_id, "boot");
                assert_eq!(
                    serde_json::from_str::<Value>(&request).unwrap()["id"],
                    "request"
                );
            }
            _ => panic!("expected endpoint request"),
        }
        write_message(
            &mut stream,
            &ServerMessage::ClientShellEndpointResponseChunk {
                boot_id: "boot".into(),
                request_id: "request".into(),
                final_chunk: true,
                data: br#"{"id":"request","error":{"code":"rejected","message":"no"}}"#.to_vec(),
            },
        )
        .unwrap();
        // Production close does not send stop or restart anything: only EOF.
        assert!(matches!(
            read_message::<_, ClientMessage>(&mut stream, MAX_FRAME_SIZE),
            Err(FramingError::UnexpectedEof)
        ));
    });
    let client = TavernClient::open(socket.path(), 80, 24, 16, 40).unwrap();
    assert!(
        matches!(client.next(Duration::from_secs(2)),NextEvent::Event(e) if e.kind==event::NOTICE)
    );
    match client.next(Duration::from_secs(2)) {
        NextEvent::Event(e) => {
            assert_eq!(e.kind, event::SNAPSHOT);
            assert_eq!(
                serde_json::from_slice::<Value>(&e.json).unwrap()["future_optional"]["enabled"],
                true
            );
        }
        _ => panic!("missing snapshot"),
    }
    client.send(br#"{"type":"request","request_id":"request","boot_id":"boot","method":"tab.focus","params":{}}"#).unwrap();
    assert!(
        matches!(client.next(Duration::from_secs(2)),NextEvent::Event(e) if e.kind==event::RESPONSE)
    );
    client.close();
    assert!(
        matches!(client.next(Duration::from_secs(2)),NextEvent::Event(e) if e.kind==event::CLOSED)
    );
    assert!(matches!(client.next(Duration::ZERO), NextEvent::Closed));
    drop(client);
    server.join().unwrap();
}
#[test]
fn public_json_preserves_rejected_reply_and_checks_id() {
    for wrong_id in [false, true] {
        let socket = SocketFixture::new();
        let listener = socket.listener.try_clone().unwrap();
        let server = thread::spawn(move || {
            use std::io::Write;
            let (mut stream, _) = listener.accept().unwrap();
            let mut line = String::new();
            BufReader::new(&mut stream).read_line(&mut line).unwrap();
            let request: Value = serde_json::from_str(&line).unwrap();
            assert_eq!(request["method"], "pane.move");
            let response=json!({"id":if wrong_id { "wrong" } else { "move" },"error":{"code":"rejected","message":"no"}}).to_string();
            stream.write_all(response.as_bytes()).unwrap();
            stream.write_all(b"\n").unwrap();
        });
        let result = public_json(
            socket.path(),
            br#"{"id":"move","method":"pane.move","params":{"pane_id":"p"}}"#,
        );
        if wrong_id {
            assert!(result.is_err());
        } else {
            assert_eq!(
                serde_json::from_str::<Value>(&result.unwrap()).unwrap()["error"]["code"],
                "rejected"
            );
        }
        server.join().unwrap();
    }
}
