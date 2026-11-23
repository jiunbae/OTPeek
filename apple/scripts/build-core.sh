#!/usr/bin/env bash
#
# build-core.sh — builds the otp-ffi Rust staticlib for Apple platforms,
# assembles apple/Frameworks/OtpeekCore.xcframework, and regenerates the Swift
# bindings into apple/Generated/.
#
# Idempotent and runnable from any working directory. Safe to re-run: it wipes
# the previous XCFramework and generated bindings only after building replacements.
#
# Slices produced (only for rust targets that are installed):
#   - aarch64-apple-darwin      (macOS, Apple Silicon, required)
#   - x86_64-apple-darwin       (macOS, Intel)
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

CRATE="otpeek-ffi"
LIB_NAME="libotpeek_ffi.a"
PROFILE="release"

MACOS_TARGET="aarch64-apple-darwin"
MACOS_X86_TARGET="x86_64-apple-darwin"
IOS_TARGET="aarch64-apple-ios"
IOS_SIM_TARGET="aarch64-apple-ios-sim"

# The framework and bindings must be generated before Xcode plans its build.
# Check both outputs against the Rust inputs in the Xcode build phases.
core_fingerprint() (
    cd "${REPO_ROOT}"
    {
        shasum -a 256 apple/scripts/build-core.sh core/Cargo.toml core/Cargo.lock || exit 1
        find core/crates -type f -exec shasum -a 256 {} +
    } | LC_ALL=C sort | shasum -a 256
)

case "${1:-}" in
    --verify)
        fingerprint="$(core_fingerprint)"
        for stamp in "${XCFRAMEWORK}/.rust-inputs" "${GENERATED_DIR}/.rust-inputs"; do
            if [ ! -f "${stamp}" ] || [ "$(cat "${stamp}")" != "${fingerprint}" ]; then
                echo "error: Rust framework or bindings missing or stale. Run apple/scripts/build-core.sh before building with Xcode." >&2
                exit 1
            fi
        done
        exit 0
        ;;
    --require-all-targets|"") ;;
    *)
        echo "Usage: $0 [--require-all-targets | --verify]" >&2
        exit 2
        ;;
esac

if ! xcodebuild -version >/dev/null 2>&1; then
    echo "error: Select full Xcode with xcode-select to build OtpeekCore.xcframework." >&2
    exit 1
fi

echo "==> build-core.sh"
echo "    repo:   ${REPO_ROOT}"
echo "    core:   ${CORE_DIR}"
echo "    apple:  ${APPLE_DIR}"

installed_targets="$(cd "${CORE_DIR}" && rustup target list --installed)"
for target in "${MACOS_TARGET}" "${MACOS_X86_TARGET}" "${IOS_TARGET}" "${IOS_SIM_TARGET}"; do
    if ! printf '%s\n' "${installed_targets}" | grep -Fxq "${target}"; then
        if [ "${target}" = "${MACOS_TARGET}" ] || [ "${1:-}" = "--require-all-targets" ]; then
            echo "error: Required Rust target missing. Run: rustup target add ${target}" >&2
            exit 1
        fi
    fi
done

# Keep per-checkout artifacts together even if the shell uses a shared Cargo cache.
TARGET_DIR="${CORE_DIR}/target"
export CARGO_TARGET_DIR="${TARGET_DIR}"

fingerprint="$(core_fingerprint)"
stage="$(mktemp -d "${APPLE_DIR}/.build-core.XXXXXX")"
trap 'rm -rf "${stage}"' EXIT
STAGED_GENERATED="${stage}/Generated"
STAGED_FRAMEWORK="${stage}/OtpeekCore.xcframework"
HEADERS_DIR="${STAGED_GENERATED}/include"

build_slice() {
    local target="$1"
    echo "==> cargo build ${CRATE} --${PROFILE} --target ${target}"
    ( cd "${CORE_DIR}" && cargo build --locked -p "${CRATE}" --"${PROFILE}" --target "${target}" )
}

HAVE_MACOS_X86=0
HAVE_IOS=0
HAVE_IOS_SIM=0
build_slice "${MACOS_TARGET}"
if printf '%s\n' "${installed_targets}" | grep -Fxq "${MACOS_X86_TARGET}"; then
    build_slice "${MACOS_X86_TARGET}"
    HAVE_MACOS_X86=1
fi
if printf '%s\n' "${installed_targets}" | grep -Fxq "${IOS_TARGET}"; then
    build_slice "${IOS_TARGET}"
    HAVE_IOS=1
fi
if printf '%s\n' "${installed_targets}" | grep -Fxq "${IOS_SIM_TARGET}"; then
    build_slice "${IOS_SIM_TARGET}"
    HAVE_IOS_SIM=1
fi

MACOS_ARM_LIB="${TARGET_DIR}/${MACOS_TARGET}/${PROFILE}/${LIB_NAME}"
MACOS_DYLIB="${TARGET_DIR}/${MACOS_TARGET}/${PROFILE}/libotpeek_ffi.dylib"

# Fuse arm64 + x86_64 into one universal static lib for the xcframework's
# macOS slice; fall back to arm64-only when the x86_64 slice is unavailable.
if [ "${HAVE_MACOS_X86}" -eq 1 ]; then
    MACOS_LIB="${stage}/libotpeek_ffi-macos-universal.a"
    echo "==> lipo -create macOS universal (arm64 + x86_64)"
    lipo -create \
        "${MACOS_ARM_LIB}" \
        "${TARGET_DIR}/${MACOS_X86_TARGET}/${PROFILE}/${LIB_NAME}" \
        -output "${MACOS_LIB}"
else
    echo "==> NOTE: x86_64 macOS slice missing — macOS lib is arm64-only." >&2
    MACOS_LIB="${MACOS_ARM_LIB}"
fi

# --- regenerate Swift bindings from the freshly built host library ---------
echo "==> generating Swift bindings"
mkdir -p "${HEADERS_DIR}"

BINDGEN_LIB="${MACOS_DYLIB}"
[ -f "${BINDGEN_LIB}" ] || BINDGEN_LIB="${MACOS_LIB}"

( cd "${CORE_DIR}" && cargo run --locked -p "${CRATE}" --bin uniffi-bindgen -- \
    generate --library "${BINDGEN_LIB}" --language swift --out-dir "${STAGED_GENERATED}" )

# Move the C shim (header + modulemap) into an include dir for the xcframework.
# UniFFI emits `<ns>FFI.modulemap`; xcframework Headers expects `module.modulemap`.
mv "${STAGED_GENERATED}"/*FFI.h "${HEADERS_DIR}/"
for mm in "${STAGED_GENERATED}"/*.modulemap; do
    mv "${mm}" "${HEADERS_DIR}/module.modulemap"
done

# --- assemble the xcframework ----------------------------------------------
echo "==> assembling OtpeekCore.xcframework"
XCARGS=(-create-xcframework)
XCARGS+=(-library "${MACOS_LIB}" -headers "${HEADERS_DIR}")
if [ "${HAVE_IOS}" -eq 1 ]; then
    XCARGS+=(-library "${TARGET_DIR}/${IOS_TARGET}/${PROFILE}/${LIB_NAME}" -headers "${HEADERS_DIR}")
fi
if [ "${HAVE_IOS_SIM}" -eq 1 ]; then
    XCARGS+=(-library "${TARGET_DIR}/${IOS_SIM_TARGET}/${PROFILE}/${LIB_NAME}" -headers "${HEADERS_DIR}")
fi
XCARGS+=(-output "${STAGED_FRAMEWORK}")

xcodebuild "${XCARGS[@]}"

if [ "${fingerprint}" != "$(core_fingerprint)" ]; then
    echo "error: Rust inputs changed while building. Run apple/scripts/build-core.sh again." >&2
    exit 1
fi
printf '%s\n' "${fingerprint}" > "${STAGED_FRAMEWORK}/.rust-inputs"
printf '%s\n' "${fingerprint}" > "${STAGED_GENERATED}/.rust-inputs"
mkdir -p "${FRAMEWORKS_DIR}"
rm -rf "${XCFRAMEWORK}" "${GENERATED_DIR}"
mv "${STAGED_FRAMEWORK}" "${XCFRAMEWORK}"
mv "${STAGED_GENERATED}" "${GENERATED_DIR}"

echo "==> done."
echo "    xcframework: ${XCFRAMEWORK}"
if [ "${HAVE_IOS}" -eq 0 ] || [ "${HAVE_IOS_SIM}" -eq 0 ]; then
    echo "    NOTE: one or more iOS slices were skipped (missing rust targets)."
    echo "          Run: rustup target add ${IOS_TARGET} ${IOS_SIM_TARGET}"
fi
