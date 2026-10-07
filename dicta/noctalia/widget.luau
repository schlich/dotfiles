-- dicta's recorder light. `dicta` publishes its state to
-- $XDG_RUNTIME_DIR/dicta/status.json; this widget names the mode and the keys
-- that work in it: REC with the elapsed time and the stop and discard keys
-- while recording, then transcription, then the takes waiting for an agent.

local dicta = "@dicta@"
local statusPath = (noctalia.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/dicta/status.json"

local function readStatus()
  local raw = noctalia.readFile(statusPath)
  local status = raw and noctalia.json.decode(raw)
  return status or { mode = "idle", pending = 0 }
end

local function clock(seconds)
  return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

function update()
  noctalia.setUpdateInterval(500)
  local status = readStatus()
  if status.mode == "recording" then
    local elapsed = math.max(0, os.time() - (status.started or os.time()))
    barWidget.setGlyph("player-record")
    barWidget.setGlyphColor("error")
    barWidget.setColor("error")
    barWidget.setText("REC " .. clock(elapsed) .. "   Mod+M stop · Mod+Shift+M discard")
    barWidget.setTooltip({ { "Mod+M", "stop and transcribe" }, { "Mod+Shift+M", "discard this take" } })
  elseif status.mode == "transcribing" then
    barWidget.setGlyph("loader")
    barWidget.setGlyphColor("primary")
    barWidget.setColor("primary")
    barWidget.setText("transcribing")
    barWidget.setTooltip({ { "Mod+M", "record another take" } })
  else
    local pending = status.pending or 0
    barWidget.setGlyph("microphone")
    barWidget.setGlyphColor("on_surface")
    barWidget.setColor("on_surface")
    barWidget.setText(pending > 0 and (pending .. " pending") or "")
    barWidget.setTooltip({
      { "Mod+M", "record a take" },
      { "Right-click", "copy pending notes" },
    })
  end
end

function onClick()
  noctalia.runAsync(dicta .. " toggle")
end

function onRightClick()
  noctalia.runAsync(dicta .. " brief --copy --mark")
end
