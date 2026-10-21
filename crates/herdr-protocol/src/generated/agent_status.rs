// @generated из herdr (Apache-2.0); происхождение и рецепт: ../../PROVENANCE.json.
// Обновление: cargo run --offline -p import-protocol -- UPSTREAM_CHECKOUT
use serde :: { Serialize , Deserialize } ; # [derive (Debug , Clone , Copy , PartialEq , Eq , Serialize , Deserialize)] # [serde (rename_all = "snake_case")] pub enum AgentStatus { Idle , Working , Blocked , Done , Unknown , }
