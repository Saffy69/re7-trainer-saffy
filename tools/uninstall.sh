#!/usr/bin/env bash
#
# tools/uninstall.sh — remove the RE7 Personal Trainer from a Resident Evil 7
# installation.
#
# USAGE
#   ./tools/uninstall.sh "/path/to/RESIDENT EVIL 7 biohazard"
#
# SAFETY CONTRACT
#   This script removes only files this trainer installed. Specifically:
#
#     * it reads the manifest that install.sh wrote, and removes the files
#       listed there
#     * it removes the manifest itself
#     * it removes the trainer's own config file from the game directory
#
#   It will NOT:
#     * delete the reframework directory
#     * delete dinput8.dll or any REFramework component
#     * touch reframework/plugins/
#     * remove any autorun script it did not install
#     * touch .pak files or anything else belonging to the game
#
#   Every removal is guarded: if the manifest is missing, the script falls back
#   to a known filename, and it verifies the file it is about to delete actually
#   carries the trainer's generated-bundle marker before deleting it.

set -euo pipefail

BUNDLE_NAME="re7trainer.lua"
MANIFEST_NAME=".re7trainer_manifest"
CONFIG_NAME="re7trainer_config.json"
DISCOVERY_NAME="re7trainer_discovery.json"

# A string that only appears in files this project generated.
MARKER="RE7 Personal Trainer - generated bundle"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 \"/path/to/RESIDENT EVIL 7 biohazard\"" >&2
  exit 64
fi

GAME_DIR="${1%/}"

if [[ ! -d "${GAME_DIR}" ]]; then
  echo "error: not a directory: ${GAME_DIR}" >&2
  exit 66
fi

AUTORUN_DIR="${GAME_DIR}/reframework/autorun"

echo "Uninstalling RE7 Personal Trainer"
echo "  game dir : ${GAME_DIR}"
echo ""

removed_any=0

# ---------------------------------------------------------------------------
# Remove the installed bundle(s), driven by the manifest
# ---------------------------------------------------------------------------

remove_bundle() {
  local target="$1"

  if [[ ! -f "${target}" ]]; then
    return
  fi

  # Only delete a file we can positively identify as ours. If some other mod
  # happens to be called re7trainer.lua, this stops us deleting it.
  if ! grep -qF "${MARKER}" "${target}" 2>/dev/null; then
    echo "  skipped (not our file): ${target}" >&2
    return
  fi

  rm -f "${target}"
  echo "  removed: ${target}"
  removed_any=1
}

if [[ -f "${AUTORUN_DIR}/${MANIFEST_NAME}" ]]; then
  while IFS= read -r line; do
    # Skip comments and blank lines.
    [[ -z "${line}" || "${line}" == \#* ]] && continue

    # Refuse to act on anything that is not a plain filename, so a hand-edited
    # or corrupted manifest cannot be used to delete something outside here.
    if [[ "${line}" == */* || "${line}" == ".."* ]]; then
      echo "  skipped (unsafe manifest entry): ${line}" >&2
      continue
    fi

    remove_bundle "${AUTORUN_DIR}/${line}"
  done < "${AUTORUN_DIR}/${MANIFEST_NAME}"

  rm -f "${AUTORUN_DIR}/${MANIFEST_NAME}"
  echo "  removed: ${AUTORUN_DIR}/${MANIFEST_NAME}"
else
  # No manifest: fall back to the known default name, still marker-checked.
  remove_bundle "${AUTORUN_DIR}/${BUNDLE_NAME}"
fi

# ---------------------------------------------------------------------------
# Remove the trainer's own data files from the game directory
# ---------------------------------------------------------------------------

for data_file in "${GAME_DIR}/${CONFIG_NAME}" "${GAME_DIR}/${DISCOVERY_NAME}"; do
  if [[ -f "${data_file}" ]]; then
    rm -f "${data_file}"
    echo "  removed: ${data_file}"
    removed_any=1
  fi
done

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

echo ""

if [[ "${removed_any}" -eq 0 ]]; then
  echo "Nothing to remove — the trainer does not appear to be installed."
else
  echo "Uninstalled."
fi

echo ""
echo "Left untouched, as intended:"
echo "  ${GAME_DIR}/dinput8.dll"
echo "  ${GAME_DIR}/reframework/"
echo "  any other mods in ${AUTORUN_DIR}/"
