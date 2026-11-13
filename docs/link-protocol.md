# apnum link protocol (v1)

How the Mac app and the Android companion talk. One paired phone and one Mac exchange tool calls and events over an encrypted channel on the local network. No cloud, no account.

## Roles

- **Mac**: server. Listens for WebSocket connections and advertises itself with Bonjour.
- **Phone**: client. Finds the Mac, connects, and reconnects whenever the network changes.

Once connected the channel is symmetric: either side can call the other's tools and send events.

## Discovery and transport

- Bonjour service type `_apnum._tcp`, instance name = the Mac's name, TXT record `v=1`, `id=<mac device id>`.
- The Mac listens on TCP port **47800** (falls back to any free port; the real port is in the Bonjour record and the pairing QR).
- Transport: WebSocket, path `/link`, **binary** messages only. No TLS: confidentiality and authentication come from Noise (below).
- The phone remembers the last host and port and tries them first, then Bonjour, then asks for a manual address.
- Works on any network where the two devices can reach each other, including the phone's own hotspot.

## Security: Noise XX

All cryptography lives in the shared Rust crate `rust/apnum-link` (built with the `snow` crate, exposed to Swift and Kotlin through UniFFI).

- Pattern: `Noise_XX_25519_ChaChaPoly_BLAKE2s`. The phone is the initiator, the Mac the responder.
- Each device has a long-lived static X25519 key pair, created on first launch. The Mac keeps its private key in the Keychain, the phone in the Android Keystore-encrypted preferences.
- Handshake: three WebSocket binary messages (→ e; ← e, ee, s, es; → s, se), with empty payloads.
- After the handshake every WebSocket binary message is one **sealed message**: the plaintext is split into chunks of at most 65,000 bytes, each chunk is encrypted as one Noise transport message, and the output is the concatenation of `[u16 big-endian ciphertext length][ciphertext]` for each chunk. An empty plaintext is one empty chunk.
- A device **must close the connection** if the peer's static key is not the one it paired with (except during pairing).

### Pairing

1. On the Mac the user opens *Phone › Pair a phone*. The Mac creates a one-time **pairing token** (16 random bytes, valid 5 minutes, single use) and shows:
   - a QR code containing `apnum://pair?v=1&host=<ip>&port=<port>&pk=<mac static public key, base64url>&token=<base64url>&name=<Mac name, url-encoded>`
   - the same link as text, and an 8-digit **pairing code** (the first 8 decimal digits derived from the token, see `pairing_code`) for typing by hand.
2. The phone scans the QR (or finds the Mac by Bonjour / manual address and the user types the 8-digit code).
3. The phone connects and completes the Noise handshake.
   - QR path: the phone checks the Mac's static key equals `pk`. If not, it aborts.
   - Code path: the phone does not know `pk` yet. Both screens show a 6-digit **safety number** derived from the handshake hash (`safety_number`); the user confirms they match on the phone.
4. The phone's first sealed message is `{"t":"pair","token":"<base64url token or 8-digit code>","device":{…}}`.
5. The Mac checks the token (or code), stores the phone's static public key and device info, replies `{"t":"paired","ok":true,"device":{…mac…}}`, and both continue with `hello`. On a wrong token: `{"t":"paired","ok":false,"error":"…"}` and close. Five wrong attempts cancel the pairing session.
6. The phone stores the Mac's static key, id, name, host and port.

Only one phone is paired at a time in v1; pairing a new phone replaces the old one after the user confirms on the Mac. *Unpair* on either side deletes the stored key.

### Reconnecting

Same handshake. Each side checks the peer's static key against the stored one, then both send `hello`.

## Messages

Sealed message plaintext is one UTF-8 JSON object with a `t` field.

| `t` | Direction | Fields |
|---|---|---|
| `pair` | phone → Mac | `token`, `device` |
| `paired` | Mac → phone | `ok`, `device` or `error` |
| `hello` | both | `v` (1), `device`, `tools` (array of tool descriptors) |
| `tools` | both | `tools` (replaces the peer's tool list, e.g. after a permission is granted) |
| `call` | both | `id` (number, unique per sender), `tool`, `input` (object) |
| `result` | both | `id`, `ok`, then `output` (any JSON) or `error` `{code, message}` |
| `event` | both | `topic` (string), `data` (object) |
| `ping` / `pong` | both | none; send `ping` every 20 s when idle, drop the link after 45 s of silence |
| `bye` | both | `reason`; sent before a deliberate close (e.g. unpair) |

`device`: `{"id":"<uuid>","name":"moto g86 power","kind":"android"|"mac","app":"0.1.0","os":"Android 16"}`

Tool descriptor: `{"name":"phone.sms.send","summary":"…","tier":"read"|"write"|"dangerous","inputSchema":{…JSON Schema…}}` — the same shape as `ToolDescriptor` in `ApnumCore`.

Error codes: `notFound`, `invalidInput`, `denied`, `unavailable`, `failed` (the cases of `ToolError`).

Calls time out after 30 s (`unavailable`). Unknown `t` values are ignored. Unknown fields are ignored.

## Tools

- **Mac tools** keep their names (`alarm.create`, `mac.volume.set`, …). Calls from the phone run as caller `phone:<device name>` through the Mac's `ToolRegistry`, so the permission policy and audit log apply. Dangerous tools are denied unless the user has turned on *Allow this phone to run dangerous actions* for the paired device on the Mac.
- **Phone tools** all start with `phone.`. While a phone is connected the Mac adds them to its registry, so the UI and agents call them like any other tool.

### Phone tools (v1)

| Tool | Tier | What it does |
|---|---|---|
| `phone.info` | read | Model, Android version, battery percent and charging state, network name |
| `phone.sms.list` | read | Recent SMS (`limit`, optional `address`, `sinceMs`), newest first: `id`, `address`, `contactName`, `body`, `dateMs`, `incoming` |
| `phone.sms.send` | dangerous | Send an SMS (`to`, `body`) |
| `phone.otp.latest` | read | The most recent one-time code found in an SMS in the last 10 minutes: `code`, `from`, `body`, `dateMs` |
| `phone.notifications.list` | read | Active notifications: `key`, `app`, `title`, `text`, `postedMs` |
| `phone.notifications.dismiss` | write | Dismiss one by `key` |
| `phone.call.dial` | dangerous | Start a phone call to `number` |
| `phone.call.end` | write | End the current call or reject the ringing one |
| `phone.call.state` | read | `idle`, `ringing` or `offhook`, with `number` when known |
| `phone.contacts.search` | read | Contacts matching `query`: `name`, `numbers` |
| `phone.clipboard.get` / `phone.clipboard.set` | read / write | Plain text |
| `phone.ring` | write | Ring loudly for 30 s even on silent, to find the phone (`stop: true` stops it) |

A tool whose Android permission has not been granted is still listed; calling it returns `unavailable` with a message naming the permission.

### Events

| Topic | From | Data |
|---|---|---|
| `sms.received` | phone | `address`, `contactName`, `body`, `dateMs`, `otp` (the code, when one is detected) |
| `notification.posted` / `notification.removed` | phone | `key`, `app`, `title`, `text`, `postedMs` |
| `call.state` | phone | `state`, `number`, `contactName` |
| `battery` | phone | `percent`, `charging` (sent when either changes by a step: every 5%, or on plug/unplug) |
| `changed` | Mac | `topic` (a `ChangeFeed` topic such as `alarms`, `timers`, `notes`) |
| `ringing` | Mac | `items` (alarms and timers ringing on the Mac) |

## Shared Rust crate: `rust/apnum-link`

Exposed through UniFFI (names in the generated Swift/Kotlin follow each language's style):

```
struct KeyPair { private_key: bytes(32), public_key: bytes(32) }
fn generate_keypair() -> KeyPair
fn public_key_for(private_key) -> bytes

object Handshake
    constructor initiator(local_private_key)      // phone
    constructor responder(local_private_key)      // Mac
    fn write_message() -> bytes                   // next handshake message to send
    fn read_message(message)                      // feed a received handshake message
    fn is_finished() -> bool
    fn remote_public_key() -> bytes?              // known once the peer's static key has arrived
    fn handshake_hash() -> bytes                  // valid when finished
    fn into_session() -> Session                  // valid when finished; consumes the handshake

object Session                                    // thread-safe
    fn seal(plaintext) -> bytes                   // chunk + encrypt, format above
    fn open(sealed) -> bytes                      // decrypt + join; error on any tampering

fn pairing_token() -> bytes(16)
fn pairing_code(token) -> String                  // 8 decimal digits, BLAKE2s(token) based
fn safety_number(handshake_hash) -> String        // 6 decimal digits
fn fingerprint(public_key) -> String              // "4F2A 91C0 7B3E 55D1"
fn make_pair_uri(host, port, public_key, token, name) -> String
fn parse_pair_uri(uri) -> PairInfo { host, port, public_key, token, name }   // error if malformed or v != 1

enum LinkError { Handshake(msg), Crypto(msg), Format(msg) }
```

Everything else (WebSocket, JSON, tools, storage) is native code on each side.

## Sync (v1.1): alarms and notes on both devices

Alarms and notes live on both devices so they work when the other is away. The Mac is the hub; the phone keeps a local copy and merges.

- Records carry `id` (UUID string), `updatedAt` and `deletedAt` (ISO-8601, UTC). Deleting sets `deletedAt` (a tombstone); nothing is removed.
- Merge rule on both sides: for each `id` keep the record with the later `updatedAt` (ties: the incoming record wins on the Mac, the local one wins on the phone, so both end up with the Mac's copy).
- The phone syncs on connect, after every local edit while connected, and whenever the Mac sends `changed` with topic `alarms` or `notes`. Edits made offline are pushed at the next connect.

### Mac tools

| Tool | Tier | Input | Output |
|---|---|---|---|
| `alarm.sync` | write | `records` (array of alarms, may be empty), `since` (ISO date, optional) | `records`: every alarm, tombstones included, whose `updatedAt` is later than `since` (all when `since` is absent) after merging; `serverTime` |
| `note.sync` | write | `records` (array of notes), `since` | same shape for notes |

The phone stores `serverTime` and sends it as the next `since`.

Alarm record (same JSON as `alarm.list` items, plus tombstones): `id`, `hour` (0-23), `minute`, `label`, `repeatDays` (lowercase weekday names), `isEnabled`, `snoozeMinutes`, `sound` (optional), `createdAt`, `updatedAt`, `deletedAt` (optional). `snoozedUntil` and `lastFiredAt` are per-device and are not synced.

Note record: `id`, `title`, `body`, `tags` (array), `pinned`, `createdAt`, `updatedAt`, `deletedAt` (optional).

### Ringing on both devices

An alarm rings on the Mac and on the phone. Stopping or snoozing on one silences the other:

- The Mac sends event `ringing` with `items`: `[{"id","kind":"alarm"|"timer","title","body","canSnooze"}]` whenever its set of ringing items changes (an empty array when nothing rings).
- When the user stops or snoozes on the phone, the phone calls `alarm.stop` / `alarm.snooze` (or `timer.stop`) on the Mac with that `id`.
- When a `ringing` event no longer lists an alarm the phone is ringing, the phone stops ringing it. If the phone is offline it simply rings on its own.
- The phone sends event `phone.ringing` with `ids` (alarm ids it is ringing) so the Mac can show it; the Mac does not need to act on it.

## Additions (v1.2)

### New phone tools

| Tool | Tier | What it does |
|---|---|---|
| `phone.calls.recent` | read | Recent calls from the call log (`limit`, default 20), newest first: `number`, `contactName`, `type` (`incoming`, `outgoing`, `missed`), `dateMs`, `durationSec`. Needs the call-log permission. |
| `phone.notifications.clear` | write | Dismisses every clearable notification. Returns `cleared` (count). |

`phone.ring` returns `{"ringing": true, "seconds": 30}` when it starts and `{"ringing": false}` after `stop: true`; the phone also sends event `ring` with `active` (bool) when ringing starts and ends, so the Mac can show a Stop button for exactly as long as it rings.

`phone.sms.send`: `to` must be a dialable number (digits with optional leading `+`, spaces, dashes and brackets, which the phone strips). Alphanumeric sender IDs such as `JD-GROWWO-S` cannot be replied to; the Mac disables the reply field for them.

`phone.contacts.search` results are `{name, numbers: [string]}`; the Mac calls it as the user types (debounced) to suggest contacts.

### Messages are pushed, not polled

On Android 17 the broadcast can be withheld from apps targeting 37 (apnum targets 36). As a fallback the notification listener runs the same code extractor on notifications from the default SMS app and known messaging apps and sends the same event (`address` = notification title, `body` = text), unless the same code was already reported within 2 minutes.

`sms.received` must be sent the moment the SMS broadcast arrives (a manifest-registered receiver that hands the message to the running link service, starting it if needed). The Mac inserts the message into its list, shows the code and copies it immediately on that event; it never waits for a refresh. Target: under one second from the SMS arriving on the phone to the code being on the Mac's clipboard.

### Clipboard sync

When *Sync clipboard* is on (a Mac setting, default on), plain text copied on one device appears on the other.

- Event `clipboard` in both directions: `text` (plain text, at most 100,000 characters), `id` (a random string for this copy).
- **Mac → phone:** the Mac sends the event when its pasteboard changes. It never sends items marked concealed or transient by password managers (`org.nspasteboard.ConcealedType`, `org.nspasteboard.TransientType`), and never non-text content. The phone sets its clipboard on receipt.
- **Phone → Mac:** Android only lets an app read the clipboard while it is in the foreground. The phone sends the event when apnum is open and the clipboard changes, and from a one-tap *Send clipboard to Mac* action (a Quick Settings tile and a notification action, which briefly bring a transparent activity to the front to read it). The Mac sets its pasteboard on receipt.
- **Automatic phone → Mac (opt-in):** with the setting *Send what I copy to my Mac automatically* on and the "apnum clipboard" Accessibility service enabled, the phone notices a copy (the system clipboard preview, or a click on Copy / Cut), takes focus for a few milliseconds with a 1x1 transparent accessibility overlay, reads the clip and sends the same `clipboard` event. It skips clips marked sensitive, text over 100,000 characters and text that came from the Mac. If the overlay gets no focus within 500 ms it falls back to the transparent activity.
- Loop prevention: each side remembers the last text it received from the peer and does not echo it back.
