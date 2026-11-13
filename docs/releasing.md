# Releasing apnum

One command publishes the Mac app and the Android APK as a GitHub Release:

```sh
export APNUM_SIGN_IDENTITY="Your Signing Identity"   # see below
scripts/release.sh 0.2.0 --notes "What changed."      # omit --notes to generate them from commits
scripts/release.sh 0.2.0 --dry-run                    # build and verify, publish nothing
```

The script refuses a dirty git tree or a version that is not greater than the latest `v*` tag. It sets the version in `Resources/Info.plist` (`CFBundleShortVersionString` is the version, `CFBundleVersion` is `git rev-list --count HEAD`) and passes the same two values to Gradle as `-PappVersionName` and `-PappVersionCode`. It then builds the Rust libraries, the Mac app and the APK, runs `swift test`, writes the assets to `build/release/`, commits the bump, tags `vX.Y.Z`, pushes, and runs `gh release create` (log in once with `gh auth login`).

## The contract

- Repo `Aazhs/apnum`, tag `vX.Y.Z`.
- Assets: `Apnum-mac.zip` (the app zipped with `ditto -c -k --keepParent`) and `apnum-android.apk`.
- "Latest" is `GET https://api.github.com/repos/Aazhs/apnum/releases/latest` (`tag_name`, `body`, `assets[].name`, `assets[].browser_download_url`, `html_url`). No token, User-Agent `apnum`.
- Versions compare numerically by dotted component, so 0.10.0 is newer than 0.9.9.

## Signing

**Mac.** An update only installs over an app signed by the same identity. The updater checks that the downloaded bundle is `dev.apnum.mac`, has the expected version, and has a valid signature that satisfies the running app's designated requirement. Set `APNUM_SIGN_IDENTITY` to a code-signing identity (on this machine, `Aash Local`) for every build you ship and every build you run. A build signed ad hoc (the default of `scripts/bundle.sh`) cannot be verified, so it refuses to update unless you choose "Install anyway". If you lose the identity, users must download the new app by hand once.

**Android.** The APK is the debug build, signed with this machine's `~/.android/debug.keystore`. Android only updates an app when the new APK has the same key. Back that file up; if it is lost, phones must uninstall apnum (losing pairing) and install the new APK.

## How the update buttons work

**Mac.** Settings, About, "Software update". apnum checks once at launch and then at most once a day (switch off with "Check for updates automatically"); it never downloads on its own. When a newer release exists, the sidebar shows a quiet "Update available" line and About shows the release notes and "Update now". That downloads `Apnum-mac.zip` to a temporary folder next to the app, unpacks it with `ditto`, verifies it, moves the running app aside, moves the new one into place (putting the old one back on any failure), and relaunches. It needs apnum to run from a writable `.app`; under `swift run` it explains why it cannot update. Agents can use `app.update.check` (read) and `app.update.install` (dangerous).

**Android.** The phone's update button reads the same `releases/latest`, compares `tag_name` with its own `versionName`, and downloads `apnum-android.apk`.
