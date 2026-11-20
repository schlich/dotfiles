-- One navigation hint. `keymap.nu hints` follows niri's event stream and
-- publishes the mode and a hint per seat (the six directions, `in` and
-- `out`) to $XDG_RUNTIME_DIR/niri-hints/status.json. Each instance of this
-- widget shows one seat, on the bar its direction faces, so a key is read
-- where its motion goes. The `in` seat also names the mode.

local statusPath = (noctalia.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/niri-hints/status.json"
local seat = tostring(noctalia.getConfig("seat") or "in")

local function readStatus()
  local raw = noctalia.readFile(statusPath)
  local status = raw and noctalia.json.decode(raw)
  return status or { mode = "NORMAL", seats = {} }
end

function update()
  noctalia.setUpdateInterval(250)
  local status = readStatus()
  local hint = (status.seats or {})[seat]
  if not hint then
    barWidget.setText("")
    return
  end
  -- A vertical bar has room for the key alone; the tooltip has the rest.
  local vertical = type(barWidget.isVertical) == "function" and barWidget.isVertical()
  local text = if vertical then hint.key else hint.text
  if seat == "in" and not vertical then
    text = "[" .. status.mode .. "]  " .. text
  end
  barWidget.setText(text)
  -- The seat of the focused area is lit.
  barWidget.setColor(if hint.here then "primary" else "on_surface")
  barWidget.setTooltip(hint.tips or {})
end
