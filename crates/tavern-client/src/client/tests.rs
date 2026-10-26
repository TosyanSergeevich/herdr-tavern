use super::*;
use crate::{tavern_event_cell, tavern_event_free, TavernCell};
use std::{io::Write, sync::mpsc};

fn welcome() -> EndpointServerWelcome {
    EndpointServerWelcome {
        generation: 1,
        server_version: "test".into(),
        snapshot_codec: SNAPSHOT_CODEC_V1.into(),
        surface_codec: SURFACE_CODEC_V1.into(),
        input_codec: INPUT_CODEC_V1.into(),
        blob_codec: BLOB_CODEC_V1.into(),
        methods: vec!["tab.focus".into(), "client_shell.surface.set".into()],
        capabilities: vec![SURFACE_INTEREST_CAPABILITY.into()],
        error: None,
    }
}
fn fixture() -> (Arc<Shared>, UnixStream, UnixStream) {
    let (client, server) = UnixStream::pair().unwrap();
    client
        .set_read_timeout(Some(Duration::from_millis(20)))
        .unwrap();
    let shared = Arc::new(Shared {
        state: Mutex::new(State {
            closed: false,
            snapshot: Some(("boot".into(), 1)),
            pending: None,
            queue: VecDeque::new(),
        }),
        changed: Condvar::new(),
        control: client.try_clone().unwrap(),
    });
    (shared, client, server)
}
fn pending(shared: &Shared) {
    lock(&shared.state).pending = Some(Pending {
        info: RequestInfo {
            id: "request".into(),
            boot: "boot".into(),
            method: "tab.focus".into(),
        },
        deadline: Instant::now() + REQUEST_DEADLINE,
        bytes: Vec::new(),
        chunks: 0,
    });
}
fn frame() -> PaneSurfaceFrame {
    PaneSurfaceFrame {
        boot_id: "boot".into(),
        projection_revision: 1,
        surface_revision: 1,
        frame: FrameData {
            cells: vec![CellData {
                symbol: "Ж".into(),
                fg: 0x02010203,
                bg: 0,
                modifier: 1,
                skip: false,
                hyperlink: None,
            }],
            width: 1,
            height: 1,
            cursor: None,
            hyperlinks: vec![],
            graphics: vec![],
        },
        panes: vec![],
        splits: vec![],
        popup: None,
        graphics: SurfaceGraphicsScene::default(),
    }
}
fn patch() -> PaneSurfacePatch {
    PaneSurfacePatch {
        boot_id: "boot".into(),
        projection_revision: 1,
        base_surface_revision: 1,
        surface_revision: 2,
        rows: vec![PaneSurfacePatchRow {
            x: 0,
            y: 0,
            cells: frame().frame.cells,
        }],
        panes: vec![],
        cursor: None,
    }
}
#[test]
fn welcome_allows_unknown_json_fields_but_checks_all_codecs_and_capability() {
    let mut value = serde_json::to_value(welcome()).unwrap();
    value["future_optional"] = json!({"version":2});
    let parsed: EndpointServerWelcome = serde_json::from_value(value).unwrap();
    validate_welcome(&parsed).unwrap();
    for index in 0..4 {
        let mut wrong = parsed.clone();
        match index {
            0 => wrong.snapshot_codec = "unknown".into(),
            1 => wrong.surface_codec = "unknown".into(),
            2 => wrong.input_codec = "unknown".into(),
            _ => wrong.blob_codec = "unknown".into(),
        }
        assert!(validate_welcome(&wrong).is_err());
    }
    let mut missing = parsed;
    missing.capabilities.clear();
    assert!(validate_welcome(&missing).is_err());
}
#[test]
fn truncated_frame_is_not_clean_eof_and_is_observable() {
    let (shared, client, mut server) = fixture();
    let mut bytes = Vec::new();
    write_message(&mut bytes, &ServerMessage::PaneSurface(frame())).unwrap();
    server.write_all(&bytes[..bytes.len() - 1]).unwrap();
    server.shutdown(Shutdown::Write).unwrap();
    let error = receive(&client, &shared).unwrap_err();
    shared.finish(Some(error));
    let s = lock(&shared.state);
    assert_eq!(s.queue[0].kind, event::ERROR);
    assert_eq!(s.queue[1].kind, event::CLOSED);
}
#[test]
fn stale_patch_identity_does_not_advance_baseline() {
    let mut baseline = Baseline::from_full(&frame());
    for index in 0..4 {
        let mut p = patch();
        match index {
            0 => p.boot_id = "other".into(),
            1 => p.projection_revision = 9,
            2 => p.base_surface_revision = 7,
            _ => p.surface_revision = 1,
        }
        assert!(baseline.accept_patch(&p).is_err());
        assert_eq!(baseline.revision, 1);
    }
    baseline.accept_patch(&patch()).unwrap();
    assert_eq!(baseline.revision, 2);
}
#[test]
fn patch_outside_grid_and_unknown_hyperlink_are_atomic_errors() {
    let mut baseline = Baseline::from_full(&frame());
    let mut p = patch();
    p.rows[0].x = 1;
    assert!(baseline.accept_patch(&p).is_err());
    assert_eq!(baseline.revision, 1);
    p.rows[0].x = 0;
    p.rows[0].cells[0].hyperlink = Some(0);
    assert!(baseline.accept_patch(&p).is_err());
    assert_eq!(baseline.revision, 1);
}
#[test]
fn rejected_chunked_response_is_delivered_intact_and_releases_request() {
    let (shared, _, _) = fixture();
    pending(&shared);
    assert!(response_chunk(
        &shared,
        "boot",
        "request",
        false,
        br#"{"id":"request","error":"#.to_vec()
    )
    .unwrap()
    .is_none());
    let event = response_chunk(
        &shared,
        "boot",
        "request",
        true,
        br#"{"code":"rejected","message":"no"}}"#.to_vec(),
    )
    .unwrap()
    .unwrap();
    let value: Value = serde_json::from_slice(&event.json).unwrap();
    assert_eq!(value["response"]["error"]["code"], "rejected");
    assert_eq!(event.kind, event::RESPONSE);
    assert!(lock(&shared.state).pending.is_none());
}
#[test]
fn response_identity_is_checked_before_accepting_bytes() {
    let (shared, _, _) = fixture();
    pending(&shared);
    assert!(response_chunk(&shared, "wrong", "request", false, vec![1]).is_err());
    assert!(response_chunk(&shared, "boot", "wrong", false, vec![1]).is_err());
    assert!(lock(&shared.state)
        .pending
        .as_ref()
        .unwrap()
        .bytes
        .is_empty());
}
#[test]
fn response_chunks_and_bytes_are_bounded() {
    let (shared, _, _) = fixture();
    pending(&shared);
    for _ in 0..CHUNK_LIMIT {
        response_chunk(&shared, "boot", "request", false, Vec::new()).unwrap();
    }
    assert!(response_chunk(&shared, "boot", "request", false, Vec::new()).is_err());
    pending(&shared);
    lock(&shared.state)
        .pending
        .as_mut()
        .unwrap()
        .bytes
        .resize(MAX_RESPONSE, 0);
    assert!(response_chunk(&shared, "boot", "request", true, vec![1]).is_err());
}
#[test]
fn request_id_inside_response_and_deadline_are_checked() {
    let (shared, _, _) = fixture();
    pending(&shared);
    assert!(response_chunk(
        &shared,
        "boot",
        "request",
        true,
        br#"{"id":"other","result":{}}"#.to_vec()
    )
    .is_err());
    pending(&shared);
    lock(&shared.state).pending.as_mut().unwrap().deadline = Instant::now();
    assert!(response_chunk(
        &shared,
        "boot",
        "request",
        true,
        br#"{"id":"request","result":{}}"#.to_vec()
    )
    .is_err());
}
#[test]
fn close_interrupts_idle_reader_and_partial_frame_without_waiting_for_frame_deadline() {
    for partial in [false, true] {
        let (shared, client, mut server) = fixture();
        if partial {
            server.write_all(&[12, 0, 0, 0, 13]).unwrap();
        }
        let receiver = Arc::clone(&shared);
        let (done_tx, done_rx) = mpsc::channel();
        let reader = thread::spawn(move || {
            let result = receive(&client, &receiver);
            done_tx.send(result).unwrap();
        });
        shared.finish(None);
        assert!(done_rx
            .recv_timeout(Duration::from_secs(1))
            .unwrap()
            .is_ok());
        reader.join().unwrap();
        assert!(lock(&shared.state).closed);
    }
}
#[test]
fn close_wakes_reader_blocked_by_bounded_event_queue() {
    let (shared, _, _) = fixture();
    for _ in 0..QUEUE_LIMIT {
        shared
            .push(TavernEvent::metadata(event::NOTICE, json!({"type":"test"})))
            .unwrap();
    }
    let receiver = Arc::clone(&shared);
    let (done_tx, done_rx) = mpsc::channel();
    let reader = thread::spawn(move || {
        done_tx
            .send(receiver.push(TavernEvent::metadata(
                event::NOTICE,
                json!({"type":"extra"}),
            )))
            .unwrap();
    });
    shared.finish(None);
    assert!(done_rx
        .recv_timeout(Duration::from_secs(1))
        .unwrap()
        .is_ok());
    reader.join().unwrap();
    assert_eq!(lock(&shared.state).queue.len(), QUEUE_LIMIT + 1);
}
#[test]
fn frame_metadata_excludes_cells_and_event_lifetime_is_independent() {
    let event = TavernEvent::full(frame()).unwrap();
    let value: Value = serde_json::from_slice(&event.json).unwrap();
    assert!(value.get("cells").is_none());
    assert_eq!(event.segments.len(), 1);
    let event = Box::into_raw(Box::new(event));
    let mut cell = std::mem::MaybeUninit::<TavernCell>::uninit();
    unsafe {
        assert_eq!(tavern_event_cell(event, 0, 0, cell.as_mut_ptr()), 0);
        let cell = cell.assume_init();
        assert_eq!(
            std::slice::from_raw_parts(cell.symbol.ptr, cell.symbol.len),
            "Ж".as_bytes()
        );
        assert_eq!(cell.modifier, 1);
        assert_eq!(tavern_event_cell(event, 0, 1, std::ptr::null_mut()), -1);
        tavern_event_free(event);
    }
}
#[test]
fn frame_never_reaches_queue_before_matching_snapshot() {
    let (shared, _, _) = fixture();
    lock(&shared.state).snapshot = None;
    let mut future = VecDeque::new();
    let surface = frame();
    let base = Baseline::from_full(&surface);
    deliver_surface(
        &shared,
        &mut future,
        &base,
        TavernEvent::full(surface).unwrap(),
    )
    .unwrap();
    assert!(lock(&shared.state).queue.is_empty());
    assert_eq!(future.len(), 1);
    lock(&shared.state).snapshot = Some(("other".into(), 1));
    assert!(deliver_surface(
        &shared,
        &mut VecDeque::new(),
        &base,
        TavernEvent::full(frame()).unwrap()
    )
    .is_err());
}
#[test]
fn second_request_is_rejected_without_writing_and_stale_boot_is_rejected() {
    let (shared, client, mut server) = fixture();
    let c = TavernClient {
        shared: Arc::clone(&shared),
        writer: Mutex::new(client),
        reader: None,
        welcome: welcome(),
    };
    pending(&shared);
    assert!(c.send(br#"{"type":"request","request_id":"second","boot_id":"boot","method":"tab.focus","params":{}}"#).is_err());
    server.set_nonblocking(true).unwrap();
    assert_eq!(
        server.read(&mut [0u8; 1]).unwrap_err().kind(),
        std::io::ErrorKind::WouldBlock
    );
    lock(&shared.state).pending = None;
    assert!(c.send(br#"{"type":"request","request_id":"second","boot_id":"other","method":"tab.focus","params":{}}"#).is_err());
}
#[test]
fn semantic_unicode_and_resize_use_upstream_wire_types() {
    let (message, _) = command::convert(
        serde_json::from_value(json!({"type":"text","pane_id":"pane","text":"Ж😀"})).unwrap(),
    )
    .unwrap();
    let mut encoded = Vec::new();
    write_message(&mut encoded, &message).unwrap();
    let decoded: ClientMessage = read_message(&mut encoded.as_slice(), MAX_FRAME_SIZE).unwrap();
    assert_eq!(message, decoded);
    assert!(command::convert(
        serde_json::from_value(
            json!({"type":"resize","cols":0,"rows":24,"cell_width_px":16,"cell_height_px":40})
        )
        .unwrap()
    )
    .is_err());
}

fn snapshot_message(revision: u64) -> ServerMessage {
    let mut snapshot = super::socket_tests::snapshot_json();
    snapshot["revision"] = json!(revision);
    ServerMessage::EndpointControl {
        kind: ENDPOINT_SNAPSHOT_KIND.into(),
        data: snapshot.to_string(),
    }
}

fn receive_sequence(
    shared: &Shared,
    client: &UnixStream,
    server: &mut UnixStream,
    messages: impl IntoIterator<Item = ServerMessage>,
) -> Result<(), String> {
    for message in messages {
        write_message(server, &message).unwrap();
    }
    server.shutdown(Shutdown::Write).unwrap();
    receive(client, shared)
}

fn receive_snapshots(snapshots: impl IntoIterator<Item = Value>) -> Result<Vec<Value>, String> {
    let (shared, client, mut server) = fixture();
    receive_sequence(
        &shared,
        &client,
        &mut server,
        snapshots.into_iter().map(|snapshot| ServerMessage::EndpointControl {
            kind: ENDPOINT_SNAPSHOT_KIND.into(),
            data: snapshot.to_string(),
        }),
    )?;
    let state = lock(&shared.state);
    Ok(state
        .queue
        .iter()
        .map(|event| {
            assert_eq!(event.kind, event::SNAPSHOT);
            serde_json::from_slice(&event.json).unwrap()
        })
        .collect())
}

fn snapshot_with_profile(profile: &str) -> Value {
    let mut snapshot = super::socket_tests::snapshot_json();
    snapshot["server_keybindings_toml"] = json!(profile);
    snapshot
}

#[test]
fn snapshot_prefix_array_preserves_commands_and_unknown_json_fields() {
    let snapshot = {
        let mut snapshot =
            snapshot_with_profile("[keys]\nprefix = ['ctrl+space', 'ctrl+b']\n");
        snapshot["commands"] = json!([{
            "command_id": "opaque-command",
            "binding_label": "ctrl+alt+r",
            "binding_labels": ["ctrl+alt+r", "prefix > r"],
            "action": "PluginAction",
            "description": "Open review",
            "future_binding": {"enabled": true}
        }]);
        snapshot
    };
    let events = receive_snapshots([snapshot.clone()]).unwrap();
    let mut projected = events.into_iter().next().unwrap();
    assert_eq!(
        projected.as_object_mut().unwrap().remove("command_prefixes"),
        Some(json!(["ctrl+space", "ctrl+b"]))
    );
    assert_eq!(projected, snapshot);
}

#[test]
fn snapshot_string_prefix_becomes_single_element_array() {
    let events =
        receive_snapshots([snapshot_with_profile("[keys]\nprefix = 'ctrl+a'\n")]).unwrap();
    assert_eq!(events[0]["command_prefixes"], json!(["ctrl+a"]));
}

#[test]
fn snapshot_without_published_profile_has_no_default_prefix() {
    let mut snapshot = super::socket_tests::snapshot_json();
    snapshot
        .as_object_mut()
        .unwrap()
        .remove("server_keybindings_toml");
    let events = receive_snapshots([snapshot]).unwrap();
    assert_eq!(events[0]["command_prefixes"], json!([]));
}

#[test]
fn reload_updates_prefixes_and_commands_and_clears_unpublished_prefixes() {
    let first = snapshot_with_profile("[keys]\nprefix = 'ctrl+a'\n");
    let mut reloaded = snapshot_with_profile("[keys]\nprefix = ['ctrl+b', 'ctrl+space']\n");
    reloaded["revision"] = json!(2);
    reloaded["commands"] = json!([{
        "command_id": "new-opaque-command",
        "binding_label": "ctrl+alt+r",
        "binding_labels": ["ctrl+alt+r"],
        "action": "PluginAction",
        "description": null
    }]);
    let mut same_profile = reloaded.clone();
    same_profile["revision"] = json!(3);
    same_profile["commands"][0]["command_id"] = json!("replaced-opaque-command");
    let mut unpublished = super::socket_tests::snapshot_json();
    unpublished["revision"] = json!(4);
    let events = receive_snapshots([first, reloaded.clone(), same_profile.clone(), unpublished])
        .unwrap();
    assert_eq!(events[0]["command_prefixes"], json!(["ctrl+a"]));
    assert_eq!(events[1]["command_prefixes"], json!(["ctrl+b", "ctrl+space"]));
    assert_eq!(events[1]["commands"], reloaded["commands"]);
    assert_eq!(events[2]["command_prefixes"], events[1]["command_prefixes"]);
    assert_eq!(events[2]["commands"], same_profile["commands"]);
    assert_eq!(events[3]["command_prefixes"], json!([]));
}

#[test]
fn malformed_published_profile_is_an_explicit_error() {
    assert!(receive_snapshots([snapshot_with_profile("[keys\nprefix = 'ctrl+a'")]).is_err());
}

#[test]
fn published_profile_without_prefix_is_an_explicit_error() {
    assert!(receive_snapshots([snapshot_with_profile("[keys]\n")]).is_err());
}

#[test]
fn published_prefix_with_wrong_type_is_an_explicit_error() {
    assert!(receive_snapshots([snapshot_with_profile("[keys]\nprefix = 42\n")]).is_err());
}

#[test]
fn published_prefix_array_with_non_string_member_is_an_explicit_error() {
    assert!(receive_snapshots([snapshot_with_profile(
        "[keys]\nprefix = ['ctrl+a', 42]\n",
    )]).is_err());
}

#[test]
fn new_snapshot_supersedes_in_flight_frames_without_breaking_patch_chain() {
    let (shared, client, mut server) = fixture();
    let mut stale_full = frame();
    stale_full.surface_revision = 2;
    let mut stale_patch = patch();
    stale_patch.base_surface_revision = 2;
    stale_patch.surface_revision = 3;
    let mut current_full = frame();
    current_full.projection_revision = 3;
    current_full.surface_revision = 4;
    current_full.frame.cells[0].symbol = "A".into();
    let mut current_patch = patch();
    current_patch.projection_revision = 3;
    current_patch.base_surface_revision = 4;
    current_patch.surface_revision = 5;
    current_patch.rows[0].cells[0].symbol = "B".into();
    receive_sequence(
        &shared,
        &client,
        &mut server,
        [
            ServerMessage::PaneSurface(frame()),
            snapshot_message(3),
            ServerMessage::PaneSurface(stale_full),
            ServerMessage::PaneSurfacePatch(stale_patch),
            ServerMessage::PaneSurface(current_full),
            ServerMessage::PaneSurfacePatch(current_patch),
        ],
    )
    .unwrap();
    let state = lock(&shared.state);
    assert!(!state.closed);
    assert_eq!(
        state.queue.iter().map(|event| event.kind).collect::<Vec<_>>(),
        [event::FULL, event::SNAPSHOT, event::FULL, event::PATCH]
    );
    assert_eq!(state.queue[2].segments[0].cells[0].symbol, "A");
    assert_eq!(state.queue[3].segments[0].cells[0].symbol, "B");
    let metadata: Value = serde_json::from_slice(&state.queue[3].json).unwrap();
    assert_eq!(metadata["projection_revision"], 3);
    assert_eq!(metadata["base_surface_revision"], 4);
    assert_eq!(metadata["surface_revision"], 5);
}

#[test]
fn new_snapshot_supersedes_waiting_frames_and_releases_matching_chain() {
    let (shared, client, mut server) = fixture();
    let mut waiting_full = frame();
    waiting_full.projection_revision = 2;
    let mut waiting_patch = patch();
    waiting_patch.projection_revision = 2;
    let mut current_full = frame();
    current_full.projection_revision = 3;
    current_full.surface_revision = 3;
    let mut current_patch = patch();
    current_patch.projection_revision = 3;
    current_patch.base_surface_revision = 3;
    current_patch.surface_revision = 4;
    current_patch.rows[0].cells[0].symbol = "C".into();
    receive_sequence(
        &shared,
        &client,
        &mut server,
        [
            ServerMessage::PaneSurface(waiting_full),
            ServerMessage::PaneSurfacePatch(waiting_patch),
            ServerMessage::PaneSurface(current_full),
            ServerMessage::PaneSurfacePatch(current_patch),
            snapshot_message(3),
        ],
    )
    .unwrap();
    let state = lock(&shared.state);
    assert!(!state.closed);
    assert_eq!(
        state.queue.iter().map(|event| event.kind).collect::<Vec<_>>(),
        [event::SNAPSHOT, event::FULL, event::PATCH]
    );
    assert_eq!(state.queue[2].segments[0].cells[0].symbol, "C");
    let metadata: Value = serde_json::from_slice(&state.queue[2].json).unwrap();
    assert_eq!(metadata["projection_revision"], 3);
    assert_eq!(metadata["base_surface_revision"], 3);
}

#[test]
fn superseded_patch_still_requires_the_decoder_baseline() {
    let (shared, client, mut server) = fixture();
    let mut wrong_patch = patch();
    wrong_patch.base_surface_revision = 99;
    let error = receive_sequence(
        &shared,
        &client,
        &mut server,
        [
            snapshot_message(2),
            ServerMessage::PaneSurface(frame()),
            ServerMessage::PaneSurfacePatch(wrong_patch),
        ],
    )
    .unwrap_err();
    shared.finish(Some(error));
    let state = lock(&shared.state);
    assert!(state.closed);
    assert_eq!(
        state.queue.iter().map(|event| event.kind).collect::<Vec<_>>(),
        [event::SNAPSHOT, event::ERROR, event::CLOSED]
    );
}

#[test]
fn superseded_surface_from_another_boot_still_closes_the_connection() {
    let (shared, client, mut server) = fixture();
    lock(&shared.state).snapshot = Some(("boot".into(), 3));
    let mut wrong_full = frame();
    wrong_full.boot_id = "other".into();
    let error = receive_sequence(
        &shared,
        &client,
        &mut server,
        [ServerMessage::PaneSurface(wrong_full)],
    )
    .unwrap_err();
    shared.finish(Some(error));
    let state = lock(&shared.state);
    assert!(state.closed);
    assert_eq!(
        state.queue.iter().map(|event| event.kind).collect::<Vec<_>>(),
        [event::ERROR, event::CLOSED]
    );
}

#[test]
fn snapshot_schema_is_validated_before_publication() {
    let mut snapshot = super::socket_tests::snapshot_json();
    snapshot["panes"] = json!({"not": "an array"});
    assert!(receive_snapshots([snapshot]).is_err());
}
