-- lily_display.lua
-- Receives status on "thermalily-status" and shows:
--   Label | Lvl | ETA (to scheduled feed) | LastEvt | SinceFeed | ID
-- Uses a monitor if present; otherwise prints to terminal.

local PROTO = "thermalily-status"

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

local mon = peripheral.find("monitor")
if mon then pcall(function() mon.setTextScale(0.5) end) end

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

local function mmss(sec)
  if not sec or sec < 0 then sec = 0 end
  local m = math.floor(sec/60); local s = math.floor(sec%60)
  return string.format("%02d:%02d", m, s)
end

local lilies = {} -- label -> {level, readyAt, lastEvent, lastFired, id, updated}

local function render()
  cls()
  writeAt(1,1,"Thermalily Cooldowns (time-scheduled)", colors and colors.white)
  writeAt(1,2,"Updated: "..textutils.formatTime(os.time(), true), colors and colors.lightGray)
  writeAt(1,4,string.format("%-16s %-5s %-7s %-10s %-10s %-4s",
    "Label","Lvl","ETA","LastEvt","SinceFeed","ID"), colors and colors.cyan)

  local keys = {}
  for k in pairs(lilies) do table.insert(keys, k) end
  table.sort(keys)

  local now = os.epoch("local")
  local row = 5
  for _, L in ipairs(keys) do
    local d = lilies[L]
    local lvl = d.level or 0
    local eta = 0
    if d.readyAt then eta = math.max(0, math.floor((d.readyAt - now)/1000)) end
    local since = "-"
    if d.lastFired then since = mmss((now - d.lastFired)/1000) end

    local col = colors and colors.white
    if colors then
      if eta == 0 then col = colors.lime         -- feeding now / due
      elseif lvl >= 10 then col = colors.red     -- long cooldown
      else col = colors.yellow                   -- short-mid cooldown
      end
    end

    writeAt(1,row,string.format("%-16s %-5d %-7s %-10s %-10s %-4d",
      L, lvl, mmss(eta), d.lastEvent or "-", since, d.id or 0), col)
    row = row + 1
  end
end

local lastDraw = 0
while true do
  local id, msg, proto = rednet.receive(nil, 0.5)
  if msg and proto == PROTO and type(msg) == "table" and msg.type == "thermalily" then
    local L = msg.label or ("id_"..tostring(msg.id))
    local rec = lilies[L] or {}
    rec.id = msg.id
    rec.level = msg.level or rec.level
    rec.lastEvent = msg.event or rec.lastEvent
    if msg.readyAt then rec.readyAt = msg.readyAt end
    if msg.event == "fired" then rec.lastFired = msg.time end
    rec.updated = os.epoch("local")
    lilies[L] = rec
  end

  if os.clock() - lastDraw > 0.5 then
    render()
    lastDraw = os.clock()
  end
end
