#!/bin/sh
# Cuts a release: builds the Mac app and the Android APK, tags, and publishes both as a GitHub Release.
#
#   scripts/release.sh 0.2.0
#   scripts/release.sh 0.2.0 --notes "Faster alarms."
#   scripts/release.sh 0.2.0 --dry-run     build everything, publish nothing, revert the version bump
#
# Contract (the Mac updater and the phone's update button both rely on it):
#   repo Aazhs/apnum, tag vX.Y.Z, assets Apnum-mac.zip and apnum-android.apk.
#
# Signing: set APNUM_SIGN_IDENTITY to your code-signing identity. Mac updates only install over
# builds signed with the same identity. The APK is signed with this machine's Android debug
# keystore (~/.android/debug.keystore); Android only updates over an APK with the same key.
set -eu

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
REPO="Aazhs/apnum"
: "${DEVELOPER_DIR:=/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
export PATH="$HOME/.cargo/bin:$PATH"
# Gradle finds the SDK through ANDROID_HOME when android/local.properties is absent (fresh worktrees).
if [ -z "${ANDROID_HOME:-}" ] && [ -d "$HOME/Library/Android/sdk" ]; then ANDROID_HOME="$HOME/Library/Android/sdk"; export ANDROID_HOME; fi

die() { echo "error: $*" >&2; exit 1; }

VERSION=""
DRY=0
NOTES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --notes) shift; [ $# -gt 0 ] || die "--notes needs text"; NOTES="$1" ;;
    -*) die "unknown flag $1" ;;
    *) [ -z "$VERSION" ] || die "version given twice"; VERSION="$1" ;;
  esac
  shift
done
[ -n "$VERSION" ] || die "usage: scripts/release.sh <version> [--dry-run] [--notes \"text\"]"
VERSION="${VERSION#v}"
case "$VERSION" in
  ''|*[!0-9.]*|.*|*.|*..*) die "version must look like 1.2.3" ;;
esac
TAG="v$VERSION"

# Compares dotted versions numerically. Prints 1 when $1 > $2, else 0.
greater() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    n = split(a, x, "."); m = split(b, y, "."); if (m > n) n = m
    for (i = 1; i <= n; i++) { p = x[i] + 0; q = y[i] + 0
      if (p > q) { print 1; exit } if (p < q) { print 0; exit } }
    print 0 }'
}

# --- Preflight ---------------------------------------------------------------------------
[ -z "$(git status --porcelain)" ] || die "the git tree is dirty. Commit or stash first."
LATEST=""
for t in $(git tag -l 'v[0-9]*'); do
  v="${t#v}"
  if [ -z "$LATEST" ] || [ "$(greater "$v" "$LATEST")" = 1 ]; then LATEST="$v"; fi
done
if [ -n "$LATEST" ] && [ "$(greater "$VERSION" "$LATEST")" != 1 ]; then
  die "version $VERSION is not greater than the latest tag v$LATEST."
fi
if [ "$DRY" = 0 ]; then
  command -v gh >/dev/null 2>&1 || die "gh (GitHub CLI) not found."
  gh auth status >/dev/null 2>&1 || die "gh is not logged in. Run: gh auth login"
fi
ANDROID_JAVA="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
[ -x "$ANDROID_JAVA/bin/java" ] || die "Android Studio's JDK not found at $ANDROID_JAVA"

COUNT="$(git rev-list --count HEAD)"
COMMITTED=0
revert_bump() {
  if [ "$COMMITTED" = 0 ]; then git checkout -- Resources/Info.plist 2>/dev/null || true; fi
}
trap revert_bump EXIT

echo "Releasing $TAG (build $COUNT)${LATEST:+, previous v$LATEST}$( [ "$DRY" = 1 ] && echo ' [dry run]')"
if [ -n "${APNUM_SIGN_IDENTITY:-}" ]; then
  echo "Mac app signing identity: $APNUM_SIGN_IDENTITY"
else
  echo "WARNING: APNUM_SIGN_IDENTITY is not set, so the Mac app is signed ad hoc."
  echo "WARNING: Updates only install over builds signed with the same identity; an ad-hoc build"
  echo "WARNING: cannot update itself without the user choosing 'Install anyway'."
fi
echo "Android: the APK is signed with this machine's debug keystore (~/.android/debug.keystore)."
echo "         Lose it and phones must uninstall and reinstall apnum to update."

# --- Version -----------------------------------------------------------------------------
PLIST=Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $COUNT" "$PLIST"

# --- Build -------------------------------------------------------------------------------
echo "==> Rust libraries"
scripts/build-rust.sh all

echo "==> Mac app"
scripts/bundle.sh

echo "==> Android APK"
(cd android && JAVA_HOME="$ANDROID_JAVA" ./gradlew assembleDebug \
  "-PappVersionName=$VERSION" "-PappVersionCode=$COUNT")
APK_SRC="android/app/build/outputs/apk/debug/app-debug.apk"
[ -f "$APK_SRC" ] || die "APK not found at $APK_SRC"

echo "==> Tests"
swift test

# --- Artifacts ---------------------------------------------------------------------------
OUT=build/release
rm -rf "$OUT"
mkdir -p "$OUT"
ditto -c -k --keepParent build/Apnum.app "$OUT/Apnum-mac.zip"
cp "$APK_SRC" "$OUT/apnum-android.apk"
echo "Artifacts:"
ls -l "$OUT"

if [ "$DRY" = 1 ]; then
  echo "==> Dry run: would publish"
  echo "    commit   \"Release $TAG\" (Info.plist $VERSION / $COUNT)"
  echo "    tag      $TAG, pushed to origin"
  echo "    release  github.com/$REPO/releases/tag/$TAG"
  echo "    assets   $OUT/Apnum-mac.zip, $OUT/apnum-android.apk"
  echo "    notes    ${NOTES:-(generated from commits)}"
  echo "Version bump reverted. Nothing was created remotely."
  exit 0
fi

# --- Publish -----------------------------------------------------------------------------
git add Resources/Info.plist
git commit -m "Release $TAG"
COMMITTED=1
git tag -a "$TAG" -m "apnum $VERSION"
git push origin HEAD "$TAG"
if [ -n "$NOTES" ]; then
  gh release create "$TAG" "$OUT/Apnum-mac.zip" "$OUT/apnum-android.apk" \
    --repo "$REPO" --title "apnum $VERSION" --notes "$NOTES"
else
  gh release create "$TAG" "$OUT/Apnum-mac.zip" "$OUT/apnum-android.apk" \
    --repo "$REPO" --title "apnum $VERSION" --generate-notes
fi
echo "Published $TAG"
