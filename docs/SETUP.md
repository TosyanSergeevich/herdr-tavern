# Build and settings

[← Herdr Tavern](../README.md) · English · [Русский](SETUP.ru.md)

## Requirements

- **macOS 14 or later.** Builds target the current machine's architecture; they are not universal binaries.
- **Xcode Command Line Tools** providing `xcrun swiftc`.
- **Rust stable through rustup**, with Cargo.
- **Herdr at runtime.** Tavern can offer to install it if it is missing; manual installation is also supported. Current features have been checked with **0.9.4**; compatibility with arbitrary newer versions is not guaranteed.
- **A local signing certificate**, configured below.

Herdr is not included in the app bundle. Agent programs and model access are configured separately. Python and an image generator are not needed for a normal build.

All supplied fonts are included in `resources/Fonts/` and copied into the `.app` by the build, without downloading fonts or reading local font installations. Tavern loads them from its resources at startup; no manual font installation is required. The terminal uses Iosevka Custom **34.9.0** (Medium, Bold, Medium Oblique, and Bold Oblique) and Symbols Nerd Font; the decorative interface fonts are bundled too. System Menlo and emoji fallbacks remain provided by macOS.

## Local signing

Before the first build, use **Keychain Access** to create a self-signed **Code Signing** certificate named **Herdr Tavern Local Signing**. It must have a private key; configure trust only for Code Signing and allow `/usr/bin/codesign` to use the key. The build stops before compilation if no usable certificate is available.

Keep this certificate across updates: recreating it, even with the same name, changes the app's identity and may require granting macOS permissions again. Never commit the private key or its export. Local signing does not replace Developer ID signing and notarization for a public release.

## Build and run

Run these commands from the repository root, not from `docs/`:

```sh
./build.sh
open "build/Herdr Tavern.app"
```

The first build may need network access to download Cargo dependencies. With a populated cache, use `CARGO_NET_OFFLINE=true ./build.sh`. The script builds the app and verifies its signature; it does not run tests.

The build uses the committed runtime PNGs; no artwork generation is required. It assembles a clean temporary bundle and replaces `build/Herdr Tavern.app` only after compilation, signing, and signature verification succeed. Artwork masters and preparation scripts are not bundled.

The Cargo release profile explicitly sets `strip = "none"` to avoid an [LLVM dylib debug-stripping bug](https://github.com/rust-lang/rust/issues/157750) that makes macOS 27 reject Rust proc macros with `mis-aligned LINKEDIT string pool`. Compiler-path remapping remains enabled.

The build remaps local source, home, Cargo, and Rust toolchain paths to relative prefixes in the compiled app, including the linker's debug map. Runtime file access is unchanged; resource provenance uses source-bundle and artifact names rather than personal directory paths.

## Install herdr

Every launch checks for herdr. If it is missing, Tavern asks for permission to download the official **0.9.4** release from GitHub, verifies its SHA256 checksum, and installs it at `~/Library/Application Support/HerdrTavern/bin/herdr`. This is a pinned release, not `latest`; download starts only after confirmation.

This installation is for Tavern only and requires no administrator privileges. The installer does not install herdr system-wide or through Homebrew, modify existing installations, or change shell profiles or `PATH` outside Tavern. An already found herdr is used without downloading, overwriting, or updating it.

Cancelling the initial offer installs nothing and ends that launch. There is no “do not ask again” setting: if herdr is still missing at the next launch, the offer appears again. After a successful installation, startup continues without a manual restart.

Alternatively, follow the [herdr installation instructions](https://github.com/herdrdev/herdr#readme) and make the executable available to Tavern, or choose it explicitly with `--herdr PATH`. An invalid explicit path is an error, not permission to silently select or install another executable.

On launch, Tavern connects to an existing herdr session or starts a server if its socket is absent. A stale socket is not removed automatically: the app reports a connection error. Server startup log: `~/Library/Logs/HerdrTavern/server.log`.

## Choose a session or server

To use a separate session, from the repository root:

```sh
"build/Herdr Tavern.app/Contents/MacOS/HerdrTavern" --session tavern
```

| Argument | Purpose |
| --- | --- |
| `--session NAME` | Select a named herdr session. |
| `--herdr PATH` | Use this explicit herdr executable; an invalid path is an error, with no fallback or installation offer. |
| `--socket PATH` | Connect to a client socket without automatically starting a server. |

Without explicit arguments, Tavern takes `HERDR_SESSION`, `HERDR_SOCKET_PATH`, `HERDR_CLIENT_SOCKET_PATH`, and `XDG_CONFIG_HOME` into account. When starting a server, it adds standard Cargo and Homebrew directories to `PATH`, but does not read shell configuration or change an already running server's environment.

Tavern also sets `PI_FORCE_IMAGE_PROTOCOL=kitty` when starting a server so omp can display images in both new and restored panes. All panes on that server inherit this setting, even with other clients attached. It does not update existing servers or processes, including servers reached through `--socket`; applying the setting there requires restarting them with the variable set.

## Settings and usage

**Language.** Open Settings with `⌘,` or the tools button and choose **English** or **Русский**. English is the initial language; your choice is saved. The interface updates immediately without restarting Tavern, reconnecting, or losing herdr sessions. Terminal output and external programs retain their own languages.

**Agents and sounds.** The Agents section can install, update, and remove herdr integrations; agent programs and model access must be configured separately. Restart the relevant agent after changing its integration. The Sounds section offers toggles, volume, previews, and replacement with your own sound files.

**Herdr configuration.** The **herdr** menu exposes available settings and can open, validate, and reload the full `config.toml`, shared by local sessions. Herdr themes and indicators do not change Tavern's appearance; Tavern sounds are configured separately. With `--socket`, this menu still edits local configuration, which may differ from the connected server's. See the [herdr configuration documentation](https://herdr.dev/docs/configuration/).

**Paste and files.** `⌘V` pastes text; image attachment support depends on the program inside the terminal. Dragging from Finder inserts file paths into the pane under the pointer, without sending Enter or uploading files.

**Split panes.** `⌘D` splits the focused pane to the right; `⌘⇧W` splits it down. The new pane receives focus.

**Closing.** `⌘W` closes the focused pane after confirming termination of its processes. To close the Tavern window without terminating the herdr session or its processes, use the window's close button or the Window menu command.

**Notifications.** Allow banners in **System Settings → Notifications → Herdr Tavern**. Denying permission does not disable sounds or unread indicators on agent cards.

Tavern does not reproduce the entire herdr interface: custom `keys.command` support does not include every built-in shortcut of herdr's terminal interface.

## Development

The interface uses Swift/AppKit; the client and extracted protocol use Rust. Sources are in `app/` and `crates/`; checks are in `tests/` and the Rust packages.

Navigation compares an ordered value projection of displayed fields, prepared on the reader and published with the matching snapshot. Surface geometry independently invalidates pane grips; sheet transitions update their availability even without terminal output. A new connection explicitly receives the current geometry even if it was already computed while opening the socket.

Card materials use exact point/pixel geometry, background preparation and one shared 30 Hz clock. A missing exact map is still built synchronously rather than stretching an old map. Offscreen cards release their own map references; reusable caches retain the existing 96 MiB/72 GPU and 32 MiB/48 CPU budgets, which are not process-memory limits.

Sidebar lighting precomputes source-texel normals and caches exact panel/region/lamp results (up to 8 entries / 4 MiB). Talisman layers retain their existing particle counts and motion formulas while skipping unchanged static geometry and particle properties.

Drag snapshots capture native text, exact geometry and material uniforms together, then read GPU results off the main thread. Originals remain visible until the whole group is ready. Releasing while capture is pending preserves that release point without consuming events from the next gesture; the release point also determines whether the visual capture contains one card or the group.

Sound file reads and import/reset transactions run on a serial worker; AppKit validation and playback remain on main. Playback copies prepared templates, with an 8-entry / 32 MiB encoded-data cache (not a limit on NSSound's decoded memory). Import keeps the previous choice until validation, copying and safe old-file removal succeed.

Outgoing JSON is encoded by one serial writer. Only adjacent, not-yet-started resize commands are combined; input and request commands remain ordered and retain their completions. There is deliberately no new admission limit: a stalled server can still grow the outgoing queue. macOS sockets report interrupted writes as errors rather than terminating the app with SIGPIPE.

Startup prepares Metal source resources and resolves the herdr executable on workers, then continues on main only after both results arrive. Integration executable providers also run on their existing serial worker; subprocess ordering and installer decisions are unchanged.

Rust still validates the full snapshot schema and preserves unknown optional fields in the original JSON value. The input string and typed validation copy are released before publication, and metadata is serialized directly into its owned byte vector; Swift keeps its required copy of borrowed FFI buffers.

Lamp visibility uses one exact `r32Float` texture per visible card. Its key includes material, pixel geometry and the bit patterns of scene geometry/lamp XYZ; flicker and magic remain dynamic. A miss encodes the unchanged visibility calculation before the final pass in the same command buffer, without a CPU wait. The final shader reads the texel without filtering; hidden cards release this texture.

Do not commit local `.env` files, private keys, or certificate exports containing private keys (`.p12`/`.pfx`): `.gitignore` excludes them, along with builds and caches. Sanitized `.env.example` and `.env.sample` templates remain allowed. Ignore rules do not remove already tracked files or data from Git history.

From the repository root:

```sh
cargo +stable test --locked --workspace
```

Swift checks are standalone drivers, not an Xcode/XCTest project. Updating the extracted protocol is separate from a normal build; the pinned revision and provenance are recorded in [PROVENANCE.json](../crates/herdr-protocol/PROVENANCE.json).

`ConnectionWriterTests` compiles its standalone Rust Unix-server fixture using the release dependencies already produced by `./build.sh`; it does not download dependencies. Drivers with deterministic rendering, worker or audio hooks require `-D TAVERN_RENDER_TESTING`. Before creating material views, drivers await `TavernCardSurfaceView.prepareResources` with a bounded main runloop.

## Optional offline resource preparation

The saved artwork masters are under `resources/Textures/Sources/`, `resources/Textures/TavernVisuals/sources/`, and `resources/Icons/Sources/`. Resource preparation is separate from a normal build and does not call an image-generation service.

- `tools/prepare-{app-icon,button-families,sidebar-cabinet,scroller-material}.py` prepare the icon and active interface textures with Python 3 and Pillow.
- `resources/Textures/TavernVisuals/tools/prepare-selection.py` additionally requires NumPy and writes the three bookmark maps directly to `TavernVisuals/sprites/`.
- `resources/Textures/TavernVisuals/tools/prepare-chained-talismans.py` uses Pillow and writes six RGBA sprites directly to `TavernVisuals/chained/`, with no unused height/material maps or demo previews.

Run a recipe with `python3` and its repository-relative path. Recipes produce images only: JSON manifests are neither required nor written. Masters are read-only unless an explicit chained `--concepts DIR` import is requested; that import copies `talismans-chain-v1.webp` and requires updating source and rights information in [NOTICE](../NOTICE). This notice does not grant redistribution rights.

Recipes do not run during a build. In the checked environment, the bookmark recipe preserves the previous processing but does not reproduce the saved PNGs pixel-for-pixel; visually compare the result before deliberately replacing committed resources.

## README artwork

Header text is rendered with the existing application fonts, not generated as part of the illustration. To regenerate both language versions from the repository root:

```sh
swift tools/render-readme-header.swift
```

This is optional documentation tooling, not part of the application build. It requires the saved `docs/assets/header-art.webp` and the existing fonts in `resources/Fonts/`. Font and reference-resource notices remain applicable; see [NOTICE](../NOTICE).
