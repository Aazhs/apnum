# apnum design

apnum should feel like an app Apple could have shipped with macOS 26: native controls, system type, the user's accent colour and Liquid Glass, with one signature of its own.

## Principles

- **Native first.** `NavigationSplitView`, toolbars, `List`, `Table`, `Form`, sheets, `ContentUnavailableView`, context menus, keyboard shortcuts. If a system component exists, use it before drawing your own.
- **Buttons follow the Clock app** (`Controls.swift`). Actions are wide capsules: `.buttonStyle(.pill)` is the neutral grey one (Cancel, Lap, Reset), `.pill(.green)` starts, `.pill(.orange)` pauses, `.pill(.red)` stops, `.pill(.accentColor)` saves. Quick starts in lists are round: `.buttonStyle(.circle(.green))` with a play symbol. Toolbar buttons stay standard. Do not use `.buttonStyle(.glass)` / `.glassProminent` for buttons inside content: they render as odd grey shapes.
- **Times are entered with `DigitField`** (click a segment and type, arrows, or the chevrons) backed by `DigitEntry`. Never use the graphical clock-face DatePicker.
- **Glass floats, content sits.** Liquid Glass is for the control layer that floats above content: toolbars (automatic), floating bars or banners (`.glassEffect(.regular, in: .capsule)` or `.rect(cornerRadius:)`). Content (lists, text, editors) sits on the plain window background. The exception is Today, which is a dashboard of `GlassPanel`s over a `SkyBackdrop`.
- **The sky is the signature.** It is driven by the real sun altitude (`SkyPalette.forSunAltitude`, aarshj.me's keyframes), drawn as the pixel scene (`PixelSkyView`) on Today and the menu bar glance, and optionally tints the accent colour. `Sky` (in `Theme.swift`) is the older hour-based fallback. It appears only where time-of-day is the subject: Today (backdrop and ribbon), the menu bar glance and the app icon. Do not spread it to other screens.
- **Times are the hero of time screens.** Use `ClockText` / `Font.clock` (SF Pro Rounded, thin or light, monospaced digits) for times and durations, large enough to read across a room on Alarms, Timers and the stopwatch.
- **Quiet everywhere else.** System fonts and semantic colours (`.primary`, `.secondary`, `.tint`, `.red` for overdue or destructive). Calendar and list colours appear only as small dots, bars or checkboxes.

## Avoid

- Grids of identical rounded cards with soft shadows; gradients as decoration.
- ALL-CAPS labels, eyebrow labels above headings, `A · B · C` metadata strings, monospace for ordinary small labels (tool names in Activity are code, so monospace is right there), `→` in button titles.
- Motion that is not a response to the user. Responses (a row completing, a sheet opening, a timer starting) may animate briefly.
- Polling. Live clocks use `TimelineView`, scoped to the text that changes, and only while visible.

## Words

Sentence case, plain verbs, the user's vocabulary. Buttons say what happens ("New alarm", "Start", "Allow access"). Empty states say what to do next. Errors say what happened and how to fix it, without apologising.

## Layout

- Detail pages: content padded 28–36 pt horizontally, readable width (text columns under ~720 pt), left-aligned.
- Screens that mirror an Apple app should feel like that app: Alarms, Stopwatch and Timers follow macOS Clock; Calendar follows macOS Calendar (Day / Week / Month, Today, back and forward); Reminders and Notes follow theirs.
- Page titles go in the toolbar (`.navigationTitle`, `.navigationSubtitle` for a short status), not as big headings in the content. Today is the exception: its date and clock are the content.
- Must look right at the default 1100×740 window and at a narrow 820×560 window, in light and dark mode.

## Checking your work

`scripts/snapshot.sh <section> <out.png> [light|dark] [width] [height]` launches the app in demo mode (sample data, throwaway data folder) in the background, captures only its window and quits. Sections: `today alarms stopwatch timers calendar reminders notes activity glance`, plus `alarms:alarm-editor`. `APNUM_SKY_TIME=18:05` previews the sky at that time. Look at the screenshot, critique it against this document, fix, and capture again.
