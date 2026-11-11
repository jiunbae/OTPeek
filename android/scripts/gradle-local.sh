#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [[ -z "${JAVA_HOME:-}" ]]; then
    for JDK in "$ROOT"/.tools/jdk/*/Contents/Home; do
        [[ -x "$JDK/bin/java" ]] && export JAVA_HOME="$JDK" && break
    done
fi
export GRADLE_USER_HOME="${GRADLE_USER_HOME:-$HOME/.gradle}"
export ANDROID_USER_HOME="${ANDROID_USER_HOME:-$ROOT/.tools/android-user}"
export ANDROID_EMULATOR_HOME="$ANDROID_USER_HOME"
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
export ANDROID_HOME="$ANDROID_SDK_ROOT"
cd "$ROOT/android"
exec ./gradlew --no-daemon "$@"
