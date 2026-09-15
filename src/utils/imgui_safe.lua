--[[--------------------------------------------------------------------------
  re7trainer.utils.imgui_safe — defensive wrappers around REFramework's imgui
  bindings.

  WHY THIS IS NOT IN THE ui/ FOLDER
  ---------------------------------
  It is not a screen. It is a safety wrapper, the same category as safe_call and
  object_helpers, so it lives with them.

  WHY IT EXISTS AT ALL
  --------------------
  Two concrete problems, both of which have bitten real REFramework mods:

  1. RETURN SHAPE. imgui.checkbox is documented in some places as returning just
     the new value and in others as returning (changed, new_value). Getting this
     wrong does not throw — it silently produces a checkbox that never toggles,
     or one that toggles every frame. W.checkbox normalises both shapes.

  2. ABSENT BINDINGS. This build does not have begin_child, bullet_text or
     colored_text (verified absent from the installed dinput8.dll). Calling one
     is an error. Every wrapper here checks the binding exists first and
     degrades to plain text rather than throwing inside a draw callback, where
     an error is far more disruptive than a missing widget.

  Everything here is a thin pass-through. No layout opinions, no styling.
----------------------------------------------------------------------------]]

local logger = require("re7trainer.logger")

local M = {}

--- Is the imgui table reachable?
-- @return boolean
function M.available()
  return type(imgui) == "table"
end

--- Is a specific binding present in this build?
-- @param name string
-- @return boolean
function M.has(name)
  return type(imgui) == "table" and type(imgui[name]) == "function"
end

--- Call an imgui function, swallowing errors.
-- A throwing draw callback can take down the whole menu, so nothing here is
-- allowed to propagate.
-- @param name string
-- @return boolean ok, any result
local function invoke(name, ...)
  if not M.has(name) then
    return false, nil
  end
  local ok, result = pcall(imgui[name], ...)
  if not ok then
    logger.throttled("imgui:" .. name, 600, "error", "Error",
                     "imgui." .. name .. " threw: " .. tostring(result))
    return false, nil
  end
  return true, result
end

-- ---------------------------------------------------------------------------
-- Text and layout
-- ---------------------------------------------------------------------------

--- Plain label text.
-- @param text string
function M.text(text)
  invoke("text", tostring(text))
end

--- Label/value pair on one line.
-- @param label string
-- @param value string
function M.field(label, value)
  M.text(tostring(label) .. ": " .. tostring(value))
end

--- Label/value pair with the value pushed to the right edge.
-- @param label string
-- @param value string
function M.field_right(label, value)
  M.text(tostring(label))
  invoke("same_line")
  invoke("text", tostring(value))
end

--- Horizontal rule.
function M.separator()
  invoke("separator")
end

--- Keep the next widget on the current line.
function M.same_line()
  invoke("same_line")
end

--- Vertical spacing.
function M.spacing()
  invoke("spacing")
end

--- Draw text that reads as de-emphasised. Falls back to parenthesised plain
--- text because colored_text is absent from this build.
-- @param text string
function M.muted(text)
  M.text("(" .. tostring(text) .. ")")
end

-- ---------------------------------------------------------------------------
-- Interactive widgets
-- ---------------------------------------------------------------------------

--- Normalised checkbox.
--
-- Handles both binding shapes:
--   (changed, new_value)  -> returns changed, new_value
--   (new_value)           -> returns value ~= old, new_value
--
-- @param label string
-- @param value boolean
-- @return boolean changed, boolean new_value
function M.checkbox(label, value)
  value = value == true

  local ok, a, b = pcall(function()
    return imgui.checkbox(label, value)
  end)

  if not ok then
    logger.throttled("imgui:checkbox", 600, "error", "Error",
                     "imgui.checkbox threw: " .. tostring(a))
    return false, value
  end

  -- Two-return shape: a is "changed", b is the new value.
  if type(b) == "boolean" then
    return a == true, b
  end

  -- One-return shape: a is the new value.
  if type(a) == "boolean" then
    return a ~= value, a
  end

  return false, value
end

--- Button.
-- @param label string
-- @return boolean pressed
function M.button(label)
  local ok, pressed = invoke("button", label)
  if not ok then
    return false
  end
  return pressed == true
end

--- A button that renders as unavailable and explains why on hover.
--
-- This is how the UI communicates "this cheat exists but is not usable on this
-- build" without pretending it works. The reason is surfaced rather than
-- hidden, which is the whole point.
-- @param label string
-- @param reason string
function M.button_disabled(label, reason)
  -- Drawn as ordinary text rather than a greyed-out button: this build has no
  -- begin_disabled, and a tooltip alone would still look clickable.
  M.text("[ ] " .. tostring(label) .. "  -- " .. tostring(reason))
end

--- Horizontal rule with a caption.
-- @param caption string
function M.section(caption)
  M.spacing()
  M.separator()
  M.text(tostring(caption))
  M.separator()
end

--- Collapsible section header. Returns true when the section is open.
--
-- Uses collapsing_header rather than tree_node on purpose.
--
-- imgui's tree_node must be paired with a tree_pop, and if a section body
-- returns early or raises, that pairing is broken and the whole menu renders
-- progressively more indented until it is unusable. collapsing_header has no
-- matching pop call, so it is impossible to unbalance. That matters more here
-- than the slightly nicer tree affordance, because this UI draws every frame
-- inside REFramework's own menu.
--
-- @param label string
-- @return boolean open
function M.section_begin(label)
  local ok, is_open = invoke("collapsing_header", label)
  if not ok then
    return false
  end
  return is_open == true
end

-- ---------------------------------------------------------------------------
-- Read-only indicators
-- ---------------------------------------------------------------------------

--- Small on/off indicator. Text-based on purpose: a coloured dot would need
--- colored_text, which this build does not have.
-- @param label string
-- @param enabled boolean
-- @return string the rendered line, for callers that want to compose it
function M.indicator(label, enabled)
  local mark = enabled and "[ON] " or "[--] "
  M.text(mark .. tostring(label))
  return mark .. tostring(label)
end

--- Fraction bar, clamped to 0..1.
-- @param fraction number
-- @param overlay string|nil
function M.progress(fraction, overlay)
  if type(fraction) ~= "number" then
    return
  end
  if fraction < 0 then fraction = 0 end
  if fraction > 1 then fraction = 1 end
  invoke("progress_bar", fraction, overlay or "")
end

return M
