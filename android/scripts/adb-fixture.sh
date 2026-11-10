#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export ANDROID_USER_HOME="$ROOT/.tools/android-user"
export ANDROID_EMULATOR_HOME="$ANDROID_USER_HOME"
export ANDROID_ADB_SERVER_PORT=5045
export ADB_SERVER_SOCKET=tcp:127.0.0.1:5045
SERIAL="${OTPEEK_EMULATOR_SERIAL:-emulator-5660}"
case "$SERIAL" in
    emulator-5660) TARGET=127.0.0.1:5661 ;;
    emulator-5662) TARGET=127.0.0.1:5663 ;;
    *) echo 'Use only OTPeek fixture emulators 5660/5662.' >&2; exit 1 ;;
esac
# Explicit TCP transport avoids emulator registration against another ADB server.
"$ROOT/.tools/sdk/platform-tools/adb" -P 5045 connect "$TARGET" >/dev/null
exec "$ROOT/.tools/sdk/platform-tools/adb" -P 5045 -s "$TARGET" "$@"
