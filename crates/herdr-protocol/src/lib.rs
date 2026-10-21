//! Wire-контракт herdr без приложения, сервера и терминального UI.
//! Генерируемые типы хранятся в исходниках; сборка не читает upstream checkout.
//! Происхождение и исключения перечислены в `PROVENANCE.json` пакета.

pub mod input {
    include!("generated/input.rs");
}

pub mod config {
    include!("generated/config.rs");
}

pub mod api {
    pub mod schema {
        include!("generated/agent_status.rs");
    }
}

pub mod protocol {
    include!("generated/wire.rs");

    pub mod endpoint {
        include!("generated/endpoint.rs");
    }
}

pub use api::schema::AgentStatus;
pub use config::ToastHerdrPosition;
pub use input::WindowsKeyRecord;
pub use protocol::*;
