#!/bin/sh
# Builds the shared Rust link core (rust/apnum-link) and its UniFFI bindings.
#
#   scripts/build-rust.sh mac       xcframework for SwiftPM + Swift bindings
#   scripts/build-rust.sh android   .so files + Kotlin bindings
#   scripts/build-rust.sh all       both (default)
#
# Run `mac` once before `swift build`: the xcframework lives in build/ and is not committed.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CRATE="$ROOT/rust/apnum-link"
LIB=apnum_link
export PATH="$HOME/.cargo/bin:$PATH"
: "${DEVELOPER_DIR:=/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

die() { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 not found. $2"; }

need cargo "Install Rust with rustup (https://rustup.rs) and run: rustup default stable"
rustup show active-toolchain >/dev/null 2>&1 || die "no default Rust toolchain. Run: rustup default stable"

ensure_target() {
  rustup target list --installed | grep -qx "$1" || rustup target add "$1" || die "could not add Rust target $1"
}

bindgen() {
  (cd "$CRATE" && cargo run --quiet --release --bin uniffi-bindgen -- "$@")
}

build_mac() {
  need xcodebuild "Install Xcode and point DEVELOPER_DIR at it."
  ensure_target aarch64-apple-darwin
  T=aarch64-apple-darwin
  (cd "$CRATE" && cargo build --release --target "$T")
  REL="$CRATE/target/$T/release"
  OUT="$ROOT/build/rust"
  GEN="$OUT/generated"
  rm -rf "$OUT"
  mkdir -p "$GEN" "$OUT/headers"
  bindgen generate --library "$REL/lib$LIB.dylib" --language swift --out-dir "$GEN"
  cp "$GEN/${LIB}FFI.h" "$OUT/headers/"
  cp "$GEN/${LIB}FFI.modulemap" "$OUT/headers/module.modulemap"
  xcodebuild -create-xcframework -library "$REL/lib$LIB.a" -headers "$OUT/headers" \
    -output "$OUT/ApnumLinkFFI.xcframework" >/dev/null
  mkdir -p "$ROOT/Sources/ApnumLinkCore"
  cp "$GEN/$LIB.swift" "$ROOT/Sources/ApnumLinkCore/$LIB.swift"
  echo "Built $OUT/ApnumLinkFFI.xcframework and Sources/ApnumLinkCore/$LIB.swift"
}

build_android() {
  need cargo-ndk "Install it with: cargo install cargo-ndk"
  if [ -z "${ANDROID_NDK_HOME:-}" ]; then
    SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
    [ -d "$SDK/ndk" ] || die "Android NDK not found. Install it with sdkmanager \"ndk;<version>\" or set ANDROID_NDK_HOME."
    ANDROID_NDK_HOME="$SDK/ndk/$(ls "$SDK/ndk" | sort -V | tail -1)"
    export ANDROID_NDK_HOME
  fi
  [ -d "$ANDROID_NDK_HOME" ] || die "ANDROID_NDK_HOME ($ANDROID_NDK_HOME) does not exist"
  ensure_target aarch64-linux-android
  ensure_target x86_64-linux-android
  JNI="$ROOT/android/app/src/main/jniLibs"
  KT="$ROOT/android/app/src/main/java"
  mkdir -p "$JNI" "$KT"
  (cd "$CRATE" && cargo ndk -t arm64-v8a -t x86_64 -o "$JNI" build --release)
  # The Android .so files are stripped (no UniFFI metadata), so read the metadata from the host build.
  ensure_target aarch64-apple-darwin
  (cd "$CRATE" && cargo build --release --target aarch64-apple-darwin)
  bindgen generate --library "$CRATE/target/aarch64-apple-darwin/release/lib$LIB.dylib" --language kotlin --out-dir "$KT"
  [ -f "$KT/uniffi/$LIB/$LIB.kt" ] || die "Kotlin bindings were not generated"
  echo "Built $JNI/{arm64-v8a,x86_64}/lib$LIB.so and Kotlin bindings in $KT"
}

case "${1:-all}" in
  mac) build_mac ;;
  android) build_android ;;
  all) build_mac; build_android ;;
  *) die "usage: scripts/build-rust.sh [mac|android|all]" ;;
esac
