--[[--------------------------------------------------------------------------
  re7trainer.cheats.inventory — Infinite Items.

  THE API THIS USES IS REAL AND WAS READ OUT OF THE RUNNING GAME
  --------------------------------------------------------------
  From a live discovery dump (docs/DISCOVERY_RESULTS.md):

      app.Item
        M System.Int32  getStackNum()
        M System.Void   setStackNum(System.Int32)
        M System.Boolean reduceNum(? (2 params))   <-- consumption
        M app.ItemData  get_ItemData()

      app.ItemData
        F app.Item.ItemCategoryType Category           <-- the classification

      app.Item.ItemCategoryType
        Drug  Material  Shell                          <-- conserve these
        KeyItem  UsableKeyItem  DiscardableKeyItem     <-- NEVER touch these
        Weapon  StackWeapon  File  Map  SupplyBox  OtherItem

  THE SAFETY PRECONDITION IS THEREFORE SATISFIABLE
  ------------------------------------------------
  This project set a hard rule: Infinite Items must not be enabled unless the
  trainer can reliably tell a stackable consumable from a key item. The engine's
  own category enum provides exactly that distinction, so the rule is met with
  real game data rather than with a heuristic over item names.

  THE GATE IS ON EVERY SINGLE CALL
  --------------------------------
  The hook reads the category of the specific item being consumed and only
  suppresses the consumption when that category is in game.SAFE_CATEGORIES. It
  is not a global switch that happens to be safe most of the time -- a key item
  passing through the same method still gets consumed normally.

  This matters because RE7 key items gate puzzles. Duplicating one can make a
  run unrecoverable, and unlike a wrong health value that is not a state you can
  simply undo.

  FAIL CLOSED
  -----------
  If the category cannot be read for any reason, the item is treated as unsafe
  and the consumption proceeds normally. An unreadable category is precisely the
  case where a guess could touch a key item.

  THE HOOK IS PERMANENT. THE FLAG IS NOT.
  ---------------------------------------
  No unhook exists in this build, so the hook stays installed and a flag decides
  whether it does anything.

  WHAT IS DELIBERATELY NOT DONE
  -----------------------------
  No eager "restore every item every frame" loop. Such a loop would also undo
  legitimate removals -- combining two herbs into one stronger herb, handing an
  item to an NPC, dropping something -- and could break progression in ways that
  are hard to diagnose. Only the consumption of a safe item is prevented.
----------------------------------------------------------------------------]]

local logger = require("re7trainer.logger")
local state = require("re7trainer.state")
local safe = require("re7trainer.utils.safe_call")
local objects = require("re7trainer.utils.object_helpers")
local game = require("re7trainer.game")

local M = {}

M.NAME = "inventory"
M.LABEL = "Infinite Items"

--- Read by the hook on every call.
local enabled = false

local hook_ready = false

local HOOK_KEY = "app.Item.reduceNum"

--- Number of consumptions suppressed, for the debug panel. Purely diagnostic.
local suppressed = 0

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function M.initialize()
  enabled = false
  suppressed = 0

  if safe.type_definition("app.Item") == nil then
    state.mark_unsupported("inventory", "app.Item is not present in this build")
    logger.warn("Inventory", "Target type missing; Infinite Items will stay disabled.")
    return
  end

  -- The category gate is the precondition. Confirm the enum is reachable before
  -- claiming support -- if the category cannot be read, this cheat must not run
  -- at all, so that is checked here rather than discovered at consumption time.
  if safe.type_definition("app.ItemData") == nil then
    state.mark_unsupported("inventory",
      "app.ItemData missing, so item categories cannot be read safely")
    logger.warn("Inventory", "Cannot classify items; Infinite Items will stay disabled.")
    return
  end

  state.mark_supported("inventory",
    "app.ItemData.Category provides engine-level consumable/key-item classification")
  logger.info("Inventory", "Ready. Hook target: app.Item.reduceNum, gated on item category.")
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
  return "active (safe categories only, " .. tostring(suppressed) .. " suppressed)"
end

--- The hook body.
--
-- args layout, from the verified sdk.hook signature:
--   args[1] = REThreadContext*
--   args[2] = `this`  (the app.Item being consumed)
--   args[3..] = parameters
-- @param args table
local function on_reduce_num(args)
  -- Runs on the game thread holding the Lua lock, so the cheapest possible
  -- early-outs come first.
  if not enabled then
    return sdk.PreHookResult.CALL_ORIGINAL
  end
  if state.prefs.trainer_enabled ~= true then
    return sdk.PreHookResult.CALL_ORIGINAL
  end

  local item = safe.to_managed_object(args[2])
  if item == nil then
    return sdk.PreHookResult.CALL_ORIGINAL
  end

  -- The gate. Everything hinges on this call: it reads the engine's own
  -- category for THIS item and refuses anything that is not a known
  -- consumable. A key item reaching here is consumed exactly as normal.
  local item_safe, reason = game.is_safe_to_conserve(item)
  if not item_safe then
    -- Logged at a throttled rate -- an item consumed repeatedly while
    -- unclassified would otherwise flood the log.
    logger.throttled("inv:skip:" .. tostring(reason), 600, "debug", "Inventory",
                     "Not conserving: " .. tostring(reason))
    return sdk.PreHookResult.CALL_ORIGINAL
  end

  suppressed = suppressed + 1
  return sdk.PreHookResult.SKIP_ORIGINAL
end

local function ensure_hook()
  if hook_ready then
    return true, nil
  end

  local ok, detail = safe.hook_method(
    HOOK_KEY, "app.Item", "reduceNum", on_reduce_num, nil)

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
    -- Do not report success when the hook failed. The previous version of this
    -- module refused enabling outright; now that there is a real implementation,
    -- the equivalent guarantee is that a failed hook is a failed enable.
    logger.error("Inventory", "Could not hook reduceNum: " .. tostring(detail))
    return false, tostring(detail)
  end

  enabled = true
  logger.info("Inventory", "Enabled. Consumption of Drug/Material/Shell items is suppressed.")
  return true, nil
end

--- Stop suppressing consumption. Does not remove the hook.
function M.disable()
  enabled = false
  logger.info("Inventory", "Disabled. Normal item consumption restored.")
end

--- Per-frame work: refresh the readout only.
function M.update()
  if not M.is_supported() then
    return
  end
  if logger.frame() % 60 ~= 0 then
    return
  end

  -- count_safe_items walks the inventory, which is more expensive than the
  -- other cheats' readouts, so it runs at a quarter of their rate.
  local safe_count, total = game.count_safe_items()
  state.runtime.item_count = safe_count
  if total > 0 then
    logger.throttled("inv:survey", 1800, "debug", "Inventory",
                     string.format("%d of %d carried items are conservable.", safe_count, total))
  end
end

--- @return table|nil
function M.readout()
  if state.runtime.item_count == nil then
    return nil
  end
  return { current = state.runtime.item_count }
end

--- Enable the alternative consumption path.
--
-- app.Item.reduceNum is the clear decrement operation and is the default. If
-- testing shows that consuming a herb does not go through it, app.Item.useItem
-- is the other candidate. This exists so that switching is a one-line change
-- during testing rather than a code edit.
--
-- Not wired to the UI yet: the correct hook point should be established by
-- observation first, not offered as a choice the user has to guess at.
-- @return string name of the method currently hooked
function M.hooked_method()
  return "reduceNum"
end

function M.reset()
  enabled = false
  suppressed = 0
  -- hook_ready not cleared; the hook is permanent.
end

return M
