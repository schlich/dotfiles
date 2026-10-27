-- The niri hint line. `keymap.nu hints` follows niri's event stream and
-- publishes the focus context and its keys to
-- $XDG_RUNTIME_DIR/niri-hints/status.json; this widget shows the context as
-- the mode and lists the keys that work in it, so they are always on screen.

local statusPath = (noctalia.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/niri-hints/status.json"

local function readStatus()
  local raw = noctalia.readFile(statusPath)
  local status = raw and noctalia.json.decode(raw)
  return status or { mode = "normal", hints = {} }
end

function update()
  noctalia.setUpdateInterval(250)
  local status = readStatus()
  local parts = {}
  local tooltip = {}
  for _, hint in ipairs(status.hints or {}) do
    table.insert(parts, hint.key .. " " .. hint.label)
    table.insert(tooltip, { hint.key, hint.label })
  end
  barWidget.setGlyph("keyboard")
  barWidget.setGlyphColor("primary")
  barWidget.setColor("on_surface")
  barWidget.setText("[" .. status.mode .. "]  " .. table.concat(parts, " · "))
  barWidget.setTooltip(tooltip)
end
