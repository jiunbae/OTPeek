#!/usr/bin/env bash
#
# build-core.sh — builds the otp-ffi Rust staticlib for Apple platforms,
# assembles apple/Frameworks/OtpeekCore.xcframework, and regenerates the Swift
# bindings into apple/Generated/.
#
# Idempotent and runnable from any working directory. Safe to re-run: it wipes
# the previous xcframework and generated bindings before re-emitting them.
#
# Slices produced (only for rust targets that are installed):
#   - aarch64-apple-darwin      (macOS, Apple Silicon)
#   - aarch64-apple-ios         (iOS device)
#   - aarch64-apple-ios-sim     (iOS simulator, Apple Silicon)
#
# See docs/ARCHITECTURE.md §9.
set -euo pipefail

# --- resolve paths (independent of cwd) ------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${APPLE_DIR}/.." && pwd)"
CORE_DIR="${REPO_ROOT}/core"

FRAMEWORKS_DIR="${APPLE_DIR}/Frameworks"
GENERATED_DIR="${APPLE_DIR}/Generated"
XCFRAMEWORK="${FRAMEWORKS_DIR}/OtpeekCore.xcframework"
HEADERS_DIR="${GENERATED_DIR}/include"

CRATE="otpeek-ffi"
LIB_NAME="libotpeek_ffi.a"
PROFILE="release"

MACOS_TARGET="aarch64-apple-darwin"
MACOS_X86_TARGET="x86_64-apple-darwin"
IOS_TARGET="aarch64-apple-ios"
IOS_SIM_TARGET="aarch64-apple-ios-sim"

echo "==> build-core.sh"
echo "    repo:   ${REPO_ROOT}"
echo "    core:   ${CORE_DIR}"
echo "    apple:  ${APPLE_DIR}"

installed_targets="$(rustup target list --installed 2>/dev/null || true)"

target_installed() {
    echo "${installed_targets}" | grep -qx "$1"
}

build_slice() {
    local target="$1"
    if ! target_installed "${target}"; then
        echo "==> SKIP ${target} (rust target not installed; run: rustup target add ${target})"
        return 1
    fi
    echo "==> cargo build ${CRATE} --${PROFILE} --target ${target}"
    ( cd "${CORE_DIR}" && cargo build -p "${CRATE}" --"${PROFILE}" --target "${target}" )
    return 0
}

# --- build the macOS (host) slice: required for binding generation ---------
if ! build_slice "${MACOS_TARGET}"; then
    echo "!! macOS target ${MACOS_TARGET} is required and is not installed." >&2
    exit 1
fi

# x86_64 macOS slice → universal macOS lib (needed for a Mac App Store build
# that runs on Intel Macs too). Best-effort: arm64-only still builds locally.
HAVE_MACOS_X86=0
build_slice "${MACOS_X86_TARGET}" && HAVE_MACOS_X86=1 || true

# iOS slices are best-effort; the script stays correct if they are missing.
HAVE_IOS=0
HAVE_IOS_SIM=0
build_slice "${IOS_TARGET}"      && HAVE_IOS=1      || true
build_slice "${IOS_SIM_TARGET}"  && HAVE_IOS_SIM=1  || true

MACOS_ARM_LIB="${CORE_DIR}/target/${MACOS_TARGET}/${PROFILE}/${LIB_NAME}"
MACOS_DYLIB="${CORE_DIR}/target/${MACOS_TARGET}/${PROFILE}/libotpeek_ffi.dylib"

# Fuse arm64 + x86_64 into one universal static lib for the xcframework's
# macOS slice; fall back to arm64-only when the x86_64 slice is unavailable.
if [ "${HAVE_MACOS_X86}" -eq 1 ]; then
    MACOS_LIB="${CORE_DIR}/target/libotpeek_ffi-macos-universal.a"
    echo "==> lipo -create macOS universal (arm64 + x86_64)"
    lipo -create \
        "${MACOS_ARM_LIB}" \
        "${CORE_DIR}/target/${MACOS_X86_TARGET}/${PROFILE}/${LIB_NAME}" \
        -output "${MACOS_LIB}"
else
    echo "==> NOTE: x86_64 macOS slice missing — macOS lib is arm64-only." >&2
    MACOS_LIB="${MACOS_ARM_LIB}"
fi

# --- regenerate Swift bindings from the freshly built host library ---------
echo "==> generating Swift bindings"
rm -rf "${GENERATED_DIR}"
mkdir -p "${GENERATED_DIR}" "${HEADERS_DIR}"

BINDGEN_LIB="${MACOS_DYLIB}"
[ -f "${BINDGEN_LIB}" ] || BINDGEN_LIB="${MACOS_LIB}"

( cd "${CORE_DIR}" && cargo run -p "${CRATE}" --bin uniffi-bindgen -- \
    generate --library "${BINDGEN_LIB}" --language swift --out-dir "${GENERATED_DIR}" )

# Move the C shim (header + modulemap) into an include dir for the xcframework.
# UniFFI emits `<ns>FFI.modulemap`; xcframework Headers expects `module.modulemap`.
mv "${GENERATED_DIR}"/*FFI.h "${HEADERS_DIR}/"
for mm in "${GENERATED_DIR}"/*.modulemap; do
    mv "${mm}" "${HEADERS_DIR}/module.modulemap"
done
echo "    -> ${GENERATED_DIR}/otpeek.swift"
echo "    -> ${HEADERS_DIR}/ (header + module.modulemap)"

# --- assemble the xcframework ----------------------------------------------
# xcframework assembly requires full Xcode (xcodebuild). If only the Command
# Line Tools are installed the bindings + staticlib are still produced above;
# re-run this script once Xcode is selected (xcode-select -s /Applications/Xcode.app).
if ! command -v xcodebuild >/dev/null 2>&1 || ! xcodebuild -version >/dev/null 2>&1; then
    echo "!! xcodebuild unavailable (full Xcode not selected) — skipping xcframework assembly." >&2
    echo "   Bindings + macOS staticlib are ready. Select Xcode and re-run to build OtpeekCore.xcframework." >&2
    exit 0
fi

echo "==> assembling OtpeekCore.xcframework"
mkdir -p "${FRAMEWORKS_DIR}"
rm -rf "${XCFRAMEWORK}"

XCARGS=(-create-xcframework)
XCARGS+=(-library "${MACOS_LIB}" -headers "${HEADERS_DIR}")
if [ "${HAVE_IOS}" -eq 1 ]; then
    XCARGS+=(-library "${CORE_DIR}/target/${IOS_TARGET}/${PROFILE}/${LIB_NAME}" -headers "${HEADERS_DIR}")
fi
if [ "${HAVE_IOS_SIM}" -eq 1 ]; then
    XCARGS+=(-library "${CORE_DIR}/target/${IOS_SIM_TARGET}/${PROFILE}/${LIB_NAME}" -headers "${HEADERS_DIR}")
fi
XCARGS+=(-output "${XCFRAMEWORK}")

xcodebuild "${XCARGS[@]}"

echo "==> done."
echo "    xcframework: ${XCFRAMEWORK}"
if [ "${HAVE_IOS}" -eq 0 ] || [ "${HAVE_IOS_SIM}" -eq 0 ]; then
    echo "    NOTE: one or more iOS slices were skipped (missing rust targets)."
    echo "          Run: rustup target add ${IOS_TARGET} ${IOS_SIM_TARGET}"
fi
