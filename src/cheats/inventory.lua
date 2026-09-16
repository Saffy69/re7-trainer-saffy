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

--- The inventory-level decrement, which is the route the item actually leaves
--- by. Blocking destroyItem alone was not enough.
local HOOK_KEY_REDUCE = "app.Inventory.reduceItem"

local enabled = false
local hook_ready = false

--- Whether reduceItem -- the hook that actually matters -- installed.
local reduce_hooked = false

--- Last observed reduceItem arguments, for the debug panel. Empty until the
--- game calls it, and the single most useful thing to know if this hook is
--- passing through when it should not be.
local last_args = ""

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

  -- Type-level check only. See the note in cheats/health.lua: initialize() runs
  -- at script load, in the main menu, where there is no inventory to read.
  if safe.type_definition("app.ItemData") == nil then
    state.mark_unsupported("inventory",
      "app.ItemData missing, so item categories cannot be read safely")
    logger.warn("Inventory", "Cannot classify items; Infinite Items will stay disabled.")
    return
  end

  state.mark_supported("inventory",
    "item classification is available (validated against live items at enable time)")
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

--- Count how many carried items the gate currently considers conservable.
--
-- Used at enable time as a live sanity check: if nothing in the inventory is
-- conservable, enabling is pointless and the reason should say so rather than
-- leaving a toggle that appears on and does nothing.
-- @return number conservable, number total
local function count_conservable()
  local conservable, total = 0, 0

  for _, info in ipairs(game.item_infos()) do
    local item = objects.get(info, "Item")
    if item ~= nil then
      total = total + 1
      if game.is_safe_to_conserve(item) then
        conservable = conservable + 1
      end
    end
  end

  return conservable, total
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

--- The reduceItem hook: the inventory-level decrement.
--
-- WHY THIS AND NOT destroyItem
-- ----------------------------
-- Blocking destroyItem was confirmed to work -- the panel read "2 blocked" --
-- and the items were still consumed. So destroyItem is a lifecycle
-- notification, not the removal itself; the item leaves the inventory by
-- another route. reduceItem is that route, and the probe confirmed it fires on
-- consumption.
--
-- THE GATING PROBLEM, AND HOW IT IS HANDLED
-- -----------------------------------------
-- reduceItem takes three parameters and their meaning is not known -- they
-- could be an item, an item id, a count. Rather than guess, each parameter is
-- examined: anything that resolves to a real app.Item is classified through the
-- same gate as everywhere else, and if NONE of them can be identified as a
-- conservable item, the call passes through untouched.
--
-- That is the fail-closed direction. An unidentifiable call is never blocked,
-- because blocking the wrong one could consume a key item or desync the
-- inventory.
--
-- args layout, from the verified sdk.hook signature:
--   args[1] = REThreadContext*, args[2] = `this` (the app.Inventory)
--   args[3..] = parameters
-- @param args table
local function on_reduce_item(args)
  if not enabled or state.prefs.trainer_enabled ~= true then
    safe.note_invocation(HOOK_KEY, "pass (disabled)")
    return sdk.PreHookResult.CALL_ORIGINAL
  end

  -- Examine each parameter. The first one that looks like an app.Item decides.
  local examined = {}

  for i = 3, 5 do
    local raw = args[i]
    if raw ~= nil then
      local as_object = safe.to_managed_object(raw)

      if as_object ~= nil then
        local type_name = objects.type_name(as_object) or "?"
        examined[#examined + 1] = string.format("[%d]=%s", i, type_name)

        if type_name == "app.Item" or type_name:find("Item", 1, true) then
          local item_safe, reason = game.is_safe_to_conserve(as_object)

          if item_safe then
            blocks = blocks + 1
            safe.note_invocation(HOOK_KEY, "SKIP (" .. tostring(reason) .. ")")
            return sdk.PreHookResult.SKIP_ORIGINAL
          end

          -- A readable item that is not conservable: let it through, and say so.
          safe.note_invocation(HOOK_KEY, "pass (" .. tostring(reason) .. ")")
          return sdk.PreHookResult.CALL_ORIGINAL
        end
      else
        -- Not a managed object -- record it as a plain value so the panel shows
        -- what the parameters actually are.
        local as_number = safe.to_number(raw)
        examined[#examined + 1] = string.format("[%d]=%s", i,
          as_number ~= nil and tostring(as_number) or type(raw))
      end
    end
  end

  last_args = table.concat(examined, " ")

  -- Nothing identifiable. Pass through rather than risk blocking the wrong
  -- thing.
  safe.note_invocation(HOOK_KEY, "pass (unidentified args)")
  return sdk.PreHookResult.CALL_ORIGINAL
end

--- Install both hooks.
--
-- Declared after the callbacks it references: a Lua local is not in scope
-- before its declaration, and putting this above them compiles fine and then
-- fails at runtime passing nil to sdk.hook.
local function ensure_hook()
  if hook_ready then
    return true, nil
  end

  -- Both hooks are needed, and they do different jobs:
  --
  --   Item.destroyItem      -- the item's own lifecycle. Confirmed to fire, and
  --                            blocking it was confirmed to work ("2 blocked")
  --                            yet the item was still consumed, so this alone
  --                            is not sufficient.
  --   Inventory.reduceItem  -- the inventory-level decrement, which is the route
  --                            the item actually leaves by.
  --
  -- At least one must install for the cheat to claim it can work.
  local destroy_ok, destroy_detail = safe.hook_method(
    HOOK_KEY, "app.Item", "destroyItem", on_destroy_item, nil)

  local reduce_ok, reduce_detail = safe.hook_method(
    HOOK_KEY_REDUCE, "app.Inventory", "reduceItem", on_reduce_item, nil)

  if not destroy_ok and not reduce_ok then
    return false, string.format("destroyItem: %s | reduceItem: %s",
                                tostring(destroy_detail), tostring(reduce_detail))
  end

  reduce_hooked = reduce_ok
  hook_ready = true
  return true, nil
end

--- @return boolean ok, string message
function M.enable()
  if not M.is_supported() then
    local reason = state.runtime.inventory_reason or "not available"
    logger.warn("Inventory", "Refusing to enable: " .. reason)
    return false, reason
  end

  -- Live check. If the inventory cannot be read, or nothing in it is
  -- conservable, say so instead of leaving a toggle that appears on and does
  -- nothing.
  local conservable, total = count_conservable()

  if total == 0 then
    local reason = "no inventory readable yet -- load into gameplay and try again"
    state.runtime.inventory_reason = reason
    logger.warn("Inventory", "Cannot enable: " .. reason)
    return false, reason
  end

  if conservable == 0 then
    local reason = string.format(
      "none of the %d carried items can be classified as a consumable, so nothing would be conserved",
      total)
    state.runtime.inventory_reason = reason
    logger.warn("Inventory", "Cannot enable: " .. reason)
    return false, reason
  end

  local ok, detail = ensure_hook()
  if not ok then
    logger.error("Inventory", "Could not hook destroyItem: " .. tostring(detail))
    return false, tostring(detail)
  end

  enabled = true
  state.runtime.inventory_reason =
    string.format("%d of %d carried items are conservable", conservable, total)

  M.refresh_baseline()
  logger.info("Inventory", "Enabled. "
    .. string.format("%d of %d carried items will be conserved.", conservable, total))
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

--- What reduceItem last received, for the debug panel.
--
-- If the cheat is passing through when it should be blocking, this is the line
-- that says why: it shows which parameters arrived and what each was
-- interpreted as.
-- @return string
function M.reduce_args()
  return last_args
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
