-- Windows-style Dock clicks. DockDoor supplies an accurate cross-Space window
-- list and the grouped-window preview; Hammerspoon handles the physical click.
local M = {}
local press = nil
local dragThreshold = 8
local nativeHoldTime = 0.6 -- leave native Dock press-and-hold menus alone
local replayTag = 0x574D444F -- "WMDO": don't intercept our native-drag replay
local openTasks = {}
local running = false

local function axValue(element, name)
  if not element then return nil end
  local ok, value = pcall(function() return element:attributeValue(name) end)
  return ok and value or nil
end

local function bundlePathFromURL(value)
  if type(value) == "table" then
    return value.filePath or value.path
  end
  if type(value) == "string" and value:match("^file:") then
    local parts = hs.http.urlParts(value)
    return parts and (parts.fileSystemRepresentation or parts.path)
  end
  return type(value) == "string" and value or nil
end

local function dockItemAt(point)
  local dock = hs.axuielement.applicationElement("com.apple.dock")
  if not dock then return nil end
  local element = dock:elementAtPosition(point)
  for _ = 1, 6 do
    if not element then return nil end
    if axValue(element, "AXRole") == "AXDockItem" then break end
    element = axValue(element, "AXParent")
  end
  if not element or axValue(element, "AXRole") ~= "AXDockItem" then return nil end
  local subrole = axValue(element, "AXSubrole")
  if subrole and subrole ~= "AXApplicationDockItem" then return nil end

  local path = bundlePathFromURL(axValue(element, "AXURL"))
  local bundle = nil
  if path and path:match("%.app/?$") then
    local info = hs.application.infoForBundlePath((path:gsub("/$", "")))
    bundle = info and info.CFBundleIdentifier
  end
  if not bundle then
    local name = axValue(element, "AXTitle") or axValue(element, "AXDescription")
    local app = name and hs.application.get(name)
    bundle = app and app:bundleID()
  end
  if not bundle or not bundle:match("^[%w._-]+$") then return nil end
  return { bundle = bundle, path = path, frame = axValue(element, "AXFrame") }
end

local function isNearDock(point)
  for _, screen in ipairs(hs.screen.allScreens()) do
    local frame = screen:fullFrame()
    if point.x >= frame.x and point.x <= frame.x + frame.w and
       point.y >= frame.y and point.y <= frame.y + frame.h then
      -- The user's Dock is along the bottom. This only avoids expensive AX
      -- hit testing elsewhere; dockItemAt still verifies the exact icon.
      return point.y >= frame.y + frame.h - 200
    end
  end
  return false
end

local function dockMenuIsOpen()
  local dock = hs.axuielement.applicationElement("com.apple.dock")
  if not dock then return false end
  -- Dock's press-and-hold menu is not a normal application window. Check
  -- both roots, with a bounded walk so this cannot stall the event tap.
  local remaining = 40
  local function hasMenu(element, depth)
    if not element or remaining <= 0 then return false end
    remaining = remaining - 1
    if axValue(element, "AXRole") == "AXMenu" then return true end
    if depth == 0 then return false end
    for _, child in ipairs(axValue(element, "AXChildren") or {}) do
      if hasMenu(child, depth - 1) then return true end
    end
    return false
  end
  for _, root in ipairs(axValue(dock, "AXWindows") or {}) do
    if hasMenu(root, 2) then return true end
  end
  return hasMenu(dock, 3)
end

local function openApplication(bundle, log)
  -- An app can be running with no windows. Launch-or-focus alone does not
  -- send the reopen event that its native Dock icon would send; open does.
  local task
  task = hs.task.new("/usr/bin/open", function(code, _, err)
    openTasks[task] = nil
    if code ~= 0 then log.w("Dock reopen failed: " .. tostring(err)) end
  end, { "-b", bundle })
  if task and task:start() then
    openTasks[task] = true
  else
    log.w("Dock reopen could not start")
  end
end

local function appleScript(source)
  local ok, result, err = hs.osascript.applescript(source)
  if not ok or (type(result) == "string" and result:match("^error:")) then
    return nil, tostring(err or result)
  end
  return result
end

local function dockDoorWindows(bundle)
  local source = 'tell application "DockDoor" to list windows "' .. bundle .. '" by "bundle"'
  local result, err = appleScript(source)
  if not result then return nil, err end
  local ok, windows = pcall(hs.json.decode, tostring(result))
  if not ok or type(windows) ~= "table" then return nil, "invalid DockDoor JSON" end
  local real, seen = {}, {}
  for _, window in ipairs(windows) do
    local id = tonumber(window.windowId)
    -- DockDoor may supply a synthetic windowId=0 for a windowless app.
    -- It cannot be minimized and must not count as an actual window.
    if id and id > 0 and not seen[id] and window.bundleId == bundle then
      seen[id] = true
      real[#real + 1] = window
    end
  end
  return real
end

local function dockDoorWindowAction(verb, id)
  local numericId = tonumber(id)
  if not numericId then return nil, "invalid window ID" end
  return appleScript('tell application "DockDoor" to ' .. verb ..
    ' window "' .. tostring(math.floor(numericId)) .. '"')
end

local function showPreview(item)
  local script = 'tell application "DockDoor" to show preview "' ..
    item.bundle .. '" by "bundle" persistent true'
  local frame = item.frame
  if type(frame) == "table" and frame.x and frame.y and frame.w and frame.h then
    local coords = string.format("%d,%d,%d,%d", math.floor(frame.x),
      math.floor(frame.y), math.floor(frame.w), math.floor(frame.h))
    script = script .. ' dock frame "' .. coords .. '"'
  end
  return appleScript(script)
end

local function handleClick(item, activeBundle, activeWindowID, log)
  local windows, err = dockDoorWindows(item.bundle)
  if not windows then
    log.w("DockDoor query failed: " .. tostring(err))
    openApplication(item.bundle, log)
    return
  end
  if #windows > 1 then
    local shown, showErr = showPreview(item)
    if not shown then log.w("DockDoor preview failed: " .. tostring(showErr)) end
    return
  end
  appleScript('tell application "DockDoor" to hide preview')
  if #windows == 0 then
    openApplication(item.bundle, log)
    return
  end

  local window = windows[1]
  local id = window.windowId
  local verb
  if activeBundle == item.bundle and activeWindowID == tonumber(id) and
     not window.isMinimized and not window.isHidden then
    verb = "minimize"
  elseif window.isMinimized then
    verb = "minimize" -- restoring also unhides and focuses the app
  elseif window.isHidden then
    verb = "hide" -- DockDoor toggles hidden off and focuses the window
  else
    verb = "focus"
  end

  local done, actionErr = dockDoorWindowAction(verb, id)
  if not done then
    log.w("DockDoor " .. verb .. " failed: " .. tostring(actionErr))
    openApplication(item.bundle, log)
  end
end

local function cancelHold(held)
  if held and held.holdTimer then
    held.holdTimer:stop()
    held.holdTimer = nil
  end
end

local function nativePress(held)
  cancelHold(held)
  if held.native then return nil end
  held.native = true
  -- A native hold menu or reorder drag supersedes a clicked thumbnail flyout.
  -- Keep AppleScript out of the physical event-tap callback itself.
  hs.timer.doAfter(0, function()
    if running then appleScript('tell application "DockDoor" to hide preview') end
  end)
  return held.down:copy():setProperty(
    hs.eventtap.event.properties.eventSourceUserData, replayTag)
end

local function onMouse(event, log)
  if event:getProperty(hs.eventtap.event.properties.eventSourceUserData) == replayTag then
    return false
  end
  local kind = event:getType()
  local types = hs.eventtap.event.types
  if kind == types.leftMouseDown then
    cancelHold(press)
    press = nil
    local flags = event:getFlags()
    if flags.cmd or flags.alt or flags.ctrl or flags.shift or flags.fn then
      return false -- keep macOS's modified Dock clicks available
    end
    local point = event:location()
    if not isNearDock(point) then return false end
    if dockMenuIsOpen() then return false end
    local item = dockItemAt(point)
    if item then
      local gestures = winmacModules and winmacModules.gestures
      if gestures and gestures.cancelSecondaryTap then gestures.cancelSecondaryTap() end
      local active = hs.application.frontmostApplication()
      local window = hs.window.focusedWindow()
      local held = {
        point = point, item = item,
        activeBundle = active and active:bundleID(),
        activeWindowID = window and window:id(),
        startedAt = hs.timer.secondsSinceEpoch(),
        down = event:copy(), native = false,
      }
      press = held
      held.holdTimer = hs.timer.doAfter(nativeHoldTime, function()
        if not running or press ~= held or held.native then return end
        -- Don't post a delayed down after the real button was released.
        -- A queued release will be handled as a complete pair below.
        if not hs.eventtap.checkMouseButtons().left then return end
        local down = nativePress(held)
        if down then down:post() end
      end)
      -- Own BOTH halves of a short click. Passing the down to Dock while
      -- swallowing its up leaves Dock stuck in its press-and-hold state.
      return true
    end
    return false
  end
  if kind == types.leftMouseDragged and press then
    if press.native then return false end
    local point = event:location()
    local dx, dy = point.x - press.point.x, point.y - press.point.y
    if dx * dx + dy * dy >= dragThreshold * dragThreshold then
      -- Inject the original down at this tap before the real drag continues.
      -- From here through release, the entire drag belongs to native Dock.
      return false, { nativePress(press) }
    end
    return true -- jitter before a suppressed down must not start a native drag
  end
  if kind ~= types.leftMouseUp or not press then return false end

  local held = press
  press = nil
  cancelHold(held)
  if held.native then return false end -- native Dock must receive its matching up
  local point = event:location()
  local dx, dy = point.x - held.point.x, point.y - held.point.y
  if dx * dx + dy * dy >= dragThreshold * dragThreshold or
     hs.timer.secondsSinceEpoch() - held.startedAt >= nativeHoldTime then
    -- If the drag/hold callback was delayed, still give native Dock a
    -- complete down/up pair rather than an orphaned release.
    return false, { nativePress(held) }
  end
  if dockMenuIsOpen() then return true end
  local releasedItem = dockItemAt(point)
  if not releasedItem or releasedItem.bundle ~= held.item.bundle then return true end

  hs.timer.doAfter(0, function()
    if not running then return end
    local ok, err = pcall(handleClick, releasedItem, held.activeBundle, held.activeWindowID, log)
    if not ok then log.e("Dock click: " .. tostring(err)) end
  end)
  return true -- replace native Dock activation, which chooses a window for us
end

function M.start(log)
  M.stop()
  running = true
  local tap = hs.eventtap.new({
    hs.eventtap.event.types.leftMouseDown,
    hs.eventtap.event.types.leftMouseUp,
    hs.eventtap.event.types.leftMouseDragged,
  }, function(event)
    local ok, consumed, replay = pcall(onMouse, event, log)
    if not ok then
      cancelHold(press)
      press = nil
      log.e("Dock event: " .. tostring(consumed))
      return false -- fail open to the native Dock
    end
    return consumed, replay
  end)
  tap:start()
  if not tap:isEnabled() then log.w("Dock click event tap needs Accessibility") end
  M.tap = tap
end

function M.stop()
  running = false
  cancelHold(press)
  press = nil
  if M.tap then M.tap:stop() end
end

return M
