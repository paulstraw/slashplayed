-- Runs SPMovie.lua against a mock MovieFrame and checks that a tap (OnMouseUp) opens the close
-- dialog, once, and that a client with no MovieFrame (or an older one) is left alone. Lua 5.1 code;
-- run with any Lua (test.sh). Usage: lua spmovie.lua <path to SPMovie.lua>

local path = assert(arg[1], "usage: lua spmovie.lua <path to SPMovie.lua>")
local failures = 0
local function check(cond, what)
    if not cond then
        failures = failures + 1
        print("FAIL: " .. what)
    end
end

local function mockFrame()
    local f = { scripts = {}, mouse = false, opened = 0 }
    f.CloseDialog = { shown = false }
    function f.CloseDialog:IsShown() return self.shown end
    function f:EnableMouse(on) self.mouse = on end
    function f:HookScript(name, fn)
        local before = self.scripts[name]
        self.scripts[name] = function(...)
            if before then before(...) end
            fn(...)
        end
    end
    function f:ShowCloseDialog()
        self.opened = self.opened + 1
        self.CloseDialog.shown = true
    end
    return f
end

-- The real thing: a tap opens the dialog; a tap while it's up (on its buttons' way) doesn't reopen it.
MovieFrame = mockFrame()
dofile(path)
check(MovieFrame.mouse, "MovieFrame takes clicks")
check(MovieFrame.scripts.OnMouseUp ~= nil, "OnMouseUp hooked")
MovieFrame.scripts.OnMouseUp(MovieFrame, "LeftButton")
check(MovieFrame.opened == 1, "a tap opens the close dialog")
MovieFrame.scripts.OnMouseUp(MovieFrame, "LeftButton")
check(MovieFrame.opened == 1, "a tap with the dialog up doesn't open it again")
MovieFrame.CloseDialog.shown = false  -- No: the movie goes on
MovieFrame.scripts.OnMouseUp(MovieFrame, "LeftButton")
check(MovieFrame.opened == 2, "after No, a tap opens it again")

-- No MovieFrame, or one without the close dialog: nothing is touched, nothing fails.
MovieFrame = nil
check(pcall(dofile, path), "no MovieFrame")
MovieFrame = { EnableMouse = function() error("touched") end }
check(pcall(dofile, path), "a MovieFrame without ShowCloseDialog is left alone")

if failures > 0 then os.exit(1) end
print("SPMovie: ok")
