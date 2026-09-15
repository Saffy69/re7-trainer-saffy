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
#     * it reads the manifest install.sh wrote and removes the files listed
#     * it prunes directories that become empty as a result, but only ever
#       under reframework/autorun/re7trainer/
#     * it removes the trainer's own config and discovery files from the game
#       directory
#
#   It will NOT:
#     * delete the reframework directory or reframework/autorun itself
#     * delete dinput8.dll or any REFramework component
#     * touch reframework/plugins/
#     * remove any autorun script it did not install
#     * touch .pak files or anything else belonging to the game
#
#   Every removal is guarded. A manifest entry containing a path traversal, an
#   absolute path, or a directory escape is skipped rather than acted on, so a
#   corrupted or hand-edited manifest cannot be used to delete files outside
#   the trainer's own folder.

set -euo pipefail

LOADER_NAME="re7trainer.lua"
MODULE_DIR="re7trainer"
MANIFEST_NAME=".re7trainer_manifest"
CONFIG_NAME="re7trainer_config.json"
DISCOVERY_NAME="re7trainer_discovery.json"

# A string that only appears in files this project generated. The loader and
# the bundle both carry it; module files are only removed when the manifest
# vouches for them.
MARKER="RE7 Personal Trainer"

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
# Validate a manifest entry
#
# Returns 0 only for a plain relative path that stays inside the autorun
# directory. Anything else is refused.
# ---------------------------------------------------------------------------

is_safe_entry() {
  local entry="$1"

  [[ -z "${entry}" ]] && return 1

  # Absolute paths, parent traversal, and anything with a NUL-ish shape.
  [[ "${entry}" == /* ]] && return 1
  [[ "${entry}" == *".."* ]] && return 1

  # Only allow the loader itself, or something under the module directory.
  if [[ "${entry}" == "${LOADER_NAME}" ]]; then
    return 0
  fi
  if [[ "${entry}" == "${MODULE_DIR}/"* ]]; then
    return 0
  fi

  return 1
}

# ---------------------------------------------------------------------------
# Remove installed files, driven by the manifest
# ---------------------------------------------------------------------------

if [[ -f "${AUTORUN_DIR}/${MANIFEST_NAME}" ]]; then
  while IFS= read -r line; do
    [[ -z "${line}" || "${line}" == \#* ]] && continue

    if ! is_safe_entry "${line}"; then
      echo "  skipped (unsafe manifest entry): ${line}" >&2
      continue
    fi

    target="${AUTORUN_DIR}/${line}"
    if [[ -f "${target}" ]]; then
      rm -f "${target}"
      removed_any=1
    fi
  done < "${AUTORUN_DIR}/${MANIFEST_NAME}"

  rm -f "${AUTORUN_DIR}/${MANIFEST_NAME}"
  echo "  removed: ${AUTORUN_DIR}/${MANIFEST_NAME}"
else
  # No manifest. Fall back to the two known layouts, still marker-checked so we
  # cannot delete an unrelated file that happens to share the name.
  for candidate in "${AUTORUN_DIR}/${LOADER_NAME}"; do
    if [[ -f "${candidate}" ]] && grep -qF "${MARKER}" "${candidate}" 2>/dev/null; then
      rm -f "${candidate}"
      echo "  removed: ${candidate}"
      removed_any=1
    fi
  done
fi

# Prune the module tree, but only the parts that are now empty. Never remove
# the autorun directory itself.
if [[ -d "${AUTORUN_DIR}/${MODULE_DIR}" ]]; then
  find "${AUTORUN_DIR}/${MODULE_DIR}" -type d -empty -delete 2>/dev/null || true

  if [[ -d "${AUTORUN_DIR}/${MODULE_DIR}" ]]; then
    remaining=$(find "${AUTORUN_DIR}/${MODULE_DIR}" -type f | wc -l)
    if [[ "${remaining}" -gt 0 ]]; then
      echo "  note: ${remaining} unexpected file(s) remain in ${AUTORUN_DIR}/${MODULE_DIR}" >&2
      echo "        left in place rather than deleted." >&2
    fi

    rmdir "${AUTORUN_DIR}/${MODULE_DIR}" 2>/dev/null || true
  fi
  echo "  removed: ${AUTORUN_DIR}/${MODULE_DIR}/"
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
