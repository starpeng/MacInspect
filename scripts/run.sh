#!/bin/bash
# Local run: Debug-build MacInspect (if needed) and launch it.
#
# Usage:
#   ./scripts/run.sh           # build if needed, then launch
#   ./scripts/run.sh --rebuild # force rebuild, then launch
#   ./scripts/run.sh --clean   # wipe DerivedData, full rebuild, then launch
#
set -euo pipefail

cd "$(dirname "$0")/.."
PROJECT="MacInspect.xcodeproj"
SCHEME="MacInspect"
APP_NAME="MacInspect"
ARTIFACTS_DIR="artifacts"
BUILD_DIR="${ARTIFACTS_DIR}/build/debug"
CONFIG="Debug"

REBUILD=0
CLEAN=0
for arg in "$@"; do
  case "$arg" in
    --rebuild|-r) REBUILD=1 ;;
    --clean|-c)   CLEAN=1; REBUILD=1 ;;
    -h|--help)
      echo "Usage: $0 [--rebuild|--clean]"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg (supported: --rebuild / --clean)" >&2
      exit 1
      ;;
  esac
done

# Always regenerate on --rebuild/--clean so new sources under src/ enter the target.
# Otherwise only generate when the .xcodeproj is missing.
need_xcodegen=0
if [ ! -d "$PROJECT" ]; then
  need_xcodegen=1
elif [ "$REBUILD" -eq 1 ]; then
  need_xcodegen=1
fi

if [ "$need_xcodegen" -eq 1 ]; then
  if command -v xcodegen >/dev/null; then
    echo "▸ Generate Xcode project"
    xcodegen generate
  elif [ ! -d "$PROJECT" ]; then
    echo "❌ Missing $PROJECT and xcodegen is not installed" >&2
    exit 1
  else
    echo "⚠️  xcodegen not installed; rebuilding with existing $PROJECT" >&2
  fi
fi

APP="$BUILD_DIR/Build/Products/${CONFIG}/${APP_NAME}.app"

# Quit a running instance first (also matches legacy MacCheck process name).
running_pids() {
  {
    pgrep -x "${APP_NAME}" 2>/dev/null || true
    pgrep -x "MacCheck" 2>/dev/null || true
    pgrep -f "/${APP_NAME}\\.app/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
    pgrep -f "/MacCheck\\.app/Contents/MacOS/MacCheck" 2>/dev/null || true
  } | sort -u
}

quit_running_app() {
  local pids
  pids="$(running_pids | paste -sd' ' -)"
  if [ -z "${pids}" ]; then
    return 0
  fi

  echo "▸ Quitting running instance (pid: ${pids})"
  # shellcheck disable=SC2086
  kill ${pids} 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pids="$(running_pids | paste -sd' ' -)"
    [ -z "${pids}" ] && break
    sleep 0.2
  done

  pids="$(running_pids | paste -sd' ' -)"
  if [ -n "${pids}" ]; then
    echo "▸ Force quit (pid: ${pids})"
    # shellcheck disable=SC2086
    kill -9 ${pids} 2>/dev/null || true
    sleep 0.2
  fi
}

quit_running_app

NEED_BUILD=0
if [ "$REBUILD" -eq 1 ] || [ ! -d "$APP" ]; then
  NEED_BUILD=1
fi

if [ "$CLEAN" -eq 1 ]; then
  echo "▸ Clean $BUILD_DIR"
  rm -rf "$BUILD_DIR"
fi

if [ "$NEED_BUILD" -eq 1 ]; then
  mkdir -p "$BUILD_DIR"
  echo "▸ Debug build → $BUILD_DIR"
  LOG=$(mktemp)
  if ! xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
    -derivedDataPath "$BUILD_DIR" \
    ONLY_ACTIVE_ARCH=YES \
    build > "$LOG" 2>&1; then
    echo "❌ Build failed; last 60 lines:" >&2
    tail -60 "$LOG" >&2
    rm -f "$LOG"
    exit 1
  fi
  grep -E 'BUILD (SUCCEEDED|FAILED)' "$LOG" | tail -1 || tail -1 "$LOG"
  rm -f "$LOG"
fi

if [ ! -d "$APP" ]; then
  echo "❌ Build product not found: $APP" >&2
  exit 1
fi

echo "▸ Launch $APP"
open -n "$APP"
