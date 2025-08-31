-- lily_node.lua
-- BACK: comparator tip
-- FRONT: wireless redstone transmitter to the dispenser
-- Also broadcasts status over rednet for a central display.

local INPUT  = "back"    -- comparator side
local OUTPUT = "front"   -- wireless redstone TX side
local PULSE_S = 0.4      -- dispenser pulse
local MIN_INTERVAL = 2   -- safety spacing
local STATUS_PROTO = "thermalily-status"
local STATUS_PERIOD = 1.0 -- broadcast level at least this often (s)

-- Try to open any wireless modem
local function openAnyWireless()
  for _, side in ipairs({"left","right","top","bottom","front","back"}) do
    if peripheral.getType(side) == "modem" and peripheral.call(side,"isWireless") then
      if not rednet.isOpen(side) then rednet.open(side) end
      return true
    end
  end
  return false
end
local haveModem = openAnyWireless()

local LABEL = os.getComputerLabel() or ("lily_"..os.getComputerID())
local lastLevel, lastFireClock, lastStatus = nil, 0, 0

local function secondsFor(level) return level * 20 end

local function send(event, extra)
  if not haveModem then return end
  local lvl = redstone.getAnalogInput(INPUT) or 0
  local msg = {
    type   = "thermalily",
    label  = LABEL,
    id     = os.getComputerID(),
    time   = os.epoch("local"),
    level  = lvl,
    seconds= secondsFor(lvl),
    event  = event,            -- "level","ready","fired"
    extra  = extra
  }
  rednet.broadcast(msg, STATUS_PROTO)
end

local function pulse()
  redstone.setOutput(OUTPUT, true)
  sleep(PULSE_S)
  redstone.setOutput(OUTPUT, false)
end

print(("[Lily %s] watching %s; pulsing %s"):format(LABEL, INPUT, OUTPUT))

while true do
  local level = redstone.getAnalogInput(INPUT) or 0
  local nowClock = os.clock()

  -- Broadcast level on change or periodically
  if lastLevel == nil or level ~= lastLevel or (nowClock - lastStatus) >= STATUS_PERIOD then
    send("level", { old = lastLevel, new = level })
    lastStatus = nowClock
  end

  -- Edge-trigger when cooldown finishes (level == 0)
  if level == 0 then
    local transitioned = (lastLevel ~= 0)
    if transitioned and (nowClock - lastFireClock) >= MIN_INTERVAL then
      send("ready")
      pulse()
      lastFireClock = nowClock
      send("fired")
      -- Wait until cooldown actually starts (level > 0) to avoid double fire
      repeat
        sleep(0.2)
        level = redstone.getAnalogInput(INPUT) or 0
      until level > 0
      -- Immediate status after change
      send("level", { old = 0, new = level })
      lastStatus = os.clock()
    end
  end

  lastLevel = level
  sleep(0.25)
end
