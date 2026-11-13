# Setting up your phone

How to put the apnum app on your Android phone and connect it to your Mac. Written for a Moto G86 Power on Android 16, but the steps are similar on any recent Android.

## 1. Install the app

Pick one.

**Android Studio.** Open the `android` folder, plug in the phone with USB (or use wireless debugging), pick the phone at the top, and press Run.

**Command line.** On the phone, turn on Developer options (Settings, About phone, tap Build number seven times), then turn on USB debugging. Plug it in, accept the prompt on the phone, and run:

```sh
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
scripts/build-rust.sh android
cd android && ./gradlew installDebug
```

For wireless debugging, turn it on in Developer options, tap Pair device with pairing code, and run `adb pair <address>` and then `adb connect <address>` on the Mac first.

**Copy the APK.** Build it with `./gradlew assembleDebug`, then copy `android/app/build/outputs/apk/debug/app-debug.apk` to the phone (AirDrop does not work with Android, so use USB file transfer, a cloud drive or `adb push`). Open it on the phone and allow installs from that app when asked.

## 2. Give it permissions

Open apnum and go to Permissions. Each row says what it is for.

| Permission | Why |
|---|---|
| Local network | Find and talk to your Mac on the same Wi-Fi (Android 17 asks for this when you first open the app; choose Allow) |
| SMS | Read texts, find one-time codes, send texts when you allow it on the Mac |
| Contacts | Show names instead of numbers, search contacts from the Mac |
| Phone and calls | See call state, start a call, hang up or reject |
| Notification access | Show your notifications on the Mac and dismiss them |
| Show notifications | The small "Connected to your Mac" status |
| Battery optimisation | Keep the link alive with the screen off |

**Allow restricted settings.** Because the app is installed outside the Play Store, Android 13 and later can grey out SMS and Notification access. Open Settings, Apps, apnum, tap the three dots at the top right, and choose Allow restricted settings. Then grant the permission again.

**Motorola battery settings.** Open Settings, Apps, apnum, Battery, and choose Unrestricted. Without it Android may stop the link when the screen is off.

## 3. Pair with the Mac

On the Mac, open apnum, go to Phone, and choose Pair a phone. It shows a QR code, a link and an 8-digit code. Your phone and Mac need to reach each other on the network: the same Wi-Fi works, and so does the phone's own hotspot (connect the Mac to it).

Choose whichever suits you.

- **Scan the QR code.** In the apnum app, tap Scan the code on your Mac. The first time, Google Play services downloads the scanner, so you need to be online.
- **Use the link.** Open the link on the phone (from any camera app, a message to yourself, or `adb shell am start -a android.intent.action.VIEW -d "<link>"`). The app opens and pairs.
- **Type the code.** Tap Enter code instead. The address fills in if the phone finds your Mac. Type the 8-digit code and tap Connect. The phone then shows a 6-digit safety number. Check that your Mac shows the same number and tap They match. If the numbers differ, tap They differ and start again.

After pairing, the phone reconnects by itself, including after a reboot. To forget the Mac, open Settings in the app and tap Unpair.

## Troubleshooting

- **The phone says "Looking for your Mac".** Check that both are on the same network, and that apnum is running on the Mac.
- **The Mac asked about incoming connections.** macOS shows a firewall prompt the first time. Choose Allow, or the phone cannot connect.
- **A VPN is on.** Some VPNs block local traffic. Turn it off on the phone and the Mac, or allow local network access.
- **Guest Wi-Fi or a cafe network.** These often stop devices from seeing each other. Use your home Wi-Fi or the phone's hotspot instead.
- **Discovery finds nothing.** Type the Mac's address in Enter code instead. You can see it in the link on the Mac, after `host=`.
- **Texts or codes are missing on the Mac.** Check SMS in Permissions and that it says Granted.
- **The clipboard says unavailable.** Android only lets the app on screen read the clipboard. Open apnum on the phone and try again.
- **Ring does not make a sound.** It uses the alarm volume, which works on silent. Do Not Disturb can still mute alarms; allow alarms in Do Not Disturb.
