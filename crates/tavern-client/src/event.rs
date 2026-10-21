use crate::localization::text;
use herdr_protocol::*;
use serde_json::{json, Value};

pub const SNAPSHOT: u32 = 1;
pub const FULL: u32 = 2;
pub const PATCH: u32 = 3;
pub const RESPONSE: u32 = 4;
pub const NOTICE: u32 = 5;
pub const ERROR: u32 = 6;
pub const CLOSED: u32 = 7;

pub struct Segment {
    pub x: u16,
    pub y: u16,
    pub target: u8,
    pub cells: Vec<CellData>,
}
pub struct Asset {
    pub id: String,
    pub asset: SurfaceGraphicsAsset,
}
pub struct TavernEvent {
    pub kind: u32,
    pub json: Vec<u8>,
    pub segments: Vec<Segment>,
    pub assets: Vec<Asset>,
}
impl TavernEvent {
    pub fn metadata(kind: u32, value: Value) -> Self {
        Self {
            kind,
            json: value.to_string().into_bytes(),
            segments: Vec::new(),
            assets: Vec::new(),
        }
    }
    pub fn full(mut surface: PaneSurfaceFrame) -> Result<Self, String> {
        validate_grid(&surface.frame)?;
        let mut segments = vec![Segment {
            x: 0,
            y: 0,
            target: 0,
            cells: std::mem::take(&mut surface.frame.cells),
        }];
        let popup = if let Some(p) = surface.popup.as_mut() {
            validate_grid(&p.frame)?;
            segments.push(Segment {
                x: 0,
                y: 0,
                target: 1,
                cells: std::mem::take(&mut p.frame.cells),
            });
            Some(
                json!({"terminal_id":p.terminal_id,"title":p.title,"width":p.width,"height":p.height,
                "frame":grid_metadata(&p.frame),"mouse_reporting":p.mouse_reporting,
                "sgr_pixel_mouse":p.sgr_pixel_mouse,"pixel_width":p.pixel_width,"pixel_height":p.pixel_height}),
            )
        } else {
            None
        };
        let mut placements = Vec::with_capacity(surface.graphics.placements.len());
        for p in &surface.graphics.placements {
            let mut v = serde_json::to_value(p).map_err(|_| {
                text(
                    "Failed to encode graphics placement",
                    "Не удалось кодировать размещение графики",
                )
            })?;
            v["id"] = Value::String(asset_id(&p.asset));
            placements.push(v);
        }
        let retained: Vec<_> = surface
            .graphics
            .retained_assets
            .iter()
            .map(asset_id)
            .collect();
        let mut assets = Vec::with_capacity(surface.graphics.assets.len());
        let mut asset_metadata = Vec::with_capacity(surface.graphics.assets.len());
        for asset in surface.graphics.assets {
            validate_asset(&asset)?;
            let id = asset_id(&asset.key);
            asset_metadata.push(json!({"id":id,"key":asset.key}));
            assets.push(Asset { id, asset });
        }
        let value = json!({"boot_id":surface.boot_id,"projection_revision":surface.projection_revision,
            "surface_revision":surface.surface_revision,"width":surface.frame.width,"height":surface.frame.height,
            "cursor":surface.frame.cursor,"hyperlinks":surface.frame.hyperlinks,"panes":surface.panes,
            "splits":surface.splits,"popup":popup,"assets":asset_metadata,"placements":placements,
            "retained_assets":retained});
        Ok(Self {
            kind: FULL,
            json: value.to_string().into_bytes(),
            segments,
            assets,
        })
    }
    pub fn patch(patch: PaneSurfacePatch, width: u16, height: u16) -> Self {
        let value = json!({"boot_id":patch.boot_id,"projection_revision":patch.projection_revision,
            "base_surface_revision":patch.base_surface_revision,"surface_revision":patch.surface_revision,
            "width":width,"height":height,"panes":patch.panes,"cursor":patch.cursor});
        Self {
            kind: PATCH,
            json: value.to_string().into_bytes(),
            assets: Vec::new(),
            segments: patch
                .rows
                .into_iter()
                .map(|r| Segment {
                    x: r.x,
                    y: r.y,
                    target: 0,
                    cells: r.cells,
                })
                .collect(),
        }
    }
}
fn grid_metadata(frame: &FrameData) -> Value {
    json!({"width":frame.width,"height":frame.height,"cursor":frame.cursor,"hyperlinks":frame.hyperlinks})
}
fn validate_grid(frame: &FrameData) -> Result<(), String> {
    if frame.width == 0
        || frame.height == 0
        || frame.cells.len() != usize::from(frame.width) * usize::from(frame.height)
    {
        return Err(text(
            "Grid dimensions do not match the frame",
            "Размер сетки не соответствует кадру",
        )
        .into());
    }
    if !frame.graphics.is_empty() {
        return Err(text(
            "Inline Kitty graphics are unsupported; expected surface assets",
            "Неподдерживаемая inline Kitty графика; ожидаются surface assets",
        )
        .into());
    }
    if let Some(c) = &frame.cursor {
        if c.x >= frame.width || c.y >= frame.height {
            return Err(text("Cursor is outside the grid", "Курсор вне сетки").into());
        }
    }
    for c in &frame.cells {
        if c.hyperlink
            .is_some_and(|i| i as usize >= frame.hyperlinks.len())
        {
            return Err(text("Invalid hyperlink index", "Некорректный индекс гиперссылки").into());
        }
    }
    Ok(())
}
fn validate_asset(asset: &SurfaceGraphicsAsset) -> Result<(), String> {
    let k = &asset.key;
    if k.data_len != asset.data.len() as u64 || k.image_width == 0 || k.image_height == 0 {
        return Err(text(
            "Invalid graphics asset length or dimensions",
            "Некорректная длина или размер графического asset",
        )
        .into());
    }
    let channels = match k.format {
        SurfaceGraphicsFormat::Rgb => 3,
        SurfaceGraphicsFormat::Rgba => 4,
        SurfaceGraphicsFormat::Png => return Ok(()),
    };
    let expected = u64::from(k.image_width)
        .checked_mul(u64::from(k.image_height))
        .and_then(|n| n.checked_mul(channels));
    if expected != Some(k.data_len) {
        return Err(text(
            "Invalid RGB/RGBA asset length",
            "Некорректная длина RGB/RGBA asset",
        )
        .into());
    }
    Ok(())
}
pub fn asset_id(k: &SurfaceGraphicsAssetKey) -> String {
    // Full key includes source: equal pixels in different targets must not alias.
    serde_json::to_string(k).expect(text(
        "Surface asset key serialization is infallible",
        "Сериализация ключа surface asset не может завершиться ошибкой",
    ))
}

#[derive(Clone, Debug)]
pub struct Baseline {
    pub boot: String,
    pub projection: u64,
    pub revision: u64,
    pub width: u16,
    pub height: u16,
    pub hyperlink_count: usize,
}
impl Baseline {
    pub fn from_full(s: &PaneSurfaceFrame) -> Self {
        Self {
            boot: s.boot_id.clone(),
            projection: s.projection_revision,
            revision: s.surface_revision,
            width: s.frame.width,
            height: s.frame.height,
            hyperlink_count: s.frame.hyperlinks.len(),
        }
    }
    pub fn accept_patch(&mut self, p: &PaneSurfacePatch) -> Result<(), String> {
        if (self.boot.as_str(), self.projection, self.revision)
            != (
                p.boot_id.as_str(),
                p.projection_revision,
                p.base_surface_revision,
            )
            || p.surface_revision <= p.base_surface_revision
        {
            return Err(text(
                "Patch does not match the boot/projection/surface baseline",
                "Патч не соответствует boot/projection/surface baseline",
            )
            .into());
        }
        for r in &p.rows {
            if r.y >= self.height || usize::from(r.x) + r.cells.len() > usize::from(self.width) {
                return Err(
                    text("Patch exceeds grid bounds", "Патч выходит за границы сетки").into(),
                );
            }
            if r.cells.iter().any(|c| {
                c.hyperlink
                    .is_some_and(|i| i as usize >= self.hyperlink_count)
            }) {
                return Err(text(
                    "Patch contains an unknown hyperlink",
                    "Патч содержит неизвестную гиперссылку",
                )
                .into());
            }
        }
        if p.cursor
            .as_ref()
            .is_some_and(|c| c.x >= self.width || c.y >= self.height)
        {
            return Err(text("Patch cursor is outside the grid", "Курсор патча вне сетки").into());
        }
        self.revision = p.surface_revision;
        Ok(())
    }
}
