# apnum

A lightweight, open-source macOS menu bar hub for one person's day: alarms, timers, notes, calendar, reminders and Mac controls, built from the start so AI agents can use every feature as a tool.

An Android companion app will follow, bringing the phone's SMS, OTPs, calls, notifications, files, WhatsApp and screen to the Mac, and letting the phone control the Mac in return.

> **Status:** early development. The Mac menu bar app works (alarms, timers, notes, calendar, reminders, Mac controls, 50 tools); the phone link and agent access come next.

## Features

| Area | Mac app | Phone (planned) |
|---|---|---|
| Alarms | apnum's own alarm clock; optional mirror into the macOS Clock app via Shortcuts | Full alarm clock in the companion app, synced both ways |
| Timers | Countdown timers and a stopwatch | Synced |
| Notes | Markdown files you own, with tags and search | Notes screen in the companion app, synced |
| Calendar and Reminders | Your real Apple Calendar and Reminders (iCloud, Google and other accounts included) | Through the same Google account |
| Mac control | Volume, media keys, clipboard, lock, sleep, battery, open apps, run Shortcuts | Control the Mac from the phone |
| Phone | — | SMS, OTP, call control, notifications, files, WhatsApp, screen mirroring (scrcpy) |
| Agents | Every feature is a tool with a JSON schema | MCP server for Claude Code |

## Design

- **Every action is a tool.** The UI, AI agents and the phone all call the same `ToolRegistry`, so they share one permission policy and one audit log. Adding MCP later is a thin adapter.
- **Permission tiers.** Tools are `read`, `write` or `dangerous`. Agents and the phone cannot run dangerous tools without approval on the Mac.
- **Private by default.** Data stays on your Mac under `~/Library/Application Support/apnum`. The audit log never records tool inputs or outputs.
- **Lightweight.** Native Swift, no third-party dependencies, no polling: the app sleeps until the next alarm or timer is due. Target: 0% idle CPU, under 30 MB memory.

See [CLAUDE.md](CLAUDE.md) for the architecture and contributor conventions.

## Build

Requires macOS 15 or later and Xcode.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # if xcode-select points at the Command Line Tools
swift test
scripts/bundle.sh          # creates build/Apnum.app
open build/Apnum.app
```

Set `APNUM_SIGN_IDENTITY` to a code-signing identity to keep macOS permission grants across rebuilds.

On first launch apnum asks for notification permission. Calendar and Reminders access is requested from the Agenda tab, and media keys need Accessibility access (Settings shows how).

Data lives in `~/Library/Application Support/apnum` (`APNUM_HOME` overrides it): `alarms.json`, `timers.json`, `notes/*.md` and `audit.jsonl`.

## Mirroring alarms into the Clock app

Optional. See [docs/clock-shortcuts.md](docs/clock-shortcuts.md).

## Roadmap

1. Mac core: alarms, timers, notes, calendar, reminders, Mac control *(done, being polished)*
2. Android companion and encrypted Wi-Fi pairing: SMS, OTP, call control, notifications, alarms, notes
3. Phone files and screen mirroring
4. WhatsApp bridge
5. Agent access over MCP with approval prompts on the Mac

## License

[MIT](LICENSE)
