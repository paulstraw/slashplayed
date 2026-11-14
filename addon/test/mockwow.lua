-- Runs SPHover.lua against a mock of the WoW API it uses, and prints what the strip shows on each
-- frame: one line of SPH_BLOCKS digits (r << 2 | g << 1 | b per block), after a line "expect <n>"
-- and n lines "x y w h" (screen fractions) for the rects it should carry. Lua 5.1 code; run with any
-- Lua (test.sh). Usage: lua mockwow.lua <path to SPHover.lua> <frames>
-- With a third argument, focus, it runs SPKeyboard.lua instead: no box has focus for the first half of
-- the frames, then the mock UI's edit box does (SetFocus), and the rect expected is that box's; two frames
-- before the end its SetFocus is called again, as choosing Say with chat open does, which has to send a
-- new message with the same rect.

local SCREEN_W, SCREEN_H = 1366, 768  -- UIParent units at effective scale 1 (16:9, 768 tall)

local frames = {}  -- every frame, in creation order, as EnumerateFrames walks them

local Frame = {}
Frame.__index = Frame

local function newFrame(kind, parent, rect, opts)
    local f = setmetatable({ kind = kind, parent = parent, rect = rect, shown = true, mouse = true,
                             alpha = 1, scale = 1, textures = {}, scripts = {} }, Frame)
    for k, v in pairs(opts or {}) do f[k] = v end
    frames[#frames + 1] = f
    return f
end

function Frame:GetObjectType() return self.kind end
function Frame:GetParent() return self.parent end
function Frame:IsForbidden() return self.forbidden or false end
function Frame:IsVisible()
    if not self.shown then return false end
    return self.parent == nil or self.parent:IsVisible()
end
function Frame:IsMouseClickEnabled() return self.mouse end
function Frame:IsMouseMotionEnabled() return false end
function Frame:IsMouseEnabled() return self.mouse end
function Frame:GetEffectiveAlpha() return self.alpha * (self.parent and self.parent:GetEffectiveAlpha() or 1) end
function Frame:GetEffectiveScale() return self.scale * (self.parent and self.parent:GetEffectiveScale() or 1) end
function Frame:GetRect()
    if not self.rect then return nil end
    return (unpack or table.unpack)(self.rect)
end
function Frame:GetWidth() return self.rect and self.rect[3] or 0 end
function Frame:GetHeight() return self.rect and self.rect[4] or 0 end
function Frame:DoesClipChildren() return self.clips or false end
function Frame:SetFrameStrata() end
function Frame:SetFrameLevel() end
function Frame:EnableMouse(on) self.mouse = on end
function Frame:SetPoint() end
function Frame:SetHeight(h) self.height = h end
function Frame:SetScript(name, fn) self.scripts[name] = fn end
function Frame:SetFocus() end
function hooksecurefunc(t, name, fn)
    local orig = t[name]
    t[name] = function(...) orig(...); fn(...) end
end
function Frame:CreateTexture()
    local t = { color = { 0, 0, 0 } }
    function t:SetColorTexture(r, g, b) self.color = { r, g, b } end
    function t:ClearAllPoints() end
    function t:SetPoint() end
    function t:SetSize() end
    self.textures[#self.textures + 1] = t
    return t
end

UIParent = newFrame("Frame", nil, { 0, 0, SCREEN_W, SCREEN_H })
UIParent.mouse = false

function CreateFrame(kind, name, parent)
    local f = newFrame(kind, parent, { 0, 0, SCREEN_W, 1 })
    f.mouse = true
    return f
end

function GetPhysicalScreenSize() return 2560, 1440 end

local focus
function GetCurrentKeyBoardFocus() return focus end

function EnumerateFrames(after)
    if after == nil then return frames[1] end
    for i, f in ipairs(frames) do
        if f == after then return frames[i + 1] end
    end
end

-- The UI: what each frame is, and the rect (UIParent units) the addon should report, if any.
local expected = {}
local function button(kind, parent, rect, opts, want)
    newFrame(kind, parent, rect, opts)
    if want then expected[#expected + 1] = want end
end
local bar = newFrame("Frame", UIParent, { 300, 0, 600, 60 }, { mouse = false })
for i = 0, 11 do
    button("CheckButton", bar, { 300 + i * 40, 10, 36, 36 }, nil, { 300 + i * 40, 10, 36, 36 })
end
button("Button", UIParent, { 10, 700, 100, 24 }, { scale = 0.8 }, { 8, 560, 80, 19.2 })  -- scaled
button("EditBox", UIParent, { 500, 400, 200, 20 }, nil, { 500, 400, 200, 20 })
local editBox = frames[#frames]
button("Slider", UIParent, { 500, 350, 200, 16 }, nil, { 500, 350, 200, 16 })
button("Button", UIParent, { 50, 50, 30, 30 }, { shown = false })      -- hidden
button("Button", UIParent, { 60, 60, 30, 30 }, { mouse = false })      -- not clickable
button("Button", UIParent, { 70, 70, 30, 30 }, { alpha = 0 })          -- invisible
button("Button", UIParent, { 0, 0, 1366, 768 })                        -- screen-sized
button("Button", UIParent, { 80, 80, 2, 30 })                          -- sliver
button("Frame", UIParent, { 90, 90, 30, 30 })                          -- not a button type
button("Button", UIParent, { 100, 100, 30, 30 }, { forbidden = true }) -- forbidden
button("Button", UIParent, { 1350, 300, 40, 20 }, nil, { 1350, 300, 16, 20 })  -- off the right edge
local scroll = newFrame("ScrollFrame", UIParent, { 900, 200, 200, 100 }, { mouse = false })
local content = newFrame("Frame", scroll, { 900, 0, 200, 400 }, { mouse = false })
button("Button", content, { 900, 250, 200, 20 }, nil, { 900, 250, 200, 20 })   -- inside the view
button("Button", content, { 900, 290, 200, 20 }, nil, { 900, 290, 200, 10 })   -- half out of it
button("Button", content, { 900, 100, 200, 20 })                               -- scrolled away
for i = 1, 60 do  -- enough rects for several chunks
    button("Button", UIParent, { 20 + i * 4, 100 + i * 5, 10, 10 }, nil, { 20 + i * 4, 100 + i * 5, 10, 10 })
end

local focusMode = arg[3] == "focus"
if focusMode then
    -- A box scaled down, so its rect has to come out times its effective scale.
    editBox.scale = 0.5
    ChatFrame1EditBox = editBox
    expected = { { 250, 200, 100, 10 } }
end

dofile(arg[1])
local strip
for _, f in ipairs(frames) do
    if #f.textures > 0 then strip = f end
end

print("expect " .. #expected)
for _, r in ipairs(expected) do
    print(string.format("%.6f %.6f %.6f %.6f", r[1] / SCREEN_W, r[2] / SCREEN_H, r[3] / SCREEN_W, r[4] / SCREEN_H))
end
for frame = 1, tonumber(arg[2]) do
    if focusMode and (frame == math.floor(tonumber(arg[2]) / 2) + 1 or frame == tonumber(arg[2]) - 1) then
        focus = editBox
        editBox:SetFocus()
    end
    strip.scripts.OnUpdate(strip, 1 / 60)
    local line = {}
    for i, t in ipairs(strip.textures) do
        line[i] = tostring(math.floor(t.color[1] * 4 + t.color[2] * 2 + t.color[3]))
    end
    print(table.concat(line))
end
