-- Runs in Hammerspoon's Lua VM, with no real mouse input or window actions.
-- Usage: hs -c 'return dofile(".../dock-regression-tests.lua").run(".../dock.lua")'
local T = {}
local bundle = "com.test.app"
local types = { leftMouseDown = 1, leftMouseUp = 2, leftMouseDragged = 3 }
local userData = 100
local function harness(path)
  local s = {
    time = 100, menu = false,
    calls = {}, timers = {}, warnings = {}, types = {}, itemBundle = bundle,
    nativeEvents = {}, nativeDown = false, orphanUps = 0, mouseLeft = false,
    pendingReplies = {}, scriptRequests = {}, terminatedTasks = 0,
  }
  local function record(kind, value) s.calls[#s.calls + 1] = { kind, value } end
  local function eventObject(kind, x, y, flags, properties)
    properties = properties or {}
    local event = {
      getType = function() return kind end,
      getFlags = function() return flags or {} end,
      location = function() return { x = x or 125, y = y or 955 } end,
      getProperty = function(_, property) return properties[property] or 0 end,
    }
    function event:copy()
      local copied = {}
      for k, v in pairs(properties) do copied[k] = v end
      return eventObject(kind, x, y, flags, copied)
    end
    function event:setProperty(property, value) properties[property] = value; return self end
    function event:post() s.dispatch(self); return self end
    return event
  end
  local function deliverNative(event)
    local kind = event:getType()
    s.nativeEvents[#s.nativeEvents + 1] = kind
    if kind == types.leftMouseDown then
      assert(not s.nativeDown, "duplicate native down without up")
      s.nativeDown = true; s.nativeDownSince = s.time
    elseif kind == types.leftMouseUp then
      if not s.nativeDown then s.orphanUps = s.orphanUps + 1 end
      s.nativeDown = false
    end
  end
  local item = {
    attributeValue = function(_, name)
      local attributes = {
        AXRole = "AXDockItem", AXSubrole = "AXApplicationDockItem",
        AXURL = "/Applications/Test.app", AXFrame = { x = 100, y = 930, w = 50, h = 50 },
      }
      return attributes[name]
    end,
  }
  local menu = { attributeValue = function(_, name) return name == "AXRole" and "AXMenu" or nil end }
  local dock = {
    attributeValue = function(_, name)
      if name == "AXRole" then return "AXApplication" end
      if name == "AXChildren" or name == "AXWindows" then return s.menu and { menu } or {} end
    end,
    elementAtPosition = function(_, point)
      if point.x >= 100 and point.x < 150 and point.y >= 930 and point.y < 980 then return item end
    end,
  }
  local fake
  fake = {
    axuielement = { applicationElement = function() return dock end },
    application = {
      infoForBundlePath = function() return { CFBundleIdentifier = s.itemBundle } end,
      frontmostApplication = function() error("focus lookup belongs to DockDoor") end,
    },
    screen = { allScreens = function()
      return { { fullFrame = function() return { x = 0, y = 0, w = 1000, h = 1000 } end } }
    end },
    timer = {
      secondsSinceEpoch = function() return s.time end,
      doAfter = function(delay, fn)
        local timer = { due = s.time + delay, fn = fn, cancelled = false }
        function timer:stop() self.cancelled = true end
        s.timers[#s.timers + 1] = timer
        return timer
      end,
    },
    osascript = { applescript = function()
      error("synchronous AppleScript blocks the gesture/event-tap thread")
    end },
    task = { new = function(path, callback, args)
      if s.taskCreationFails and path == "/usr/bin/osascript" then return nil end
      local task = { terminated = false }
      function task:terminate()
        self.terminated = true; s.terminatedTasks = s.terminatedTasks + 1
      end
      local source = args[2]
      local function complete(forceLateReply)
        if task.terminated then
          if forceLateReply then callback(0, "ok\n", "") end
          return
        end
        if path == "/usr/bin/open" then callback(0, "", ""); return end
        if source:find("hide preview", 1, true) then
          s.previewDismissals = (s.previewDismissals or 0) + 1
        else
          local target = source:match('activate dock item "([%w._-]+)"')
          assert(target, "expected a single Dock click command")
          if s.rejectClick then callback(0, "error: unavailable", ""); return end
          record("activate", target)
        end
        callback(0, "ok\n", "")
      end
      function task:start()
        if path == "/usr/bin/open" then
          record("open", args[2])
        else
          assert(path == "/usr/bin/osascript", "unexpected executable")
          assert(args[1] == "-e", "script must be passed directly, not through a shell")
          assert(source:find("with timeout of 2 seconds", 1, true), "AppleEvent has no timeout")
          s.scriptRequests[#s.scriptRequests + 1] = source
          if s.taskStartFails then return false end
          if s.stallClick and source:find("activate dock item", 1, true) then
            s.pendingReplies[#s.pendingReplies + 1] = complete
            return true
          end
        end
        fake.timer.doAfter(s.replyDelay or 0, complete)
        return true
      end
      return task
    end },
    eventtap = { event = { types = types, properties = { eventSourceUserData = userData } },
      checkMouseButtons = function() return { left = s.mouseLeft } end,
      new = function(eventTypes, callback)
      s.callback = callback
      s.types = eventTypes
      local enabled = false
      return {
        start = function() enabled = true end,
        stop = function() enabled = false end,
        isEnabled = function() return enabled end,
      }
    end },
  }
  local env = setmetatable({ hs = fake, winmacModules = { gestures = {
    cancelSecondaryTap = function() s.tapCancellations = (s.tapCancellations or 0) + 1 end,
  } } }, { __index = _G })
  s.module = assert(loadfile(path, "t", env))()
  s.module.start({ w = function(v) s.warnings[#s.warnings + 1] = v end,
    e = function(v) error(v) end })
  function s.dispatch(event)
    local consumed, injected = s.callback(event)
    -- hs.eventtap inserts callback-returned events at the tap proxy before
    -- letting the real event continue. Such events skip this same tap.
    for _, replay in ipairs(injected or {}) do deliverNative(replay) end
    if not consumed then deliverNative(event) end
    return consumed, injected
  end
  function s.event(kind, x, y, flags)
    if kind == types.leftMouseDown then s.mouseLeft = true end
    if kind == types.leftMouseUp then s.mouseLeft = false end
    return s.dispatch(eventObject(kind, x, y, flags))
  end
  function s.flush()
    -- Drain callbacks queued by prior callbacks too, just like successive
    -- main-run-loop turns, without advancing to future timeout timers.
    for _ = 1, 100 do
      local pending, ran = s.timers, false
      s.timers = {}
      for _, timer in ipairs(pending) do
        if not timer.cancelled then
          if timer.due <= s.time then timer.fn(); ran = true
          else s.timers[#s.timers + 1] = timer end
        end
      end
      if not ran then return end
    end
    error("timer loop did not quiesce")
  end
  function s.advance(seconds)
    s.time = s.time + seconds; s.flush()
    -- Model the native hold-menu trigger, rather than just mocked window
    -- actions. An unmatched native down will now fail a short-click test.
    if s.nativeDown and s.time - s.nativeDownSince >= 0.6 then s.nativeMenu = true end
  end
  function s.balanced()
    assert(not s.nativeDown, "native Dock left holding the button")
    assert(s.orphanUps == 0, "native Dock received an orphaned up")
  end
  function s.expectNative(expected)
    assert(#s.nativeEvents == #expected, "wrong native event count")
    for i, kind in ipairs(expected) do assert(s.nativeEvents[i] == kind, "native event order mismatch") end
    s.balanced()
  end
  function s.click()
    local native = s.menu
    assert(s.event(types.leftMouseDown) == not native, "wrong mouse-down ownership")
    assert(#s.calls == 0, "window action on mouse-down")
    s.time = s.time + 0.1
    local consumed = s.event(types.leftMouseUp)
    s.flush()
    s.balanced()
    if not native then assert(#s.nativeEvents == 0, "short click leaked to native Dock") end
    return consumed
  end
  function s.expect(kind, value, count)
    count = count or 1
    assert(#s.calls == count, "expected " .. count .. " actions; got " .. #s.calls)
    if count > 0 then
      assert(s.calls[1][1] == kind, "expected " .. kind .. "; got " .. tostring(s.calls[1][1]))
      assert(s.calls[1][2] == value, "wrong action target")
    end
  end
  return s
end

function T.run(path)
  local cases = {}
  local function case(name, fn) cases[#cases + 1] = { name, fn } end
  case("a short click sends one DockDoor request", function(s)
    assert(s.click()); s.expect("activate", bundle)
    assert(#s.scriptRequests == 1)
    assert(s.scriptRequests[1]:find('dock frame "100,930,50,50"', 1, true), "Dock frame coordinates changed")
  end)
  case("action is deferred until after release callback", function(s)
    s.event(types.leftMouseDown); assert(s.event(types.leftMouseUp))
    assert(#s.calls == 0); s.flush(); s.expect("activate", bundle)
  end)
  case("drag away and back is not a click", function(s)
    s.event(types.leftMouseDown); assert(not s.event(types.leftMouseDragged, 180, 955))
    assert(not s.event(types.leftMouseDragged, 125, 955))
    assert(not s.event(types.leftMouseUp)); s.flush(); s.expect(nil, nil, 0)
    s.expectNative({ types.leftMouseDown, types.leftMouseDragged, types.leftMouseDragged, types.leftMouseUp })
  end)
  case("ordinary reorder drag is preserved", function(s)
    s.event(types.leftMouseDown); s.event(types.leftMouseDragged, 180, 955)
    assert(not s.event(types.leftMouseUp, 180, 955)); s.flush(); s.expect(nil, nil, 0)
    s.expectNative({ types.leftMouseDown, types.leftMouseDragged, types.leftMouseUp })
  end)
  case("diagonal drag is not a click", function(s)
    s.event(types.leftMouseDown); s.event(types.leftMouseDragged, 131, 961)
    assert(not s.event(types.leftMouseUp, 131, 961)); s.flush(); s.expect(nil, nil, 0)
    s.expectNative({ types.leftMouseDown, types.leftMouseDragged, types.leftMouseUp })
  end)
  case("minor pointer jitter stays a click", function(s)
    s.event(types.leftMouseDown); s.event(types.leftMouseDragged, 126, 956)
    assert(s.event(types.leftMouseUp, 126, 956)); s.flush(); s.expect("activate", bundle)
  end)
  case("release outside original icon is not a click", function(s)
    s.event(types.leftMouseDown, 147, 955)
    assert(s.event(types.leftMouseUp, 151, 955)); s.flush(); s.expect(nil, nil, 0); s.expectNative({})
  end)
  case("release over another icon is not a click", function(s)
    s.event(types.leftMouseDown); s.itemBundle = "com.other.app"
    assert(s.event(types.leftMouseUp)); s.flush(); s.expect(nil, nil, 0); s.expectNative({})
  end)
  case("press-and-hold stays native", function(s)
    s.event(types.leftMouseDown); s.time = s.time + 0.7
    assert(not s.event(types.leftMouseUp)); s.flush(); s.expect(nil, nil, 0)
    s.expectNative({ types.leftMouseDown, types.leftMouseUp })
  end)
  case("native menu opening cancels click", function(s)
    s.event(types.leftMouseDown); s.menu = true
    assert(s.event(types.leftMouseUp)); s.flush(); s.expect(nil, nil, 0); s.expectNative({})
  end)
  case("native menu already open stays native", function(s)
    s.menu = true; assert(not s.click()); s.expect(nil, nil, 0)
  end)
  case("modified click stays native", function(s)
    assert(not s.event(types.leftMouseDown, nil, nil, { shift = true }))
    assert(not s.event(types.leftMouseUp)); s.flush(); s.expect(nil, nil, 0)
  end)
  case("outside Dock stays native", function(s)
    assert(not s.event(types.leftMouseDown, 125, 200))
    assert(not s.event(types.leftMouseUp, 125, 200)); s.flush(); s.expect(nil, nil, 0)
  end)
  case("unpaired release stays native", function(s)
    assert(not s.event(types.leftMouseUp)); s.flush(); s.expect(nil, nil, 0)
  end)
  case("no duplicate action on extra release", function(s)
    assert(s.click()); assert(not s.event(types.leftMouseUp)); s.flush(); s.expect("activate", bundle)
  end)
  case("command rejection logs and reopens", function(s)
    s.rejectClick = true; assert(s.click()); s.expect("open", bundle)
    assert(#s.warnings == 1)
  end)
  case("restart does not leave two enabled taps", function(s)
    local oldTap = s.module.tap
    s.module.start({ w = function() end, e = function(v) error(v) end })
    assert(not oldTap:isEnabled()); assert(s.module.tap:isEnabled())
  end)
  case("stop prevents queued action", function(s)
    s.event(types.leftMouseDown); assert(s.event(types.leftMouseUp))
    assert(s.module.stop, "stop method missing"); s.module.stop()
    s.flush(); s.expect(nil, nil, 0)
  end)
  case("short click never leaves a native hold menu", function(s)
    s.event(types.leftMouseDown); s.time = s.time + 0.1
    s.event(types.leftMouseUp); s.flush(); s.advance(2)
    assert(not s.nativeMenu, "short click opened native hold menu")
    s.expectNative({}); s.expect("activate", bundle)
  end)
  case("hold timer replays one down and forwards its matching up", function(s)
    assert(s.event(types.leftMouseDown)); s.advance(0.7)
    assert(s.nativeDown, "native hold did not start")
    s.advance(0.7); assert(s.nativeMenu, "native hold menu unavailable")
    assert(not s.event(types.leftMouseUp)); s.flush()
    s.expectNative({ types.leftMouseDown, types.leftMouseUp }); s.expect(nil, nil, 0)
  end)
  case("a drag cancelled the hold timer", function(s)
    assert(s.event(types.leftMouseDown)); assert(not s.event(types.leftMouseDragged, 180, 955))
    s.advance(0.3); assert(not s.event(types.leftMouseUp, 180, 955)); s.advance(1)
    s.expectNative({ types.leftMouseDown, types.leftMouseDragged, types.leftMouseUp })
    s.expect(nil, nil, 0)
  end)
  case("delayed timer cannot replay down after physical release", function(s)
    assert(s.event(types.leftMouseDown)); s.mouseLeft = false; s.advance(0.7)
    assert(not s.nativeDown); assert(#s.nativeEvents == 0)
    assert(not s.event(types.leftMouseUp)); s.advance(1)
    s.expectNative({ types.leftMouseDown, types.leftMouseUp }); s.expect(nil, nil, 0)
  end)
  case("stop cancels pending native hold", function(s)
    assert(s.event(types.leftMouseDown)); s.module.stop(); s.advance(2)
    assert(not s.nativeMenu); s.expectNative({}); s.expect(nil, nil, 0)
  end)
  case("consumed primary press still cancels two-finger secondary tap", function(s)
    assert(s.click()); assert(s.tapCancellations == 1, "gesture owner missed primary press")
  end)
  case("native drag handoff dismisses any pinned flyout once", function(s)
    s.event(types.leftMouseDown); s.event(types.leftMouseDragged, 180, 955)
    s.event(types.leftMouseDragged, 200, 955); s.event(types.leftMouseUp, 200, 955)
    s.flush(); s.expect(nil, nil, 0); assert(s.previewDismissals == 1)
    s.balanced()
  end)
  case("native hold handoff dismisses any pinned flyout once", function(s)
    s.event(types.leftMouseDown); s.advance(0.7); s.flush()
    s.event(types.leftMouseUp); s.flush(); s.expect(nil, nil, 0)
    assert(s.previewDismissals == 1); s.balanced()
  end)
  case("click does not send a separate hide command", function(s)
    s.click(); assert(not s.previewDismissals and #s.scriptRequests == 1)
  end)
  case("stalled DockDoor reply never blocks the event tap", function(s)
    s.stallClick = true; s.click(); s.expect(nil, nil, 0)
    assert(not s.event(types.leftMouseDown, 125, 200))
    assert(not s.event(types.leftMouseUp, 125, 200))
    s.advance(3.1); s.expect("open", bundle)
    assert(#s.warnings == 1); assert(s.terminatedTasks == 1)
  end)
  case("late reply after deadline cannot act a second time", function(s)
    s.stallClick = true; s.click(); s.advance(3.1)
    s.pendingReplies[1](true); s.flush(); s.expect("open", bundle)
    assert(#s.scriptRequests == 1, "late reply dispatched a window action")
  end)
  case("stop terminates an outstanding reply and ignores its callback", function(s)
    s.stallClick = true; s.click(); s.module.stop()
    s.pendingReplies[1](true); s.advance(4); s.expect(nil, nil, 0)
    assert(s.terminatedTasks == 1); assert(#s.warnings == 0)
  end)
  case("another Dock press cancels a stale reply", function(s)
    s.stallClick = true; s.click()
    s.event(types.leftMouseDown)
    s.pendingReplies[1](true); s.flush(); s.expect(nil, nil, 0)
    assert(#s.scriptRequests == 1 and s.terminatedTasks == 1)
  end)
  case("subprocess start failure fails open without stalling", function(s)
    s.taskStartFails = true; s.click(); s.expect("open", bundle)
    s.advance(4); s.expect("open", bundle); assert(#s.warnings == 1)
  end)
  case("subprocess creation failure fails open without stalling", function(s)
    s.taskCreationFails = true; s.click(); s.expect("open", bundle)
    s.advance(4); s.expect("open", bundle); assert(#s.warnings == 1)
  end)
  case("delayed completed click remains asynchronous", function(s)
    s.replyDelay = 0.2; s.click(); s.expect(nil, nil, 0)
    assert(#s.scriptRequests == 1)
    s.advance(0.2); s.expect("activate", bundle)
  end)
  case("mouse-down never runs a subprocess", function(s)
    s.event(types.leftMouseDown); s.flush()
    assert(#s.scriptRequests == 0)
    assert(s.event(types.leftMouseUp)); s.flush(); s.expect("activate", bundle)
    assert(#s.scriptRequests == 1)
  end)
  case("release over another icon does not dispatch a request", function(s)
    s.event(types.leftMouseDown); s.flush(); s.itemBundle = "com.other.app"
    assert(s.event(types.leftMouseUp)); s.flush()
    s.expect(nil, nil, 0); assert(#s.scriptRequests == 0)
  end)
  case("stress: 500 rapid clicks and reorder drags preserve button pairing", function(s)
    for i = 1, 500 do
      s.event(types.leftMouseDown)
      if i % 5 == 0 then s.event(types.leftMouseDragged, 180, 955) end
      s.event(types.leftMouseUp); s.flush(); s.balanced()
    end
    s.expect("activate", bundle, 400)
    assert(#s.scriptRequests == 500 and s.previewDismissals == 100)
  end)
  local passed, failures = 0, {}
  for _, test in ipairs(cases) do
    local ok, err = pcall(function() test[2](harness(path)) end)
    if ok then passed = passed + 1 else failures[#failures + 1] = test[1] .. ": " .. tostring(err) end
  end
  return { passed = passed, total = #cases, failures = failures }
end
return T
