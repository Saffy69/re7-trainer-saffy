--[[--------------------------------------------------------------------------
  re7trainer.cheats.inventory — Infinite Items.

  WHAT THE IN-GAME PROBE ESTABLISHED
  ----------------------------------
  Consuming an item fired:

      app.Item.destroyItem          x1
      app.Inventory.reduceItem      x1

  and app.Item.reduceNum -- which the first implementation hooked -- never
  fired at all. So consumption does not go through the per-item decrement the
  name suggested.

  THE TWO HALVES OF THIS CHEAT
  ----------------------------
  1. A HOOK on app.Item.destroyItem, skipped when the item's category is one of
     the conservable ones. destroyItem takes no arguments, so `this` is
     available at args[2] and the category can be read off it directly. This is
     confirmed to be on the consumption path and confirmed to be callable,
     which is more than could be said for the previous target.

  2. A per-frame RESTORE of stack counts, for items that lose a unit without
     being destroyed outright.

  Both are needed. The hook alone would leave a stack decremented but present;
  the restore alone could not resurrect an item that had already been removed
  from the inventory, which is exactly what happened in the first in-game test.

  THE SAFETY GATE IS UNCHANGED AND APPLIES TO BOTH HALVES
  -------------------------------------------------------
  Only Drug, Material and Shell are ever conserved. Key items -- KeyItem,
  UsableKeyItem, DiscardableKeyItem -- are consumed normally even while the
  cheat is on, because duplicating one can make a run unrecoverable. If a
  category cannot be read, the item is treated as unsafe and nothing is done to
  it. Both the hook and the restore path call the same gate.
----------------------------------------------------------------------------]]

local logger = require("re7trainer.logger")
local state = require("re7trainer.state")
local safe = require("re7trainer.utils.safe_call")
local objects = require("re7trainer.utils.object_helpers")
local game = require("re7trainer.game")

local M = {}

M.NAME = "inventory"
M.LABEL = "Infinite Items"

local HOOK_KEY = "app.Item.destroyItem"

local enabled = false
local hook_ready = false

--- itemDataID -> last observed stack count.
local baseline = {}

local restores = 0
local blocks = 0

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function M.initialize()
  enabled = false
  hook_ready = false
  baseline = {}
  restores = 0
  blocks = 0

  if safe.type_definition("app.Item") == nil then
    state.mark_unsupported("inventory", "app.Item is not present in this build")
    return
  end

  if safe.type_definition("app.ItemData") == nil then
    state.mark_unsupported("inventory",
      "app.ItemData missing, so item categories cannot be read safely")
    logger.warn("Inventory", "Cannot classify items; Infinite Items will stay disabled.")
    return
  end

  state.mark_supported("inventory",
    "item categories are readable, so consumables can be told from key items")
  logger.info("Inventory", "Ready. Guarding destroyItem and restoring stack counts.")
end

--- @return boolean
function M.is_supported()
  return state.runtime.inventory_supported == true
end

--- @return string
function M.status()
  if not M.is_supported() then
    return state.runtime.inventory_reason or "not available"
  end
  if not enabled then
    return "ready (off)"
  end
  return string.format("active (%d blocked, %d restored)", blocks, restores)
end

--- The destroyItem hook.
--
-- args layout, from the verified sdk.hook signature:
--   args[1] = REThreadContext*, args[2] = `this` (the app.Item)
-- @param args table
local function on_destroy_item(args)
  if not enabled or state.prefs.trainer_enabled ~= true then
    safe.note_invocation(HOOK_KEY, "pass (disabled)")
    return sdk.PreHookResult.CALL_ORIGINAL
  end

  local item = safe.to_managed_object(args[2])
  if item == nil then
    safe.note_invocation(HOOK_KEY, "pass (no item)")
    return sdk.PreHookResult.CALL_ORIGINAL
  end

  local item_safe, reason = game.is_safe_to_conserve(item)
  if not item_safe then
    safe.note_invocation(HOOK_KEY, "pass (" .. tostring(reason) .. ")")
    return sdk.PreHookResult.CALL_ORIGINAL
  end

  blocks = blocks + 1
  safe.note_invocation(HOOK_KEY, "SKIP (destroy blocked)")
  return sdk.PreHookResult.SKIP_ORIGINAL
end

local function ensure_hook()
  if hook_ready then
    return true, nil
  end

  local ok, detail = safe.hook_method(
    HOOK_KEY, "app.Item", "destroyItem", on_destroy_item, nil)

  if ok then
    hook_ready = true
  end
  return ok, detail
end

--- @return boolean ok, string message
function M.enable()
  if not M.is_supported() then
    local reason = state.runtime.inventory_reason or "not available"
    logger.warn("Inventory", "Refusing to enable: " .. reason)
    return false, reason
  end

  local ok, detail = ensure_hook()
  if not ok then
    logger.error("Inventory", "Could not hook destroyItem: " .. tostring(detail))
    return false, tostring(detail)
  end

  enabled = true
  M.refresh_baseline()
  logger.info("Inventory", "Enabled. Drug/Material/Shell items will not be consumed.")
  return true, nil
end

function M.disable()
  enabled = false
  baseline = {}
  logger.info("Inventory", "Disabled. Normal item consumption restored.")
end

-- ---------------------------------------------------------------------------
-- Stack tracking
-- ---------------------------------------------------------------------------

--- Record the current stack count of every conservable item.
local function refresh_baseline()
  baseline = {}

  for _, info in ipairs(game.item_infos()) do
    local item = objects.get(info, "Item")
    if item ~= nil and game.is_safe_to_conserve(item) then
      local id = objects.get(item, "ItemDataID")
      local count = game.item_stack(item)
      if type(id) == "string" and count ~= nil then
        baseline[id] = count
      end
    end
  end
end

M.refresh_baseline = refresh_baseline

--- Per-frame work: put back any stack that lost a unit.
function M.update()
  if not M.is_supported() then
    return
  end

  local infos = game.item_infos()
  if #infos == 0 then
    return
  end

  if not enabled or state.prefs.trainer_enabled ~= true then
    refresh_baseline()
    return
  end

  local safe_seen = 0
  local tracked = 0

  for _, info in ipairs(infos) do
    local item = objects.get(info, "Item")
    if item ~= nil then
      tracked = tracked + 1

      local is_safe, _ = game.is_safe_to_conserve(item)
      if is_safe then
        safe_seen = safe_seen + 1

        local id = objects.get(item, "ItemDataID")
        local count = game.item_stack(item)

        if type(id) == "string" and count ~= nil then
          local previous = baseline[id]

          if previous == nil then
            baseline[id] = count
          elseif count < previous then
            if game.set_item_stack(item, previous) then
              restores = restores + 1
            end
          else
            -- Same or higher: a pickup or a combine result. Accept it.
            baseline[id] = count
          end
        end
      end
    end
  end

  state.runtime.item_count = safe_seen

  logger.throttled("inv:survey", 1800, "debug", "Inventory",
                   string.format("%d of %d carried items are conservable.", safe_seen, tracked))
end

--- @return table|nil
function M.readout()
  if state.runtime.item_count == nil then
    return nil
  end
  return { current = state.runtime.item_count }
end

function M.reset()
  enabled = false
  baseline = {}
  restores = 0
  blocks = 0
  -- hook_ready is not cleared: the hook is permanent in this build, so a later
  -- enable() must not try to install a second one.
end

return M
