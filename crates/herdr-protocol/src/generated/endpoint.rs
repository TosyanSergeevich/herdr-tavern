// @generated из herdr (Apache-2.0); происхождение и рецепт: ../../PROVENANCE.json.
// Обновление: cargo run --offline -p import-protocol -- UPSTREAM_CHECKOUT
use serde :: { Deserialize , Serialize } ;
use super :: ClientSurfaceSize ;
pub const ENDPOINT_PROTOCOL_GENERATION : u32 = 1 ;
pub const ENDPOINT_HELLO_KIND : & str = "endpoint.hello.v1" ;
pub const ENDPOINT_WELCOME_KIND : & str = "endpoint.welcome.v1" ;
pub const SNAPSHOT_CODEC_V1 : & str = "shell.snapshot.v1" ;
pub const ENDPOINT_SNAPSHOT_KIND : & str = SNAPSHOT_CODEC_V1 ;
pub const SURFACE_CODEC_V1 : & str = "shell.surface.v1" ;
pub const INPUT_CODEC_V1 : & str = "shell.input.semantic.v1" ;
pub const BLOB_CODEC_V1 : & str = "shell.blob.v1" ;
pub const SURFACE_INTEREST_CAPABILITY : & str = "surface_interest" ;
pub const PRESENTATION_EFFECTS_FENCE_CAPABILITY : & str = "presentation_effects_fence" ;
pub const PRESENTATION_EFFECTS_SYNC_KIND : & str = "endpoint.presentation.sync.v1" ;
pub const PRESENTATION_EFFECTS_READY_KIND : & str = "endpoint.presentation.ready.v1" ;
pub const HEALTH_CHECK_CAPABILITY : & str = "health_check" ;
pub const HEALTH_PING_KIND : & str = "endpoint.health.ping.v1" ;
pub const HEALTH_PONG_KIND : & str = "endpoint.health.pong.v1" ;
pub const AGENT_VIEW_PROJECTION_CAPABILITY : & str = "agent_view_projection" ;
pub const AGENT_VIEW_PROJECTION_KIND : & str = "endpoint.agent-view.v1" ;
pub const AGENT_COMPLETIONS_CAPABILITY : & str = "agent_completions" ;
pub const AGENT_COMPLETIONS_KIND : & str = "endpoint.agent-completions.v1" ;
# [derive (Debug , Clone , PartialEq , Eq , Serialize , Deserialize)] pub struct EndpointAgentCompletions { pub boot_id : String , pub revision : u64 , pub completions : std :: collections :: BTreeMap < String , u64 > , }
fn default_true () -> bool { true }
# [derive (Debug , Clone , PartialEq , Eq , Serialize , Deserialize)] pub struct EndpointClientHello { pub generation : u32 , pub cell_width_px : u32 , pub cell_height_px : u32 , pub surface_size : ClientSurfaceSize , pub pixel_mouse : bool , pub direct_graphics : bool , pub endpoint_keybindings : bool , pub mouse_capture : bool , # [serde (default = "default_true")] pub surface_active : bool , # [doc = " Accept the optional cell-retaining surface encoding on this connection."] # [serde (default)] pub surface_reuse : bool , # [doc = " Accept the optional surface-delta encoding on this connection."] # [serde (default)] pub surface_delta : bool , # [doc = " Accept the optional scroll-aware patch encoding on this connection."] # [serde (default)] pub surface_scroll : bool , # [serde (default)] pub snapshot_codecs : Vec < String > , # [serde (default)] pub surface_codecs : Vec < String > , # [serde (default)] pub input_codecs : Vec < String > , # [serde (default)] pub blob_codecs : Vec < String > , }
# [derive (Debug , Clone , PartialEq , Eq , Serialize , Deserialize)] pub struct EndpointHandshakeError { pub code : String , pub message : String , }
# [doc = " Optional companion to a V1 snapshot. The view payload is intentionally opaque to this"] # [doc = " stable envelope so clients can ignore view language additions they do not understand."] # [derive (Debug , Clone , PartialEq , Eq , Serialize , Deserialize)] pub struct EndpointAgentViewProjection { pub boot_id : String , pub revision : u64 , # [serde (default)] pub view : Option < serde_json :: Value > , }
# [derive (Debug , Clone , PartialEq , Eq , Serialize , Deserialize)] pub struct EndpointServerWelcome { pub generation : u32 , pub server_version : String , pub snapshot_codec : String , pub surface_codec : String , pub input_codec : String , pub blob_codec : String , # [serde (default)] pub methods : Vec < String > , # [serde (default)] pub capabilities : Vec < String > , # [serde (default , skip_serializing_if = "Option::is_none")] pub error : Option < EndpointHandshakeError > , }
impl EndpointClientHello { pub fn supports_required_codecs (& self) -> bool { self . snapshot_codecs . iter () . any (| codec | codec == SNAPSHOT_CODEC_V1) && self . surface_codecs . iter () . any (| codec | codec == SURFACE_CODEC_V1) && self . input_codecs . iter () . any (| codec | codec == INPUT_CODEC_V1) && self . blob_codecs . iter () . any (| codec | codec == BLOB_CODEC_V1) } }
