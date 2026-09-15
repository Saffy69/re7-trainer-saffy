--[[--------------------------------------------------------------------------
  re7trainer.cheats.inventory — Infinite Items.

  THE HIGHEST-RISK CHEAT IN THIS PROJECT
  --------------------------------------
  Getting this one wrong does not just fail to work — it can corrupt a save by
  duplicating a key item, which in RE7 can make a puzzle unsolvable and the run
  unrecoverable. So this module is deliberately the most conservative of the
  three, and it ships with a hard precondition rather than a best effort.

  THE PRECONDITION
  ----------------
  Before Infinite Items may be enabled, discovery must establish BOTH:

    (a) a readable and writable quantity for a stackable consumable, AND
    (b) a reliable way to tell a stackable consumable from a key/quest item.

  If (b) cannot be established, the correct outcome is a documented limitation
  and a permanently disabled toggle. A version of this cheat that cannot tell
  a herb from a keycard is a version that will eventually duplicate a keycard.

  THE REQUIREMENT THAT SHAPES THE DESIGN
  --------------------------------------
  Five herbs stay five herbs after using one.

      NOT:  set quantity to 999999
      YES:  quantity after use == quantity before use

  So this is a conservation problem, not a maximisation problem. It also means
  we must be careful about *when* we act. If we restore the quantity eagerly on
  every frame, picking up an item and then using it works fine — but a game
  action that legitimately removes an item entirely (combining two herbs into
  one stronger herb, or handing an item to an NPC) would be undone, which could
  itself break progression.

  STRATEGY, in preference order
  -----------------------------
    1. PREVENT CONSUMPTION ON THE CONSUMABLE PATH ONLY. Hook the specific
       operation that consumes one unit of a stackable item, and skip it. Narrow
       by construction: it never touches add, remove, combine, or transfer.
    2. RESTORE ON DECREASE, CONSUMABLES ONLY. Watch the quantity of items we
       have positively classified as stackable consumables; if one drops, put
       it back. Broader than (1) and cannot help with a use that removes the
       entry entirely.
    3. NOT IMPLEMENTED. There is no third fallback. If neither (1) nor (2) is
       available, the cheat stays off.

  WHAT THIS MODULE WILL NOT DO, EVER
  ----------------------------------
    * touch items it has not classified as stackable consumables
    * touch the item box rather than the carried inventory, unless discovery
      shows the same safe classification applies there
    * write to save files
    * add items that were not already present (no duplication of anything, ever)
----------------------------------------------------------------------------]]

local logger = require("re7trainer.logger")
local state = require("re7trainer.state")

local M = {}

M.NAME = "inventory"
M.LABEL = "Infinite Items"

--- "hook_consume" | "restore_on_decrease", or nil until discovered.
local strategy = nil

--- Set of item identifiers positively classified as stackable consumables.
--- Populated only by discovery. An empty set means "nothing is safe to touch",
--- which is the correct default.
local safe_items = {}

--- Shadow copy of quantities we are tracking, so update() can spot a decrease.
--- Keys are item identifiers, values are the last observed quantity.
local snapshot = {}

--- Handle to whatever we hooked, so disable() can undo it.
local hook_handle = nil

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

--- Called once at startup. Never touches the game.
function M.initialize()
  strategy = nil
  safe_items = {}
  snapshot = {}
  hook_handle = nil
  logger.info("Inventory", "Module initialised. Awaiting discovery — no item API is known yet.")
end

--- @return boolean
function M.is_supported()
  if state.runtime.inventory_supported ~= true or strategy == nil then
    return false
  end
  -- Refuse to report support while nothing has been classified as safe. This
  -- is the guard that stops the cheat from ever running in an "I will figure
  -- out which items are safe as I go" mode.
  return next(safe_items) ~= nil
end

--- @return string
function M.status()
  if M.is_supported() then
    local count = 0
    for _ in pairs(safe_items) do
      count = count + 1
    end
    return "active via '" .. tostring(strategy) .. "' (" .. count .. " item(s) classified safe)"
  end
  return state.runtime.inventory_reason or "not yet discovered"
end

--- @return boolean ok, string message
function M.enable()
  if state.runtime.inventory_supported ~= true then
    local reason = state.runtime.inventory_reason or "not yet discovered"
    logger.warn("Inventory", "Refusing to enable Infinite Items: " .. reason)
    return false, reason
  end

  if next(safe_items) == nil then
    local reason = "no items have been classified as safe stackable consumables"
    logger.warn("Inventory", "Refusing to enable Infinite Items: " .. reason
                          .. ". Touching unclassified items risks duplicating key items.")
    return false, reason
  end

  if strategy == "hook_consume" then
    -- TODO(discovery): sdk.hook the verified consume operation, and inside the
    -- pre-callback check the item identifier against `safe_items` before
    -- deciding to skip the original call.
    logger.warn("Inventory", "Hook strategy selected but no verified consume method to hook.")
    return false, "hook strategy has no verified target"

  elseif strategy == "restore_on_decrease" then
    -- TODO(discovery): prime `snapshot` from the verified quantity accessor for
    -- every item in `safe_items`.
    logger.warn("Inventory", "Restore strategy selected but no verified quantity accessor.")
    return false, "restore strategy has no verified accessor"
  end

  logger.warn("Inventory", "No usable strategy. This should be unreachable.")
  return false, "no strategy"
end

--- Turn the cheat off. Safe to call when never enabled, and safe twice.
function M.disable()
  if hook_handle ~= nil then
    -- TODO(discovery): unhook here once a hook exists.
    hook_handle = nil
  end

  snapshot = {}
  logger.info("Inventory", "Disabled. Normal item consumption restored.")
end

--- Per-frame work. Returns immediately when unsupported.
function M.update()
  if not M.is_supported() then
    return
  end
  if not state.is_active() then
    return
  end

  -- TODO(discovery): dispatch on `strategy` here. Intentionally empty — see the
  -- module header. In particular, do not add an eager "restore everything every
  -- frame" loop: that would undo legitimate item removal (combining, handing
  -- over) and can break progression.
end

--- @return table|nil
function M.readout()
  if state.runtime.item_count == nil then
    return nil
  end
  return { tracked = state.runtime.item_count }
end

--- Called by discovery once a real strategy is established.
-- @param chosen string  "hook_consume" | "restore_on_decrease"
-- @param classified table array of item identifiers proven safe to conserve
-- @param reason string
function M.set_strategy(chosen, classified, reason)
  strategy = chosen
  safe_items = {}
  for _, id in ipairs(classified or {}) do
    safe_items[id] = true
  end
  state.mark_supported("inventory", reason or ("strategy: " .. tostring(chosen)))
  logger.info("Inventory", "Strategy established: " .. tostring(chosen)
                        .. " with " .. tostring(#(classified or {})) .. " classified item(s).")
end

--- Reset on scene change / script reset. Clears the safe set too, so a new
--- scenario never inherits classifications from the previous one.
function M.reset()
  strategy = nil
  safe_items = {}
  snapshot = {}
  hook_handle = nil
end

return M
