// @generated из herdr (Apache-2.0); происхождение и рецепт: ../../PROVENANCE.json.
// Обновление: cargo run --offline -p import-protocol -- UPSTREAM_CHECKOUT
use serde :: { Serialize , Deserialize } ; # [derive (Debug , Clone , Copy , PartialEq , Eq , Serialize , Deserialize)] pub struct WindowsKeyRecord { pub key_down : bool , pub repeat_count : u16 , pub virtual_key_code : u16 , pub virtual_scan_code : u16 , pub unicode : u16 , pub control_key_state : u32 , }
