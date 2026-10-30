#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd -P)"
cd "$ROOT"
export MACOSX_DEPLOYMENT_TARGET=14.0
export CARGO_TARGET_DIR="$ROOT/target"
SIGNING_IDENTITY="Herdr Tavern Local Signing"
if ! security find-identity -v -p codesigning | /usr/bin/grep -Fq "\"$SIGNING_IDENTITY\""; then
    printf 'A persistent code-signing certificate named "%s" with its private key is required in Keychain; see README.md.\n' "$SIGNING_IDENTITY" >&2
    exit 1
fi
plutil -lint resources/en.lproj/*.strings resources/ru.lproj/*.strings

# Cargo разбивает RUSTFLAGS по пробельным символам; encoded-форма сохраняет пробелы в путях.
if [[ -z "${CARGO_ENCODED_RUSTFLAGS+x}" ]]; then
    rust_flags=()
    IFS=$' \t\r\n\v\f' read -r -d '' -a rust_flags <<< "${RUSTFLAGS:-}" || true
    CARGO_ENCODED_RUSTFLAGS=""
    if [[ -n "${rust_flags[0]:-}" ]]; then
        for flag in "${rust_flags[@]}"; do
            CARGO_ENCODED_RUSTFLAGS+="${CARGO_ENCODED_RUSTFLAGS:+$'\x1f'}$flag"
        done
    fi
fi
# Более конкретные префиксы идут последними: rustc использует последнее совпадение.
for mapping in "$HOME=home" "${CARGO_HOME:-$HOME/.cargo}=cargo" "${RUSTUP_HOME:-$HOME/.rustup}=rustup" "$ROOT=tavern"; do
    CARGO_ENCODED_RUSTFLAGS+="${CARGO_ENCODED_RUSTFLAGS:+$'\x1f'}--remap-path-prefix=$mapping"
done
export CARGO_ENCODED_RUSTFLAGS

cargo +stable build --locked --release -p tavern-client
mkdir -p "$ROOT/build"
STAGING="$(mktemp -d "$ROOT/build/.tavern-build.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/Herdr Tavern.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Licenses" "$APP/Contents/Resources/Sounds" "$APP/Contents/Resources/Fonts" "$APP/Contents/Resources/Textures"
xcrun swiftc -O -target "$(uname -m)-apple-macosx14.0" \
    -file-prefix-map "$HOME=home" -file-prefix-map "$ROOT=tavern" \
    -Xlinker -oso_prefix -Xlinker "$ROOT/" \
    -import-objc-header app/BridgingHeader.h app/*.swift \
    target/release/libtavern_client.a \
    -framework AppKit -framework QuartzCore -framework CoreText -framework CoreGraphics -framework UserNotifications -framework Metal -framework MetalKit \
    -o "$APP/Contents/MacOS/HerdrTavern"
cp app/Info.plist "$APP/Contents/Info.plist"
cp LICENSE LICENSE.ru NOTICE NOTICE.ru "$APP/Contents/Resources/Licenses/"
cp crates/herdr-protocol/LICENSE "$APP/Contents/Resources/Licenses/herdr-protocol.txt"
cp licenses/*.txt "$APP/Contents/Resources/Licenses/"
cp -R resources/en.lproj resources/ru.lproj "$APP/Contents/Resources/"
cp resources/Sounds/*.wav "$APP/Contents/Resources/Sounds/"
cp resources/Fonts/*.ttf resources/Fonts/*.otf "$APP/Contents/Resources/Fonts/"
# Только изображения, которые загружают нативные контроллеры.
runtime_textures=(
    OakPanel.png LivingBoardWood.png LivingTopTab.png LivingTabRecess.png
    LivingAddButton.png LivingFrame.png LivingSidebarFrame.png
    LivingSidebarSprig.png LivingSidebarLeaves.png LivingRootFrame.png
    ScrollerBronze.png AgentChainConnector.png AgentChainStrap.png AgentChainBelt.png
    ButtonNavigation.png ButtonPrimary.png ButtonTool.png ButtonToolIcon.png
    LivingHangingLantern.png LivingLanternBracket.png
    TavernVisuals/materials/plank-atlas.png
    TavernVisuals/nebula/workspace-nebula.png
    TavernVisuals/nebula/workspace-nebula-weights.png
    TavernVisuals/sprites/bookmark.png
    TavernVisuals/sprites/bookmark-height.png
    TavernVisuals/sprites/bookmark-material.png
    TavernVisuals/sprites/particle-core.png
    TavernVisuals/sprites/particle-soft.png
    TavernVisuals/sprites/glow.png
    TavernVisuals/chained/mount.png
    TavernVisuals/chained/progress-body.png
    TavernVisuals/chained/success-body.png
    TavernVisuals/chained/question-body.png
    TavernVisuals/chained/error-body.png
    TavernVisuals/chained/waiting-body.png
)
for texture in "${runtime_textures[@]}"; do
    destination="$APP/Contents/Resources/Textures/$texture"
    mkdir -p "$(dirname "$destination")"
    cp "resources/Textures/$texture" "$destination"
done
mkdir -p "$APP/Contents/Resources/Shaders"
cp resources/Shaders/TavernCard.metal "$APP/Contents/Resources/Shaders/"
cp resources/Shaders/TavernWorkspaceNebula.metal "$APP/Contents/Resources/Shaders/"
cp resources/Icons/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign "$SIGNING_IDENTITY" --identifier org.local.HerdrTavern "$APP"
codesign --verify --deep --strict "$APP"
# Не трогаем прежнее приложение, пока новая сборка не подписана и не проверена.
rm -rf "$ROOT/build/Herdr Tavern.app"
mv "$APP" "$ROOT/build/Herdr Tavern.app"
printf 'Built: build/Herdr Tavern.app\n'
