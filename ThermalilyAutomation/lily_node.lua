-- lily_node.lua
-- Thermalily controller that works with:
--   - BACK: comparator tip touching the computer (reads analog 0..15)
--   - FRONT: wireless redstone transmitter to the dispenser/valve (pulsed)
--
-- Behavior:
--   * During PRODUCTION the comparator is 0 for ~30s.
--   * When production ends, comparator jumps 0 -> L (>0). L*20s = cooldown.
--   * We schedule next feed at: now + (L*20s) + EXTRA_DELAY_S.
--   * At ready time, we pulse FRONT, then confirm by seeing L>0 -> 0 (new production).
--   * If not confirmed, retry after RETRY_AFTER_S.
--
-- Also broadcasts status over rednet (if a wireless modem is attached).

local INPUT      = "back"    -- comparator side
local OUTPUT     = "front"   -- wireless TX (to dispenser/valve receiver)
local PULSE_S    = 0.4       -- pulse length
local EXTRA_DELAY_S = 1.0    -- << your requested extra 1s lag buffer
local RETRY_AFTER_S = 5      -- if feed not confirmed, retry after this
local STATUS_PERIOD = 1.0    -- min seconds between status broadcasts
local PROTO      = "thermalily-status"
local STATE_PATH = "lily_state.dat"  -- persist schedule across reboots

-- ---------- utils ----------
local function now_ms() return os.epoch("local") end
local function ms(s)   return math.floor(s * 1000) end
local function get_level()
  return redstone.getAnalogInput(INPUT) or 0
end

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

local function send(event, extra)
  if not haveModem then return end
  local level = get_level()
  local payload = {
    type   = "thermalily",
    label  = LABEL,
    id     = os.getComputerID(),
    time   = now_ms(),
    level  = level,
    readyAt= nil,       -- filled by caller if available
    event  = event,     -- "level","cooldown_start","feed_due","fired","confirm","retry","boot_arm"
    extra  = extra
  }
  rednet.broadcast(payload, PROTO)
end

-- ---------- persistence ----------
local function save_state(st)
  local f = fs.open(STATE_PATH, "w")
  if not f then return end
  f.write(textutils.serialize(st))
  f.close()
end

local function load_state()
  if not fs.exists(STATE_PATH) then return nil end
  local f = fs.open(STATE_PATH, "r")
  if not f then return nil end
  local s = f.readAll()
  f.close()
  local ok, t = pcall(textutils.unserialize, s)
  if ok and type(t) == "table" then return t end
  return nil
end

-- ---------- scheduling ----------
local state = load_state() or {
  lastLevel = nil,
  cooldownLevel = nil,
  cooldownStartedAt = nil, -- ms
  readyAt = nil,           -- ms
  firedAt = nil,           -- ms (last pulse time)
}

local function set_ready_in(level)
  -- Schedule: cooldown duration (L*20s) + the requested 1s buffer
  local t = now_ms() + ms(level * 20 + EXTRA_DELAY_S)
  state.readyAt = t
  save_state(state)
  if haveModem then
    local payload = {
      type="thermalily", label=LABEL, id=os.getComputerID(),
      time=now_ms(), level=get_level(), readyAt=t, event="feed_due"
    }
    rednet.broadcast(payload, PROTO)
  end
end

local function pulse()
  redstone.setOutput(OUTPUT, true)
  sleep(PULSE_S)
  redstone.setOutput(OUTPUT, false)
end

print(("[Lily %s] timing from BACK(cmp), pulsing FRONT(wireless), +%0.1fs buffer")
  :format(LABEL, EXTRA_DELAY_S))

-- Initial boot handling:
-- If we boot with L>0 we are somewhere in cooldown; we don't know when it started,
-- so be conservative and wait L*20s + buffer from *now*.
-- If we boot with 0, wait for 0->L transition to schedule precisely.
do
  local L = get_level()
  state.lastLevel = L
  if L > 0 then
    state.cooldownLevel = L
    state.cooldownStartedAt = nil -- unknown
    set_ready_in(L)
    send("boot_arm", {reason="level>0"})
  else
    state.readyAt = nil
    save_state(state)
    send("boot_arm", {reason="level==0"})
  end
end

-- ---------- main loop ----------
local lastStatusClock = 0
while true do
  local L = get_level()
  local now = now_ms()
  local clk = os.clock()

  -- Status on change or periodic
  if L ~= state.lastLevel or (clk - lastStatusClock) >= STATUS_PERIOD then
    if haveModem then
      local payload = {
        type="thermalily", label=LABEL, id=os.getComputerID(),
        time=now, level=L, readyAt=state.readyAt, event="level",
        extra={old=state.lastLevel, new=L}
      }
      rednet.broadcast(payload, PROTO)
    end
    lastStatusClock = clk
  end

  -- Detect PRODUCTION -> COOLDOWN (0 -> L>0)
  if state.lastLevel ~= nil and state.lastLevel == 0 and L > 0 then
    state.cooldownLevel = L
    state.cooldownStartedAt = now
    set_ready_in(L)            -- schedule next feed from *now*
    send("cooldown_start", {level=L})
  end

  -- Ready to feed?
  if state.readyAt and now >= state.readyAt then
    -- Attempt to feed
    send("feed_due", {at=state.readyAt})
    pulse()
    state.firedAt = now
    save_state(state)
    send("fired")

    -- Confirm by seeing L>0 -> 0 within a few seconds (new production)
    local deadline = now_ms() + ms(4)
    local confirmed = false
    local prev = L
    while now_ms() <= deadline do
      local cur = get_level()
      if prev > 0 and cur == 0 then
        confirmed = true
        break
      end
      prev = cur
      sleep(0.2)
    end

    if confirmed then
      -- We will reschedule when 0->L happens at the end of production.
      state.readyAt = nil
      save_state(state)
      send("confirm")
    else
      -- Not ready yet or no lava. Retry after a short delay.
      state.readyAt = now_ms() + ms(RETRY_AFTER_S)
      save_state(state)
      send("retry", {after=RETRY_AFTER_S})
    end
  end

  state.lastLevel = L
  save_state(state)
  sleep(0.25)
end
