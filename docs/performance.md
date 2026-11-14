# Performance

apnum should cost nothing while idle. The sky follows the real time on its own; there is no manual time control (a time-travel slider existed briefly and was removed as unnecessary complexity).

## Measuring

```sh
scripts/perf.sh [seconds]   # builds the release app, runs throwaway demo copies, prints a table, exits 1 over budget
```

Each state is a separate demo copy (`APNUM_DEMO=1`, its own `APNUM_HOME`), so your real data and running app are untouched.
Debug switches (environment variables, all off by default):

| Variable | Effect |
| --- | --- |
| `APNUM_PERF=1` | One stderr line per slow operation (`perf scene 2.31 ms`, `perf bake`, `perf frame`; also os_signpost spans for Instruments) and a per-second counter line (`perf per-second applied=29 scrub-set=29`). |
| `APNUM_SKY_ALWAYS=1` | Keeps the pixel scene animating even when the window is not key (needed to measure a visible Today in the background). |

Settings › About › Diagnostics shows live memory and CPU of the app; it samples every 2 s and only while that tab is on screen.

## Budgets

Read by `scripts/perf.sh`. CPU is percent of one core. "unfocused" is the Today window open but not key (the scene is paused); the
demo data has a running timer, which redraws once a second.

```budgets
today_idle_cpu 8
today_unfocused_cpu 3
other_idle_cpu 1
hidden_cpu 3
memory_mb 80
```

## Results (release build, Apple silicon, 10 s per state)

| State | Before | After |
| --- | --- | --- |
| Today visible, animated, idle | n/m | 3.8% |
| Today, window not key | n/m | 1.8% |
| Another section, idle | n/m | 0.4% |
| Memory footprint, Today | 73 MB | 54 MB idle |

Per operation (APNUM_PERF=1, main-actor view of one scrub tick):

| Operation | Before | After |
| --- | --- | --- |
| `SkyEngine.scene()` | 0.5-1.4 ms | 0.5-1.4 ms (already cheap: unit vectors are precomputed) |
| `summary()` (sunrise/sunset search) | recomputed every tick | once per day and place (cached) |
| `dayColors()` | recomputed every tick | once per day and place (cached) |
| Pixel bake | 1.0 ms hero + 0.55 ms sidebar, every tick | 1.0 ms hero only; the sidebar follows the live sky |
| Pixel frame | under 1 ms | under 1 ms |

## What was slow, and what fixed it

Measuring showed the astronomy and the renderer were never the problem (about 2 ms per tick together). The main thread was saturated by SwiftUI:

(Items 1, 2 and 4 are history: they concerned the time-travel slider, which has since been removed.)

1. **Stepped slider.** `Slider(step: 5)` over 1,440 minutes draws and lays out 288 tick marks and labels on every change. Now the slider is continuous and the value is snapped to 5 minutes in `onChange`.
2. **Whole-window invalidation.** `model.skyScene` also drove the window theme, the sidebar still and every view that read it, so each tick re-evaluated and re-laid-out the whole window, and re-baked a second pixel scene. The live sky (`skyScene`) now never changes while scrubbing; the preview lives in `previewScene` and `previewSummary`, read only by the Today hero, which is split into small views (scene, clock, readout) that each read only what they show.
3. **Deep comparison of scenes.** SwiftUI compared the ~3,000-element star and Milky Way arrays field by field on every update. `SkyScene` now has a cheap `Equatable` (time, place, weather, palette, sun, moon, counts).
4. **Uncoalesced updates.** Each slider change started its own `Task`. One worker now keeps only the newest requested time, computes the scene and summary in `SkyService` (off the main actor) and applies at most one result every 16 ms.
5. **Repeated daily work.** Sunrise/sunset crossings and the day colour ribbon are cached per (day, place) in `SkyCache`.

Hover over the scene only updates the renderer's pointer state and the overlay labels in AppKit; it never touches SwiftUI state. Idle CPU with the window open is 0% in a sample.

Not improved: memory is about 54 MB at rest, above the original 30 MB goal. Of the roughly 32 MB heap, nearly all is SwiftUI, AppKit and SF Symbol data; apnum's own buffers are a few MB.
