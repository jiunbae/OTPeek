#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
NDK="$SDK/ndk/28.2.13676358/toolchains/llvm/prebuilt/darwin-x86_64"
if [[ ! -d "$NDK" ]]; then
    NDK="$SDK/ndk/28.2.13676358/toolchains/llvm/prebuilt/linux-x86_64"
fi
[[ -x "$NDK/bin/aarch64-linux-android26-clang" ]] || { echo 'NDK r28c missing. See android/README.md.' >&2; exit 1; }
export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
export CARGO_TARGET_DIR="$ROOT/core/target/android"
export RUSTUP_TOOLCHAIN=1.94.0
export RUSTC="$(rustup which --toolchain "$RUSTUP_TOOLCHAIN" rustc)"
export RUSTDOC="$(rustup which --toolchain "$RUSTUP_TOOLCHAIN" rustdoc)"
CARGO_BIN="$(rustup which --toolchain "$RUSTUP_TOOLCHAIN" cargo)"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$NDK/bin/aarch64-linux-android26-clang"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS='-C link-arg=-Wl,-z,max-page-size=16384 -C link-arg=-Wl,-z,common-page-size=16384'
export CC_aarch64_linux_android="$NDK/bin/aarch64-linux-android26-clang"
export AR_aarch64_linux_android="$NDK/bin/llvm-ar"
export CARGO_BUILD_JOBS=4
"$CARGO_BIN" build --manifest-path "$ROOT/core/Cargo.toml" --locked -p otpeek-ffi --lib --no-default-features --target aarch64-linux-android --release
HOST_TARGET_DIR="$ROOT/core/target/android-investigation/build"
CARGO_TARGET_DIR="$HOST_TARGET_DIR" "$CARGO_BIN" build --manifest-path "$ROOT/core/Cargo.toml" --locked -p otpeek-ffi --lib --bin uniffi-bindgen
case "$(uname -s)" in
    Darwin) HOST_LIB="$HOST_TARGET_DIR/debug/libotpeek_ffi.dylib" ;;
    *) HOST_LIB="$HOST_TARGET_DIR/debug/libotpeek_ffi.so" ;;
esac
OUT="$ROOT/android/app/build/generated"
mkdir -p "$OUT/rust/jniLibs/arm64-v8a" "$OUT/uniffi"
cp "$CARGO_TARGET_DIR/aarch64-linux-android/release/libotpeek_ffi.so" "$OUT/rust/jniLibs/arm64-v8a/"
(cd "$ROOT/core" && "$HOST_TARGET_DIR/debug/uniffi-bindgen" generate --library "$HOST_LIB" --config "$ROOT/android/uniffi.toml" --language kotlin --no-format --out-dir "$OUT/uniffi")
