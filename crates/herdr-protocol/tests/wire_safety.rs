use herdr_protocol::{
    endpoint::{
        EndpointServerWelcome, BLOB_CODEC_V1, INPUT_CODEC_V1, SNAPSHOT_CODEC_V1, SURFACE_CODEC_V1,
    },
    read_message, write_message, AgentStatus, ClientShellWorkspace, FramingError, ServerMessage,
    MAX_FRAME_SIZE,
};
use std::io::{self, Cursor, Read};

fn control() -> ServerMessage {
    ServerMessage::EndpointControl {
        kind: "endpoint.test.optional.v1".into(),
        data: "{\"text\":\"кириллица\"}".into(),
    }
}

fn framed(message: &ServerMessage) -> Vec<u8> {
    let mut bytes = Vec::new();
    write_message(&mut bytes, message).unwrap();
    bytes
}

#[test]
fn truncated_length_prefix_is_eof() {
    let mut input = Cursor::new([8_u8, 0, 0]);
    assert!(matches!(
        read_message::<_, ServerMessage>(&mut input, MAX_FRAME_SIZE),
        Err(FramingError::UnexpectedEof)
    ));
}

#[test]
fn truncated_payload_is_eof() {
    let mut bytes = framed(&control());
    bytes.pop();
    assert!(matches!(
        read_message::<_, ServerMessage>(&mut Cursor::new(bytes), MAX_FRAME_SIZE),
        Err(FramingError::UnexpectedEof)
    ));
}

#[test]
fn oversized_length_is_rejected_before_reading_payload() {
    let mut bytes = ((MAX_FRAME_SIZE + 1) as u32).to_le_bytes().to_vec();
    bytes.extend_from_slice(b"unread payload");
    let mut input = Cursor::new(bytes);
    assert!(matches!(
        read_message::<_, ServerMessage>(&mut input, MAX_FRAME_SIZE),
        Err(FramingError::Oversized { claimed, max })
            if claimed == MAX_FRAME_SIZE + 1 && max == MAX_FRAME_SIZE
    ));
    assert_eq!(input.position(), 4);
}

#[test]
fn trailing_bytes_are_not_silently_accepted() {
    let mut bytes = framed(&control());
    let payload_length = bytes.len() - 4;
    bytes[..4].copy_from_slice(&((payload_length + 1) as u32).to_le_bytes());
    bytes.push(0);
    assert!(matches!(
        read_message::<_, ServerMessage>(&mut Cursor::new(bytes), MAX_FRAME_SIZE),
        Err(FramingError::Bincode(_))
    ));
}

#[test]
fn unknown_binary_message_variant_is_a_protocol_error() {
    // Bincode standard encodes tags <251 in one byte; 250 is not a V1 message tag.
    let mut input = Cursor::new([1_u8, 0, 0, 0, 250]);
    assert!(matches!(
        read_message::<_, ServerMessage>(&mut input, MAX_FRAME_SIZE),
        Err(FramingError::Bincode(_))
    ));
}

struct ByteAtATime<R>(R);

impl<R: Read> Read for ByteAtATime<R> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        let count = buffer.len().min(1);
        self.0.read(&mut buffer[..count])
    }
}

#[test]
fn partial_reads_reassemble_exactly_one_message() {
    let expected = control();
    let bytes = framed(&expected);
    let mut reader = ByteAtATime(Cursor::new(bytes.clone()));
    let decoded: ServerMessage = read_message(&mut reader, MAX_FRAME_SIZE).unwrap();
    assert_eq!(decoded, expected);
    assert_eq!(reader.0.position(), bytes.len() as u64);
}

#[test]
fn welcome_ignores_new_optional_fields_but_requires_core_codecs() {
    let value = serde_json::json!({
        "generation": 1,
        "server_version": "future",
        "snapshot_codec": SNAPSHOT_CODEC_V1,
        "surface_codec": SURFACE_CODEC_V1,
        "input_codec": INPUT_CODEC_V1,
        "blob_codec": BLOB_CODEC_V1,
        "future_optional_field": {"nested": true}
    });
    let _: EndpointServerWelcome = serde_json::from_value(value.clone()).unwrap();
    let mut missing_codec = value;
    missing_codec.as_object_mut().unwrap().remove("blob_codec");
    assert!(serde_json::from_value::<EndpointServerWelcome>(missing_codec).is_err());
}

#[test]
fn future_json_agent_status_maps_to_unknown_without_changing_binary_codec() {
    let workspace: ClientShellWorkspace = serde_json::from_value(serde_json::json!({
        "workspace_id": "workspace-1",
        "active_tab_id": "tab-1",
        "new_workspace_cwd": "/",
        "number": 1,
        "label": "Проект",
        "custom_label": false,
        "branch": null,
        "git_ahead_behind": null,
        "tokens": [],
        "worktree": null,
        "focused": true,
        "agent_status": "future-status",
        "future_optional_field": true
    }))
    .unwrap();
    assert_eq!(workspace.agent_status, AgentStatus::Unknown);
    let mut bytes = Vec::new();
    write_message(&mut bytes, &workspace).unwrap();
    let decoded: ClientShellWorkspace =
        read_message(&mut Cursor::new(bytes), MAX_FRAME_SIZE).unwrap();
    assert_eq!(decoded, workspace);
}
