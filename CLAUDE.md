# apnum

A personal macOS hub (alarms, timers, notes, calendar, reminders, Mac control) that will later bridge to an Android phone and expose every capability to AI agents over MCP. MIT licensed.

## Build and test

Xcode is installed but `xcode-select` still points at the Command Line Tools, so always prefix Swift commands:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build                          # everything
swift build --target ApnumAlarms     # one module
swift test --filter ApnumAlarmsTests # one module's tests
scripts/bundle.sh                    # builds build/Apnum.app (needed for Calendar/notification permissions)
scripts/snapshot.sh notes out.png dark   # screenshot one screen in demo mode, in the background
```

## Architecture

- `ApnumCore` — no AppKit/SwiftUI. Tool protocol, `ToolRegistry`, `PermissionPolicy`, `AuditLog`, `ChangeFeed`, `JSONFileStore`, `AppPaths`, `SyncRecord`, `WakeScheduler`, and platform protocols (`Ringer`, `ShortcutRunning`).
- Feature modules depend only on `ApnumCore`, never on each other: `ApnumAlarms`, `ApnumTimers`, `ApnumNotes`, `ApnumCalendar`, `ApnumSystem`.
- `ApnumApp` — the SwiftUI app (a main window with a sidebar of `AppSection`s, a menu bar glance and Settings) and the composition root. `AppModel` builds every service, collects their tools into one `ToolRegistry`, drives alarms and timers with one `WakeScheduler`, and keeps main-actor snapshots for SwiftUI. Views perform every change with `model.run("tool.name", jsonInput)`, the same JSON path agents and the phone use.

The rule that makes agents easy later: **every action is a `Tool`**. The UI may read service state directly for display, but anything that changes state goes through the registry, so the UI, agents and the phone all get the same permissions and audit trail.

## UI

Follow [docs/design.md](docs/design.md): native macOS 26 controls, Liquid Glass only on the floating control layer, the sky palette only where time of day is the subject. Shared pieces live in `Sources/ApnumApp/Theme.swift`. Check every UI change with `scripts/snapshot.sh` in light and dark mode.

## Conventions

- Swift 6 language mode, strict concurrency. Services are `actor`s or `@MainActor` classes; models are `Sendable` value types.
- Each feature module exposes: models, a service, a `Tools.swift` with one `Tool` struct per action, and a `public func makeTools() -> [AnyTool]` on the service (or a free function) returning all of them.
- Tool names: `domain.verb` or `domain.noun.verb`, lowercase (`alarm.create`, `mac.volume.set`). Summaries are one plain sentence an agent can act on. `inputSchema` must match `Input` exactly.
- Pick the tier honestly: `read` (no changes), `write` (local, reversible), `dangerous` (outward-facing, destructive or hard to undo).
- Records that will sync to the phone conform to `SyncRecord` (UUID id, `updatedAt`, `deletedAt` tombstone). Never hard-delete them.
- Services publish to the shared `ChangeFeed` after every change.
- Time-based services expose `tick(now: Date)` and `nextWakeDate(after: Date) -> Date?`, and are driven by `WakeScheduler`, which sleeps until something is due (no polling). Tests pass fixed dates instead of sleeping.
- Lightweight is a goal: no polling loops, no third-party dependencies in the Mac app, idle CPU 0% and memory under 30 MB.
- Persist with `JSONFileStore` or plain files under `AppPaths`. Tests use `AppPaths.temporary()`.
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`). Do not test against the real Calendar, Shortcuts or system volume; put those behind a protocol and test the logic with a fake.
- No third-party dependencies without discussing it first. Anything borrowed must be MIT/Apache/BSD compatible.
- Never log tool inputs or outputs; they can contain private data.

## Language choices

Swift for the Mac app, Kotlin for the Android companion. Rust is reserved for code that both apps must share once the phone link exists (sync protocol, pairing, encryption), exposed to Swift and Kotlin through UniFFI. Do not add Rust to the Mac-only features.
