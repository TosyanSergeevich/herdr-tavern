// @generated из herdr (Apache-2.0); происхождение и рецепт: ../../PROVENANCE.json.
// Обновление: cargo run --offline -p import-protocol -- UPSTREAM_CHECKOUT
use serde :: { Serialize , Deserialize } ; # [derive (Debug , Clone , Copy , PartialEq , Eq , Deserialize , Serialize , Default)] # [serde (rename_all = "kebab-case")] pub enum ToastHerdrPosition { TopLeft , TopRight , BottomLeft , # [default] BottomRight , }
