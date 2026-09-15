#!/usr/bin/env bash
#
# tools/install.sh — install the RE7 Personal Trainer into a Resident Evil 7
# installation's REFramework autorun folder.
#
# USAGE
#   ./tools/install.sh "/path/to/RESIDENT EVIL 7 biohazard" [--bundle]
#
# DEFAULT MODE: MODULAR
#   Installs a small top-level loader plus the module tree:
#
#     reframework/autorun/re7trainer.lua          <- loader (auto-executed)
#     reframework/autorun/re7trainer/main.lua     <- modules, loaded via require()
#     reframework/autorun/re7trainer/utils/...       (subtree is NOT auto-executed)
#
#   This is the layout the project was designed around, and it is safe because
#   of two verified properties of REFramework v1.5.9's ScriptRunner:
#
#     1. reset_scripts() iterates `autorun/*.lua` NON-RECURSIVELY. Only the
#        top-level loader runs automatically; everything under re7trainer/ is
#        left alone, so module files are never executed as standalone scripts.
#
#     2. reset_scripts() appends `<autorun>/?.lua` and `<autorun>/?/init.lua`
#        to package.path BEFORE running any script. So a require("re7trainer.x")
#        from the loader resolves to autorun/re7trainer/x.lua.
#
#   Both properties were confirmed against the source for tag v1.5.9 and
#   independently against the installed binary, where the literals "/?.lua",
#   "/?/init.lua" and "/?.dll" sit immediately adjacent to the "[ScriptState]
#   Running script {}..." string — the package.path concatenation in
#   ScriptState::run_script(). See docs/COMPATIBILITY.md.
#
# --bundle MODE
#   Builds src/ into a single self-contained file instead, registering every
#   module in package.preload. This has NO dependency on package.path at all,
#   which makes it useful as a diagnostic: if modular mode does not load,
#   --bundle isolates whether the problem is module resolution or something
#   else. It is also genuinely robust against future ScriptRunner changes.
#
# WHAT IT WILL NEVER DO
#   * delete or overwrite dinput8.dll, or any REFramework file
#   * touch reframework/plugins/
#   * delete the reframework directory
#   * modify any other mod's autorun scripts
#   * write to the game's .pak files

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

LOADER_NAME="re7trainer.lua"
MODULE_DIR="re7trainer"
BUNDLE_NAME="re7trainer.lua"
MANIFEST_NAME=".re7trainer_manifest"

MODE="modular"

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

POSITIONAL=()
for arg in "$@"; do
  case "${arg}" in
    --bundle) MODE="bundle" ;;
    --modular) MODE="modular" ;;
    -h|--help)
      sed -n '2,50p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) POSITIONAL+=("${arg}") ;;
  esac
done

if [[ ${#POSITIONAL[@]} -lt 1 ]]; then
  echo "Usage: $0 \"/path/to/RESIDENT EVIL 7 biohazard\" [--bundle]" >&2
  echo "" >&2
  echo "The path is the folder containing re7.exe." >&2
  exit 64
fi

GAME_DIR="${POSITIONAL[0]%/}"

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

if [[ ! -d "${GAME_DIR}/reframework" ]]; then
  echo "error: ${GAME_DIR}/reframework does not exist." >&2
  echo "       REFramework must be installed and run at least once first." >&2
  exit 65
fi

AUTORUN_DIR="${GAME_DIR}/reframework/autorun"

if [[ ! -f "${GAME_DIR}/dinput8.dll" ]]; then
  echo "warning: dinput8.dll not found next to re7.exe." >&2
  echo "         REFramework may be installed via a different loader." >&2
fi

echo "Installing RE7 Personal Trainer (${MODE} mode)"
echo "  game dir : ${GAME_DIR}"
echo "  autorun  : ${AUTORUN_DIR}"
echo ""

# ---------------------------------------------------------------------------
# Remove any previous install first, so switching modes cannot leave a stale
# loader and a stale bundle both trying to initialise the trainer twice.
# ---------------------------------------------------------------------------

if [[ -f "${AUTORUN_DIR}/${MANIFEST_NAME}" ]]; then
  echo "Removing previous installation..."
  "${SCRIPT_DIR}/uninstall.sh" "${GAME_DIR}" >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# Syntax-check every source file before it goes anywhere near the game
# ---------------------------------------------------------------------------

if command -v luac >/dev/null 2>&1; then
  echo "Syntax checking source..."
  syntax_fail=0
  while IFS= read -r f; do
    if ! luac -p "$f" 2>/dev/null; then
      echo "  FAIL: $f" >&2
      syntax_fail=1
    fi
  done < <(find "${PROJECT_DIR}/src" -name '*.lua' | sort)

  if [[ "${syntax_fail}" -ne 0 ]]; then
    echo "error: source failed syntax check; nothing installed." >&2
    exit 70
  fi
  echo "  all files OK"
fi

mkdir -p "${AUTORUN_DIR}"

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

if [[ "${MODE}" == "bundle" ]]; then

  LUA_BIN=""
  for candidate in lua lua5.4 lua5.3 luajit; do
    if command -v "${candidate}" >/dev/null 2>&1; then LUA_BIN="${candidate}"; break; fi
  done

  if [[ -z "${LUA_BIN}" ]]; then
    echo "error: no Lua interpreter found for bundling (tried lua, lua5.4, lua5.3, luajit)." >&2
    exit 69
  fi

  BUILD_DIR="${PROJECT_DIR}/build"
  mkdir -p "${BUILD_DIR}"

  echo "Bundling with ${LUA_BIN}..."
  "${LUA_BIN}" "${PROJECT_DIR}/tools/bundle.lua" \
    "${PROJECT_DIR}/src" "${BUILD_DIR}/${BUNDLE_NAME}"

  if command -v luac >/dev/null 2>&1 && ! luac -p "${BUILD_DIR}/${BUNDLE_NAME}" 2>/dev/null; then
    echo "error: generated bundle failed syntax check." >&2
    exit 70
  fi

  install -m 0644 "${BUILD_DIR}/${BUNDLE_NAME}" "${AUTORUN_DIR}/${BUNDLE_NAME}"

  cat > "${AUTORUN_DIR}/${MANIFEST_NAME}" <<EOF
# Installed by re7-personal-trainer/tools/install.sh (bundle mode)
# Files listed here are owned by this trainer and may be removed by uninstall.sh.
${BUNDLE_NAME}
EOF

  echo ""
  echo "Installed:"
  echo "  ${AUTORUN_DIR}/${BUNDLE_NAME}"

else

  # The loader is the only file the ScriptRunner will auto-execute. It must
  # stay tiny and must not do anything except hand off to the module tree.
  cat > "${AUTORUN_DIR}/${LOADER_NAME}" <<'EOF'
-- RE7 Personal Trainer - autorun loader.
--
-- This is the only file REFramework executes automatically: ScriptRunner
-- iterates autorun/*.lua non-recursively. Everything else lives under
-- re7trainer/ and is loaded on demand through require(), which works because
-- ScriptRunner appends <autorun>/?.lua to package.path before running scripts.
--
-- Generated by tools/install.sh. Edit the files in src/ and reinstall.
return require("re7trainer.main")
EOF

  rm -rf "${AUTORUN_DIR:?}/${MODULE_DIR}"
  mkdir -p "${AUTORUN_DIR}/${MODULE_DIR}"

  # Copy the tree, preserving structure.
  while IFS= read -r f; do
    rel="${f#"${PROJECT_DIR}/src/"}"
    dest="${AUTORUN_DIR}/${MODULE_DIR}/${rel}"
    mkdir -p "$(dirname "${dest}")"
    install -m 0644 "${f}" "${dest}"
  done < <(find "${PROJECT_DIR}/src" -name '*.lua' -type f | sort)

  # Manifest: every file we own, so uninstall never has to guess.
  {
    echo "# Installed by re7-personal-trainer/tools/install.sh (modular mode)"
    echo "# Files listed here are owned by this trainer and may be removed by uninstall.sh."
    echo "${LOADER_NAME}"
    while IFS= read -r f; do
      rel="${f#"${PROJECT_DIR}/src/"}"
      echo "${MODULE_DIR}/${rel}"
    done < <(find "${PROJECT_DIR}/src" -name '*.lua' -type f | sort)
  } > "${AUTORUN_DIR}/${MANIFEST_NAME}"

  echo ""
  echo "Installed:"
  echo "  ${AUTORUN_DIR}/${LOADER_NAME}"
  echo "  ${AUTORUN_DIR}/${MODULE_DIR}/  ($(find "${AUTORUN_DIR}/${MODULE_DIR}" -name '*.lua' | wc -l) modules)"
fi

echo ""
echo "Next:"
echo "  1. Launch Resident Evil 7."
echo "  2. Press Insert to open the REFramework menu."
echo "  3. The trainer appears as its own collapsible section."
echo ""
echo "No cheat is functional yet. Open Developer -> 'Run discovery dump' from"
echo "inside gameplay, then read docs/DISCOVERY.md for what to do with the output."
