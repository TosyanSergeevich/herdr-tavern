// Рецепт импорта wire-контракта herdr (Apache-2.0).
// Обычная сборка использует checked-in исходники и никогда не запускает этот инструмент.
use quote::{quote, ToTokens};
use std::{error::Error, ffi::OsString, fs, path::Path, process::Command};
use syn::{Item, Type, UseTree};

const REVISION: &str = "2563803dca97c040beaf3dc3acdcb5a3221b4238";
const HEADER: &str = "// @generated из herdr (Apache-2.0); происхождение и рецепт: ../../PROVENANCE.json.\n// Обновление: cargo run --offline -p import-protocol -- UPSTREAM_CHECKOUT\n";
const SOURCES: &[&str] = &[
    "src/protocol/wire.rs",
    "src/protocol/endpoint.rs",
    "src/input/model.rs",
    "src/api/schema/common.rs",
    "src/config/model.rs",
    "LICENSE",
];

type Result<T> = std::result::Result<T, Box<dyn Error>>;

fn main() {
    if let Err(error) = import() {
        eprintln!("Импорт протокола: {error}");
        std::process::exit(1);
    }
}

fn git(root: &Path, arguments: &[&str]) -> Result<String> {
    let output = Command::new("git")
        .arg("-C")
        .arg(root)
        .args(arguments)
        .output()?;
    if !output.status.success() {
        return Err(format!("git: {}", String::from_utf8_lossy(&output.stderr)).into());
    }
    Ok(String::from_utf8(output.stdout)?)
}

fn parse(root: &Path, source: &str) -> Result<syn::File> {
    Ok(syn::parse_file(&fs::read_to_string(root.join(source))?)?)
}

fn use_contains(tree: &UseTree, name: &str) -> bool {
    match tree {
        UseTree::Path(path) => use_contains(&path.tree, name),
        UseTree::Name(item) => item.ident == name,
        UseTree::Rename(item) => item.ident == name,
        UseTree::Group(group) => group.items.iter().any(|tree| use_contains(tree, name)),
        UseTree::Glob(_) => false,
    }
}

fn emit(items: impl IntoIterator<Item = Item>) -> String {
    let mut output = HEADER.to_owned();
    for item in items {
        output.push_str(&item.to_token_stream().to_string());
        output.push('\n');
    }
    output
}

fn wire(root: &Path) -> Result<String> {
    let items = parse(root, SOURCES[0])?
        .items
        .into_iter()
        .filter(|item| match item {
            Item::Use(item) => !use_contains(&item.tree, "HashMap"),
            Item::Const(item) => !matches!(
                item.ident.to_string().as_str(),
                "UNDERLINE_STYLE_SHIFT" | "UNDERLINE_STYLE_MASK"
            ),
            Item::Struct(_) | Item::Enum(_) | Item::Type(_) => true,
            Item::Impl(item) => match item.self_ty.as_ref() {
                Type::Path(path) => {
                    item.trait_.is_some()
                        && path.path.segments.last().is_some_and(|segment| {
                            matches!(
                                segment.ident.to_string().as_str(),
                                "FramingError" | "CellData"
                            )
                        })
                }
                _ => false,
            },
            Item::Fn(item) => matches!(
                item.sig.ident.to_string().as_str(),
                "deserialize_client_shell_agent_status"
                    | "serialize_graphics_bytes"
                    | "deserialize_graphics_bytes"
                    | "write_message"
                    | "read_message"
                    | "read_exact_or_eof"
            ),
            _ => false,
        })
        .collect::<Vec<_>>();
    for required in [
        "ClientMessage",
        "ServerMessage",
        "FramingError",
        "PaneSurfaceFrame",
        "PaneSurfacePatch",
    ] {
        if !items.iter().any(|item| match item {
            Item::Struct(item) => item.ident == required,
            Item::Enum(item) => item.ident == required,
            _ => false,
        }) {
            return Err(format!("Отсутствует обязательный wire-тип {required}").into());
        }
    }
    for required in ["write_message", "read_message", "read_exact_or_eof"] {
        if !items
            .iter()
            .any(|item| matches!(item, Item::Fn(item) if item.sig.ident == required))
        {
            return Err(format!("Отсутствует обязательный framing helper {required}").into());
        }
    }
    Ok(emit(items))
}

fn endpoint(root: &Path) -> Result<String> {
    let items = parse(root, SOURCES[1])?
        .items
        .into_iter()
        .filter_map(|item| match item {
            Item::Use(item) if use_contains(&item.tree, "ClientSurfaceSize") => {
                Some(syn::parse_quote!(
                    use super::ClientSurfaceSize;
                ))
            }
            Item::Use(_) | Item::Const(_) | Item::Struct(_) | Item::Enum(_) => Some(item),
            Item::Impl(ref implementation)
                if matches!(implementation.self_ty.as_ref(),
            Type::Path(path) if path.path.is_ident("EndpointClientHello")) =>
            {
                Some(item)
            }
            Item::Fn(ref function) if function.sig.ident == "default_true" => Some(item),
            _ => None,
        });
    Ok(emit(items))
}

fn leaf(root: &Path, source: &str, name: &str) -> Result<String> {
    for mut item in parse(root, source)?.items {
        let attributes = match &mut item {
            Item::Struct(item) if item.ident == name => &mut item.attrs,
            Item::Enum(item) if item.ident == name => &mut item.attrs,
            _ => continue,
        };
        for attribute in attributes
            .iter_mut()
            .filter(|attribute| attribute.path().is_ident("derive"))
        {
            let paths = attribute.parse_args_with(
                syn::punctuated::Punctuated::<syn::Path, syn::Token![,]>::parse_terminated,
            )?;
            let retained = paths
                .into_iter()
                .filter(|path| {
                    path.segments
                        .last()
                        .is_none_or(|segment| segment.ident != "JsonSchema")
                })
                .collect::<Vec<_>>();
            *attribute = syn::parse_quote!(#[derive(#(#retained),*)]);
        }
        return Ok(format!(
            "{HEADER}{}\n",
            quote!(use serde::{Serialize, Deserialize}; #item)
        ));
    }
    Err(format!("Отсутствует обязательный leaf-тип {name} в {source}").into())
}

fn import() -> Result<()> {
    let arguments = std::env::args_os().skip(1).collect::<Vec<OsString>>();
    if arguments.is_empty() || arguments.len() > 3 {
        return Err("Использование: import-protocol UPSTREAM_CHECKOUT [EXPECTED_REVISION] [PROTOCOL_CRATE_DIR]; defaults: закреплённая ревизия и crates/herdr-protocol".into());
    }
    let upstream = Path::new(&arguments[0]);
    let revision = arguments
        .get(1)
        .map(|value| value.to_str().ok_or("Ревизия должна быть UTF-8"))
        .transpose()?
        .unwrap_or(REVISION);
    if revision.len() != 40 || !revision.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err("EXPECTED_REVISION должна быть полным 40-символьным commit SHA".into());
    }
    if git(upstream, &["rev-parse", "HEAD"])?.trim() != revision {
        return Err("HEAD upstream checkout не совпадает с EXPECTED_REVISION".into());
    }
    let mut status_arguments = vec!["status", "--porcelain", "--"];
    status_arguments.extend_from_slice(SOURCES);
    if !git(upstream, &status_arguments)?.is_empty() {
        return Err("Заимствуемые upstream-файлы содержат незакоммиченные изменения".into());
    }
    let destination = arguments
        .get(2)
        .map(Path::new)
        .unwrap_or_else(|| Path::new("crates/herdr-protocol"));
    // Сначала разобрать весь набор, чтобы ошибка извлечения не оставила частичный результат.
    let generated = [
        ("wire.rs", wire(upstream)?),
        ("endpoint.rs", endpoint(upstream)?),
        ("input.rs", leaf(upstream, SOURCES[2], "WindowsKeyRecord")?),
        (
            "agent_status.rs",
            leaf(upstream, SOURCES[3], "AgentStatus")?,
        ),
        (
            "config.rs",
            leaf(upstream, SOURCES[4], "ToastHerdrPosition")?,
        ),
    ];
    let license = fs::read(upstream.join("LICENSE"))?;
    let provenance = serde_json::json!({
        "schema_version": 1,
        "upstream": "https://github.com/herdrdev/herdr",
        "revision": revision,
        "license": "Apache-2.0",
        "license_file": "LICENSE",
        "sources": SOURCES,
        "generator": "tools/import-protocol/src/main.rs",
        "update_command": "cargo run --offline -p import-protocol -- UPSTREAM_CHECKOUT [EXPECTED_REVISION] [PROTOCOL_CRATE_DIR]",
        "selection": {
            "wire": "Top-level use/const/struct/enum/type; trait impls for FramingError and CellData; deserialize_client_shell_agent_status, serialize_graphics_bytes, deserialize_graphics_bytes, write_message, read_message, read_exact_or_eof",
            "endpoint": "Top-level use/const/struct/enum, default_true and EndpointClientHello codec validation",
            "leaf_types": ["WindowsKeyRecord", "AgentStatus", "ToastHerdrPosition"]
        },
        "exceptions": [
            "Leaf derives remove only JsonSchema; serde attributes and field/variant order remain unchanged",
            "HashMap import and UNDERLINE_STYLE_SHIFT/MASK constants omitted with UI conversion helpers",
            "Endpoint imports retain only ClientSurfaceSize; server factory and message helpers omitted",
            "Runtime/TUI conversions, version check helper, server constructors and upstream test modules are not imported",
            "AST token emission preserves doc attributes but omits ordinary comments; generated source headers added"
        ]
    });
    fs::create_dir_all(destination.join("src/generated"))?;
    for (filename, source) in generated {
        fs::write(destination.join("src/generated").join(filename), source)?;
    }
    fs::write(destination.join("LICENSE"), license)?;
    fs::write(
        destination.join("PROVENANCE.json"),
        format!("{}\n", serde_json::to_string_pretty(&provenance)?),
    )?;
    println!("Wire-контракт импортирован из herdr {revision}");
    Ok(())
}
