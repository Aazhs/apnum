# apnum for Android

The phone side of apnum. It pairs with the Mac app, brings SMS, one-time codes, calls and notifications to the Mac, and lets the phone control the Mac. The protocol is in [docs/link-protocol.md](../docs/link-protocol.md).

## Build

You need Android Studio (its bundled JDK is fine) and the Rust toolchain.

```sh
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
export ANDROID_HOME="$HOME/Library/Android/sdk"

scripts/build-rust.sh android      # once: builds libapnum_link.so into app/src/main/jniLibs
cd android
./gradlew assembleDebug            # app/build/outputs/apk/debug/app-debug.apk
./gradlew testDebugUnitTest        # JVM unit tests
./gradlew installDebug             # to a connected phone or emulator
```

If the `.so` files are missing, Gradle stops with a message telling you to run `scripts/build-rust.sh android`.

Versions: Gradle 9.9.1, Android Gradle Plugin 9.5.1, Kotlin 2.4.21, Compose BOM 2026.09.00, compileSdk and targetSdk 37, minSdk 28.

## Architecture

Package `dev.apnum.android`.

- `link/` the link core, with no UI. `LinkClient` opens a WebSocket (OkHttp), runs Noise XX as initiator through the Rust bindings (`uniffi.apnum_link`), pairs, reconnects with backoff (1 s to 30 s, and on network changes), and exposes `StateFlow`s for the connection, the Mac and its tool list. `ToolRegistry` holds the phone tools and checks Android permissions before each call. `Messages` builds and parses the JSON messages. `PairUri` parses `apnum://pair` links. `Storage` keeps the device key (encrypted with an Android Keystore key) and the paired Mac.
- `sync/` records (`AlarmRecord`, `NoteRecord`) and their JSON codecs in the Mac's exact format (UTC whole-second dates, upper-case UUIDs, tombstones), `SyncStore` (a small JSON file with the records, the Mac's last `serverTime` and the ids edited since the last sync), `RecordSync` (one `alarm.sync` / `note.sync` round against a `MacCaller`) and `SyncCoordinator` (when to sync: on connect, after edits, on the Mac's `changed` event, retry on failure).
- `alarm/` the alarm clock: `AlarmLogic` (next ring with java.time, DST-safe), `AlarmRepository`, `AlarmScheduler` (`AlarmManager.setAlarmClock`, rescheduled by `AlarmRescheduleReceiver` on boot, update, time and zone change), `AlarmController` (ringing state, coordination with the Mac through `alarm.stop`, `alarm.snooze`, the `ringing` and `phone.ringing` events), `RingService` and `RingActivity` (sound on the alarm stream with rising volume, vibration, full-screen over the lock screen).
- `notes/` `NoteRepository`: create, autosave, delete (tombstone), search and tags.
- `phone/` the phone tools and events: SMS and one-time code extraction (`Otp`), notifications (`ApnumNotificationListener`), calls, contacts, clipboard, ringing, and the battery and call monitors.
- `LinkService` is the foreground service (type `connectedDevice`) that keeps the process and the link alive. `BootReceiver` starts it after a reboot when a Mac is paired. The shared objects live in `AppGraph`, held by `ApnumApp`.
- `sky/` ports `SkyPalette.forSunAltitude` and the sun altitude from the Mac app. The Material 3 theme follows the sun at the Mac's location (Pune until the Mac says otherwise).
- `ui/` Compose screens with a bottom bar: Home (Mac remote and timers), Alarms, Notes, Phone (permissions), Settings; plus pairing.

Every Mac action in the UI goes through `LinkClient.callMac("tool.name", json)`, the same path agents use on the Mac side.

## Try it without a Mac

Debug builds accept extras that fake a paired home screen and jump to a tab:

```sh
adb shell am start -n dev.apnum.android/.MainActivity --ez demo true --es tab home
```

Other debug extras: `--ei alarm_in 2` adds an alarm two minutes from now, `--es note_title Hello` adds a note.

`scripts/e2e-emulator.sh <workdir>` pairs the emulator with a throwaway demo Mac instance (use a fresh workdir each time; `E2E_BOGUS_FIRST=1` opens a bad link first to test that a failed pairing does not poison the next one). The Mac's `<workdir>/home/audit.jsonl` lists every tool the phone called, `alarms.json` and `notes/` show what synced.

Pair with a link from the Mac (or any `apnum://pair?...` link):

```sh
adb shell am start -a android.intent.action.VIEW -d "apnum://pair?v=1&host=192.168.1.20&port=47800&pk=...&token=...&name=Mac"
```

The app never logs message bodies, codes or keys, and it talks to nothing except the Mac.
