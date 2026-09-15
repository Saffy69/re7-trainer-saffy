#!/usr/bin/env bash
#
# tools/install.sh — install the RE7 Personal Trainer into a Resident Evil 7
# installation's REFramework autorun folder.
#
# USAGE
#   ./tools/install.sh "/path/to/RESIDENT EVIL 7 biohazard"
#
# WHAT IT DOES
#   1. Validates that the target really is an RE7 install with REFramework
#      present. It refuses to act on anything else rather than creating a
#      reframework folder in the wrong place.
#   2. Bundles src/ into a single self-contained Lua file.
#   3. Installs exactly one file into reframework/autorun/.
#
# WHY ONE FILE
#   See the header of tools/bundle.lua. Short version: this REFramework build
#   has no filesystem API and no game-directory accessor, and require() resolves
#   against a package.path we cannot verify. A single file with package.preload
#   registrations is the only arrangement with no path dependencies.
#
# WHAT IT WILL NEVER DO
#   * delete or overwrite dinput8.dll, or any REFramework file
#   * touch reframework/plugins/
#   * delete the reframework directory
#   * modify any other mod's autorun scripts
#   * write to the game's .pak files
#
# It removes only files it previously installed, identified by a marker comment
# in the first line and by an explicit manifest it writes on install.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

BUNDLE_NAME="re7trainer.lua"
MANIFEST_NAME=".re7trainer_manifest"

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 \"/path/to/RESIDENT EVIL 7 biohazard\"" >&2
  echo "" >&2
  echo "The path is the folder containing re7.exe." >&2
  exit 64
fi

GAME_DIR="${1%/}"

if [[ ! -d "${GAME_DIR}" ]]; then
  echo "error: not a directory: ${GAME_DIR}" >&2
  exit 66
fi

# ---------------------------------------------------------------------------
# Validate the target
#
# Refusing to install into the wrong folder matters more than convenience: a
# stray reframework/ directory in an unrelated game is confusing to clean up.
# ---------------------------------------------------------------------------

if [[ ! -f "${GAME_DIR}/re7.exe" ]]; then
  echo "error: no re7.exe in ${GAME_DIR}" >&2
  echo "       Point this at the folder that contains re7.exe." >&2
  exit 65
fi

AUTORUN_DIR="${GAME_DIR}/reframework/autorun"

if [[ ! -d "${GAME_DIR}/reframework" ]]; then
  echo "error: ${GAME_DIR}/reframework does not exist." >&2
  echo "       REFramework must be installed and run at least once first." >&2
  exit 65
fi

if [[ ! -f "${GAME_DIR}/dinput8.dll" ]]; then
  echo "warning: dinput8.dll not found next to re7.exe." >&2
  echo "         REFramework may be installed via a different loader." >&2
fi

echo "Installing RE7 Personal Trainer"
echo "  game dir : ${GAME_DIR}"
echo "  autorun  : ${AUTORUN_DIR}"
echo ""

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

BUILD_DIR="${PROJECT_DIR}/build"
mkdir -p "${BUILD_DIR}"

LUA_BIN=""
for candidate in lua lua5.4 lua5.3 luajit; do
  if command -v "${candidate}" >/dev/null 2>&1; then
    LUA_BIN="${candidate}"
    break
  fi
done

if [[ -z "${LUA_BIN}" ]]; then
  echo "error: no Lua interpreter found (tried lua, lua5.4, lua5.3, luajit)." >&2
  echo "       Install one, e.g. 'sudo pacman -S lua'." >&2
  exit 69
fi

echo "Bundling with ${LUA_BIN}..."
"${LUA_BIN}" "${PROJECT_DIR}/tools/bundle.lua" \
  "${PROJECT_DIR}/src" \
  "${BUILD_DIR}/${BUNDLE_NAME}"

# Syntax-check the bundle before it goes anywhere near the game. A syntax error
# in autorun is a silent no-op at runtime, which is a miserable thing to debug.
if command -v luac >/dev/null 2>&1; then
  if ! luac -p "${BUILD_DIR}/${BUNDLE_NAME}" 2>/dev/null; then
    echo "error: generated bundle failed syntax check." >&2
    exit 70
  fi
  echo "Syntax check passed."
fi

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

mkdir -p "${AUTORUN_DIR}"

install -m 0644 "${BUILD_DIR}/${BUNDLE_NAME}" "${AUTORUN_DIR}/${BUNDLE_NAME}"

# Record exactly what we installed, so uninstall.sh never has to guess.
cat > "${AUTORUN_DIR}/${MANIFEST_NAME}" <<EOF
# Installed by re7-personal-trainer/tools/install.sh
# Files listed here are owned by this trainer and may be removed by uninstall.sh.
${BUNDLE_NAME}
EOF

echo ""
echo "Installed:"
echo "  ${AUTORUN_DIR}/${BUNDLE_NAME}"
echo ""
echo "Next:"
echo "  1. Launch Resident Evil 7."
echo "  2. Press Insert to open the REFramework menu."
echo "  3. The trainer appears as its own collapsible section."
echo ""
echo "No cheat is functional yet. Open Developer -> 'Run discovery dump' from"
echo "inside gameplay, then read docs/DISCOVERY.md for what to do with the output."
