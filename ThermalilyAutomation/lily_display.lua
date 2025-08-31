-- lily_display.lua
-- Shows all lily cooldowns received over rednet ("thermalily-status").
-- Uses a connected monitor if found; else draws in terminal.

local PROTO = "thermalily-status"

-- Open any wireless modem
local function openAnyWireless()
  for _, s in ipairs({"left","right","top","bottom","front","back"}) do
    if peripheral.getType(s) == "modem" and peripheral.call(s,"isWireless") then
      if not rednet.isOpen(s) then rednet.open(s) end
      return true
    end
  end
  return false
end
assert(openAnyWireless(), "Attach a wireless modem.")

-- Find an attached monitor (optional)
local mon = peripheral.find("monitor")
if mon then
  pcall(function() mon.setTextScale(0.5) end)
end

local function cls()
  if mon then mon.clear() mon.setCursorPos(1,1) else term.clear() term.setCursorPos(1,1) end
end
local function writeAt(x,y,text,color)
  if mon then
    if mon.setTextColor and color then mon.setTextColor(color) end
    mon.setCursorPos(x,y); mon.write(text)
  else
    if term.setTextColor and color then term.setTextColor(color) end
    term.setCursorPos(x,y); term.write(text)
  end
end

local lilies = {}  -- label -> {level, seconds, lastEvent, lastFired, id, updated}

local function fmtSec(s)
  local m = math.floor(s/60); local sec = math.floor(s%60)
  return string.format("%02d:%02d", m, sec)
end

local function render()
  cls()
  local now = os.epoch("local")
  writeAt(1,1,"Thermalily Cooldowns", colors and colors.white)
  writeAt(1,2,("Updated: %s"):format(textutils.formatTime(os.time(), true)), colors and colors.lightGray)

  -- header
  writeAt(1,4, string.format("%-16s %-5s %-8s %-10s %-6s","Label","Lvl","Time","LastEvt","Since"), colors and colors.cyan)

  -- sort labels for stable order
  local labels = {}
  for k in pairs(lilies) do table.insert(labels, k) end
  table.sort(labels)

  local row = 5
  for _, label in ipairs(labels) do
    local d = lilies[label]
    local lvl = d.level or 0
    local secs = d.seconds or (lvl*20)
    local lastEvt = d.lastEvent or "-"
    local since = "-"
    if d.lastFired then since = fmtSec((now - d.lastFired)/1000) end

    -- color: green if ready, yellow mid, red high cooldown
    local col = colors and colors.white
    if colors then
      if lvl == 0 then col = colors.lime
      elseif lvl >= 10 then col = colors.red
      else col = colors.yellow end
    end

    writeAt(1,row, string.format("%-16s %-5d %-8s %-10s %-6s",
      label, lvl, fmtSec(secs), lastEvt, since), col)
    row = row + 1
  end
end

-- Receive + refresh loop
local lastDraw = 0
while true do
  local id, msg, proto = rednet.receive(nil, 0.5)
  if msg and proto == PROTO and type(msg) == "table" and msg.type == "thermalily" then
    local L = msg.label or ("id_"..tostring(msg.id))
    local rec = lilies[L] or {}
    rec.id = msg.id
    rec.level = msg.level or rec.level
    rec.seconds = msg.seconds or rec.seconds
    rec.lastEvent = msg.event or rec.lastEvent
    if msg.event == "fired" then rec.lastFired = msg.time end
    rec.updated = os.epoch("local")
    lilies[L] = rec
  end

  if os.clock() - lastDraw > 0.5 then
    render()
    lastDraw = os.clock()
  end
end
