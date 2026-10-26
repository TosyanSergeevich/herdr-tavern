# Repository Guidelines

## Project Overview

Herdr Tavern — нативная macOS-оболочка для herdr с оформлением фэнтезийной таверны и настоящим терминалом. Сервер, PTY, процессы и агенты принадлежат herdr; Tavern управляет клиентской проекцией и интерфейсом. Закрытие окна отсоединяет клиент, но не завершает сессию. Закрытие панели/вкладки завершает процессы и требует подтверждения.

`README.md` описывает возможности и ограничения, `docs/SETUP.md` — настройку, сборку и запуск. Не переписывайте историю Git и не переносите каталог без поручения. Исторические отчёты QA не доказывают текущую работоспособность: проверяйте затронутый сценарий на актуальных исходниках.

Сообщения Git-коммитов Tavern — заголовок и тело — всегда пишите на английском языке.

## Architecture & Data Flow

- `TavernDelegate` в `app/main.swift` связывает окно, навигацию, запросы и состояние. `LaunchOptions` и `RustConnection` в `app/Connection.swift` отвечают за запуск/подключение и Swift-сторону FFI.
- Поток данных: herdr → Unix socket → Rust transport/codec → ограниченная очередь `TavernEvent` → C ABI → `NativeEvent` → main queue → AppKit. Метаданные передаются JSON, ячейки и изображения — типизированными сегментами; не сериализуйте всю сетку в JSON.
- `crates/tavern-client/src/{transport,client,event,command}.rs` разделяют IO/framing, handshake и жизненный цикл, преобразование событий и команды. Клиентский endpoint и публичный newline-JSON API — разные интерфейсы; публичные операции использует `publicRequest`.
- Состояние навигации и кадр публикуются согласованно по `boot_id` и revision (`pendingSnapshot`, `publishPendingSnapshot`). Пока новая пара не готова, сохраняйте прежнюю; учитывайте приостановленную поверхность скрытого окна. Patch применим только к соответствующему baseline.
- `SurfaceView` (`app/Surface.swift`) рисует терминал и реализует `NSTextInputClient`; `TerminalInput.swift` нормализует macOS-клавиши. Терминальные последовательности кодирует herdr, не новый локальный кодировщик.
- Декор отделён от терминальной поверхности: `Appearance.swift`, `Materials.swift`, `LivingChrome.swift`, `Motion.swift`. Анимация не должна инвалидировать терминал; сохраняйте Reduce Motion и остановку часов для скрытых/перекрытых окон.

## Key Directories

- `app/` — Swift/AppKit, без Swift Package или Xcode project; сборка включает все `app/*.swift`.
- `crates/herdr-protocol/` — выделенные upstream-типы и кодеки; `src/generated/` не редактировать вручную.
- `crates/tavern-client/` — Rust-клиент (`staticlib` для Swift, `rlib` для Rust).
- `tests/` — самостоятельные Swift regression drivers; Rust-тесты находятся внутри crates.
- `tools/` — ручной импорт протокола, подготовка иконки, кнопок, sidebar и скроллбаров; не часть обычной сборки или запуска.
- `resources/Textures/Sources/` и `resources/Textures/TavernVisuals/sources/` — сохранённые художественные мастера. Runtime PNG лежат в `resources/Textures/` и `TavernVisuals/{materials,sprites,chained}/`; `TavernVisuals/tools/` содержит ручные рецепты закладки и талисманов. `licenses/` и `vendor/crates/` — лицензионные уведомления и закреплённые зависимости.

## Development Commands

Выполняйте из корня:

```sh
./build.sh
open "build/Herdr Tavern.app"
# Изолированная сессия для QA:
"build/Herdr Tavern.app/Contents/MacOS/HerdrTavern" --session tavern-qa
cargo +stable test --locked --workspace
```

При заполненном Cargo-кэше: `CARGO_NET_OFFLINE=true ./build.sh`. Сборка создаёт `target/` и `build/`, статически связывает Rust со Swift, подписывает `.app` постоянным сертификатом `Herdr Tavern Local Signing` из Keychain и проверяет подпись; тесты не запускает. Новый bundle собирается в чистом временном каталоге и заменяет `build/Herdr Tavern.app` только после успешной сборки и проверки подписи. Сертификат и приватный ключ настраиваются один раз по README.md; не пересоздавайте их при обновлении и не заменяйте подпись на ad-hoc: это меняет идентичность для разрешений macOS.

`build.sh` обезличивает пути компилятора через Rust `--remap-path-prefix` и Swift `-file-prefix-map`, а корень архива в Mach-O debug map — через linker `-oso_prefix`. Общие HOME-префиксы идут перед Cargo/Rustup и корнем проекта. Существующие `CARGO_ENCODED_RUSTFLAGS` сохраняются; если они не заданы, `RUSTFLAGS` разбираются по пробельным символам по правилам Cargo. Не возвращайте личные абсолютные пути в ресурсные манифесты; указывайте имена исходных наборов/артефактов или настоящие относительные пути. Проверяйте готовую `.app`, не только исходники; история Git этим не очищается.

Проектного lint-скрипта и конфигурации Swift lint нет. Для изменённого Rust можно использовать стандартные инструменты (не установленный проектом CI gate):

```sh
cargo +stable fmt --all -- --check
cargo +stable clippy --locked --workspace --all-targets
```

## Code Conventions & Common Patterns

- Следуйте стилю соседнего кода: Swift — отступ 4 пробела, типы `UpperCamelCase`, методы/свойства `lowerCamelCase`, `private` для внутреннего состояния, `final class` для контроллеров. Rust — обычный rustfmt-стиль, `snake_case`, `Result<T, String>` в клиентском слое. Не форматируйте посторонние файлы.
- Изменения AppKit и UI-состояния выполняются на main thread. Блокирующие `open/send/publicRequest` — вне main queue; запись сериализована `writer`, чтение — одним worker. Сохраняйте ограниченную передачу событий в UI, не заменяйте её неограниченной очередью full frames.
- Контракт памяти — `include/TavernClient.h`: event buffers borrowed до `tavern_event_free`; строки ошибок/ответов owned и освобождаются `tavern_string_free`. Скопируйте нужные данные до освобождения события. `close` прерывает IO; `free` разрешён только после окончания всех C-вызовов. Swift и `#[repr(C)]` Rust ABI меняйте согласованно.
- Ошибки Swift проходят через `NativeError`/`Result` и показываются пользователю; Rust FFI удерживает panic внутри boundary. Различайте транспортный сбой и серверный `response.error`. Не повторяйте автоматически команды после таймаута или частичной записи: результат операции может быть неизвестен.
- Endpoint-запросы выполняются по одному; ответы проверяются по request ID и `boot_id`. Асинхронные callbacks и действия из меню/диалогов проверяют поколение соединения и существование целевого объекта, а не только сохранённый ID.
- Связи UI задаются callbacks (`send`, `request`, `focusPane`) и передаваемыми зависимостями, без DI-фреймворка. Используйте `[weak self]` для callbacks контроллеров; явное удержание клиента worker-потоком необходимо для его lifetime.
- Навигационные контролы сохраняются по идентификаторам между обновлениями. Непрочитанное (`Unread.swift`) — отдельное состояние, независимое от звуков/разрешения уведомлений; сбрасывается при новом boot и читается только при фактическом показе сфокусированной панели в активном окне.
- Пользовательские строки задаются через `L` и парные каталоги `resources/en.lproj/` и `resources/ru.lproj/` (`Shell`, `Settings`, `Core`, `Installer`). `app/Localization.swift` загружает их один раз, хранит выбор языка и публикует `tavernLanguageDidChange`; меню и виды обновляются без пересоздания терминала. Английский — начальный язык. Не переводите IDs, имена команд, пользовательские данные и вывод терминальных программ; сохраняйте типы/порядок форматных аргументов. `main.swift` синхронизирует язык собственных Rust-диагностик через `tavern_set_language`.

## Important Files

- `build.sh`, `Cargo.toml`, `Cargo.lock`, `app/Info.plist` — сборка, зависимости и bundle.
- `app/main.swift` — entry point и координация; `app/Connection.swift`, `include/TavernClient.h`, `app/BridgingHeader.h` — граница Swift/Rust.
- `app/Surface.swift`, `app/TerminalInput.swift`, `app/TerminalTheme.swift` — рендеринг, ввод и Kanagawa Wave. Размер и насыщенность терминала задаёт `TavernTerminalSettings`; по умолчанию 16 пт/Medium и сетка 8×20 pt. Для другого размера рассчитывайте ячейку по метрикам шрифта с округлением к backing pixels и передавайте ту же геометрию серверу. При смене метрик очищайте кэш глифов и обновляйте границы рисунка; цвет применяется при рисовании.
- `tools/import-protocol/src/main.rs`, `crates/herdr-protocol/PROVENANCE.json` — закреплённая ревизия, происхождение и рецепт импорта. Обновление протокола выполняется вручную из подходящего upstream checkout:

```sh
cargo +stable run --locked -p import-protocol -- /path/to/herdr
```

Новая ревизия требует обновления закреплённой ревизии импортёра и проверки совместимости. Не редактируйте generated-файлы и vendored dependencies как обычный прикладной код.

## Runtime/Tooling Preferences

- macOS 14+, Xcode Command Line Tools (`xcrun swiftc`), Rust `stable`/Cargo. herdr нужен при запуске, но не входит в bundle. При его отсутствии каждый запуск предлагает подтверждённую пользователем загрузку официального закреплённого herdr 0.9.4 с GitHub с проверкой SHA256 в `~/Library/Application Support/HerdrTavern/bin/herdr`; это не `latest` и не обещание совместимости с ним. Не используйте sudo, Homebrew, сетевые shell-скрипты, изменения shell-профилей или автоматическое обновление найденного herdr. Отмена ничего не устанавливает и завершает запуск без сохранения отказа; успешная установка продолжает запуск без ручного перезапуска. Ручная установка остаётся вариантом; неверный явный `--herdr PATH` — ошибка без подмены и предложения установки.
- Cargo с `--locked`; сборка для архитектуры текущей машины. Node/Bun, Python-мост и скачивание upstream herdr для обычной сборки не нужны.
- Все поставляемые шрифты включены в `resources/Fonts/` и копируются `build.sh` в `.app` без скачивания и чтения локальных каталогов шрифтов; ручная установка не нужна. При запуске `TerminalFonts` загружает Iosevka Custom 34.9.0 (девять весов Thin…Heavy с настоящими Oblique) и `SymbolsNerdFont-Regular.ttf` из ресурсов через CGFont/CoreText. Пользователю доступны восемь весов Thin…ExtraBold; Heavy оставлен для ANSI bold при ExtraBold, а при Bold выделение использует ExtraBold. Для меньших основных весов выделение использует Bold. Исходные CGFont удерживаются для смены размера/веса без файлового IO. Уважайте выбранные пользователем размер/вес и не заменяйте Oblique на Italic. Декоративные шрифты также загружаются из `.app`; Menlo и emoji fallback остаются системными. Отсутствующий обязательный ресурс не заменяйте молча. Iosevka Custom распространяется по SIL OFL 1.1 (`licenses/IosevkaCustom.txt`, справочный перевод `licenses/IosevkaCustom.ru.txt`), не по Apache проекта. Права на распространение FrizQuadrataC/MorpheusAlt1Cyr пока не подтверждены (`licenses/InterfaceFonts.txt`).
- Не подменяйте HOME и пользовательскую конфигурацию. `--socket PATH` означает клиентский socket без автозапуска; stale socket автоматически не удаляется.
- Обычная сборка копирует явно перечисленные готовые runtime PNG и не запускает художественные генераторы. Мастера и рецепты не включаются в `.app`; графические JSON-манифесты не хранятся и не генерируются. `tools/prepare-{app-icon,button-families,sidebar-cabinet,scroller-material}.py` — необязательные локальные утилиты на Python 3 + Pillow. `resources/Textures/TavernVisuals/tools/prepare-selection.py` дополнительно требует NumPy и готовит три карты закладки в `sprites/`; `prepare-chained-talismans.py` готовит только шесть RGBA PNG в `chained/`.
- Рецепты читают сохранённые мастера и записывают только готовые изображения. Только явный `prepare-chained-talismans.py --concepts DIR` заменяет мастер талисманов; при таком импорте отдельно актуализируйте сведения об источниках и правах в `NOTICE`. Не возвращайте удалённые концепты, демо и журналы генерации; сохраняйте оставшиеся художественные источники и лицензионные уведомления.

## Testing & QA

Rust использует `#[test]`: wire safety, handshake, patch/baseline, лимиты, deadlines, shutdown и настоящие локальные Unix-сокеты с тестовым сервером. Установленный herdr для этих тестов не нужен. Swift drivers используют `@main` и `precondition`, не XCTest; не добавляйте `-Ounchecked`, отключающий эти проверки.

```sh
check_dir="$(mktemp -d)"
xcrun swiftc -target "$(uname -m)-apple-macosx14.0" app/Localization.swift app/Unread.swift tests/UnreadTests.swift -o "$check_dir/unread-tests"
"$check_dir/unread-tests"
xcrun swiftc -target "$(uname -m)-apple-macosx14.0" app/TerminalInput.swift tests/TerminalInputTests.swift -o "$check_dir/input-tests"
"$check_dir/input-tests"
rm "$check_dir/unread-tests" "$check_dir/input-tests"
rmdir "$check_dir"
```

Swift-драйверам, использующим локализованные типы, нужен `app/Localization.swift` в списке исходников. Для фактического вызова `L` запускайте драйвер из отдельной `.app` с `en.lproj` и `ru.lproj` в `Contents/Resources/`; отсутствие/несовпадение обязательных каталогов — ошибка упаковки. `tests/LocalizationTests.swift` проверяет сохранение выбора с отдельным UserDefaults suite и принимает путь к собранной `.app` аргументом. Не возвращайте в README журналы QA и личные пути: `README.md` — краткая английская входная страница, `README.ru.md` — её русская пара.

`DialogMenuTests` также рисует настоящую `TavernButton`: тестовой `.app` нужен полный `Contents/Resources/` штатной сборки, не только каталоги переводов. Компилируйте драйвер с явным macOS target и запускайте его бинарник напрямую; не считайте нулевой код `open -W` подтверждением прохождения — проверяйте итог самого драйвера.

Драйверам с `SurfaceView` также нужен `app/TerminalFonts.swift`. `TerminalFontsTests` и `SurfaceGlyphTests` принимают путь к собранной `.app` первым аргументом; первый проверяет начертания, моноширинную сетку и отказ при отсутствующем/повреждённом ресурсе. Сам драйвер должен иметь доступ к каталогам переводов, как описано выше; установка Iosevka в macOS для этих проверок не нужна.

Покрывайте изменённое поведение и границы именованными сценариями; численного coverage gate нет. Swift input driver требует macOS/AppKit. Для изменений ABI/протокола проверяйте Rust-тесты и сборку `.app`; для UI сборки недостаточно — запускайте финальное приложение и проверяйте изменённый путь в изолированной сессии herdr.

Для пути отсутствующего herdr проверяйте предложение при каждом запуске, отмену без установки и запоминания отказа, подтверждённую загрузку закреплённого релиза с проверкой SHA256 и продолжение запуска после установки. Проверяйте ошибки загрузки/контрольной суммы без установки, использование уже найденного herdr без загрузки/обновления и неверный явный `--herdr PATH` без подмены. Используйте изолированные окружение и каталог назначения, не удаляйте и не меняйте пользовательский herdr ради проверки отсутствующей зависимости; тесты не должны требовать сетевой загрузки или установленного herdr.

Релевантные ручные сценарии: кириллица и сочетания клавиш, paste/выделение, split и переключение вкладок, компактное окно/длинные имена/scrollbars, reconnect и сохранение процессов после закрытия окна. Не завершайте пользовательские процессы и не отправляйте запросы модели ради UI QA. При проверке настроек используйте отдельный UserDefaults suite; временные диагностические драйверы не включайте в продукт. В отчёте различайте автоматические тесты, синтетические события, реально просмотренный UI и непроверенные сценарии.
