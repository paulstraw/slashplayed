-- SPKeyboard: tells the iPhone and iPad shim which of the game's text boxes has the keyboard's focus,
-- and where it is, so the on-screen keyboard comes up when a box gains focus (on an iPhone, zoomed onto
-- it) and goes away when it loses it. The game gives the shim no sign of a box's focus (its view answers
-- the Mac text-input protocol the same however its boxes are used), and an addon has no channel out of
-- the game but pixels, so this sends it the way SPHover sends its rects: SPHover.lua has the strip's
-- format, which this shares but for the frame's second byte, 'K' rather than 'W', and a message of at
-- most one rect, the focused box's (none when no box has focus), then with a box focused, a count of the
-- UI's SetFocus calls on edit boxes: choosing Say again with chat already open focuses the same box, and
-- the new count is what tells the shim to bring back a keyboard closed with Done.
--
-- Only in game: addons don't run on the login and character screens, where the edit menu's Keyboard
-- brings the keyboard up instead (shims/appkit/spkeyboard.m). Nothing about the box's text goes out:
-- only where the box is, which doesn't change as it's typed in.

local N_BLOCKS = 320
local FRAME_BYTES = 120  -- N_BLOCKS * 3 / 8
local PAYLOAD_BYTES = FRAME_BYTES - 7
local STRIP_PIXELS = 3

local floor, max, min = math.floor, math.max, math.min

local strip = CreateFrame("Frame", "SPKeyboardStrip", UIParent)
strip:SetFrameStrata("TOOLTIP")
strip:SetFrameLevel(9000)
strip:EnableMouse(false)
strip:SetPoint("BOTTOMLEFT")
strip:SetPoint("BOTTOMRIGHT")

local blocks = {}
for i = 1, N_BLOCKS do
    local t = strip:CreateTexture(nil, "OVERLAY")
    t:SetColorTexture(0, 0, 0, 1)
    blocks[i] = t
end

local laidOutWidth, laidOutHeight
local function layout()
    local _, physH = GetPhysicalScreenSize()
    local height = STRIP_PIXELS * 768 / physH / UIParent:GetEffectiveScale()
    local width = strip:GetWidth()
    if width == laidOutWidth and height == laidOutHeight then return end
    laidOutWidth, laidOutHeight = width, height
    strip:SetHeight(height)
    for i = 1, N_BLOCKS do
        local t = blocks[i]
        t:ClearAllPoints()
        t:SetPoint("BOTTOMLEFT", strip, "BOTTOMLEFT", width * (i - 1) / N_BLOCKS, 0)
        t:SetSize(width / N_BLOCKS, height)
    end
end

-- Every edit box's SetFocus, through the method table they share, taken from the chat box (a new edit
-- box would take the focus itself: they focus on show by default). A hook runs after the call and taints
-- nothing. A client without one leaves the count at 0: only a change of box then reopens the keyboard.
local focusCalls = 0
local sample = ChatFrame1EditBox or (ChatFrame1 and ChatFrame1.editBox)
local editBoxMethods = sample and getmetatable(sample)
editBoxMethods = editBoxMethods and editBoxMethods.__index
if type(editBoxMethods) == "table" and editBoxMethods.SetFocus then
    hooksecurefunc(editBoxMethods, "SetFocus", function() focusCalls = (focusCalls + 1) % 256 end)
end

local function quantize(v)
    return floor(max(0, min(1, v)) * 4095 + 0.5)
end

-- The message: no rects, or the focused box's, in screen fractions (origin bottom left). A forbidden or
-- hidden box (a secure frame's) can't be measured, so it's reported as none.
local function scan()
    local f = GetCurrentKeyBoardFocus and GetCurrentKeyBoardFocus()
    if not f or (f.IsForbidden and f:IsForbidden()) or not f:IsVisible() then return string.char(0, 0) end
    local l, b, w, h = f:GetRect()
    if not l then return string.char(0, 0) end
    local sw = UIParent:GetWidth() * UIParent:GetEffectiveScale()
    local sh = UIParent:GetHeight() * UIParent:GetEffectiveScale()
    local s = f:GetEffectiveScale()
    l, b = max(l * s, 0), max(b * s, 0)
    local r, t = min(l + w * s, sw), min(b + h * s, sh)
    if r <= l or t <= b then return string.char(0, 0) end
    local x, y = quantize(l / sw), quantize(b / sh)
    local qw, qh = quantize((r - l) / sw), quantize((t - b) / sh)
    return string.char(0, 1, floor(x / 16), x % 16 * 16 + floor(y / 256), y % 256,
                       floor(qw / 16), qw % 16 * 16 + floor(qh / 256), qh % 256, focusCalls)
end

-- ---- sending (as SPHover.lua's)

local message, seq, chunks, chunkIndex = nil, 0, {}, 0

local function fletcher16(bytes, n)
    local s1, s2 = 0, 0
    for i = 1, n do
        s1 = (s1 + bytes[i]) % 255
        s2 = (s2 + s1) % 255
    end
    return s2, s1
end

local function buildChunks(msg)
    chunks = {}
    local count = max(1, math.ceil(#msg / PAYLOAD_BYTES))
    for c = 1, count do
        local bytes = { 86, 75, seq, c - 1, count }  -- 'V' 'K'
        local part = msg:sub((c - 1) * PAYLOAD_BYTES + 1, c * PAYLOAD_BYTES)
        for i = 1, PAYLOAD_BYTES do
            bytes[5 + i] = part:byte(i) or 0
        end
        bytes[FRAME_BYTES - 1], bytes[FRAME_BYTES] = fletcher16(bytes, FRAME_BYTES - 2)
        chunks[c] = bytes
    end
    chunkIndex = 0
end

local function showChunk(bytes)
    local bit = 0  -- index into the frame's bits, most significant first
    local function nextBit()
        local byte = bytes[floor(bit / 8) + 1]
        local v = floor(byte / 2 ^ (7 - bit % 8)) % 2
        bit = bit + 1
        return v
    end
    for i = 1, N_BLOCKS do
        local r, g, b = nextBit(), nextBit(), nextBit()
        blocks[i]:SetColorTexture(r, g, b, 1)
    end
end

-- Every frame: asking for the focus is cheap, and the keyboard should follow it at once. The strip
-- changes only when the message does.
strip:SetScript("OnUpdate", function()
    layout()
    local ok, msg = pcall(scan)
    if ok and msg ~= message then
        message = msg
        seq = (seq + 1) % 256
        buildChunks(msg)
    end
    if #chunks > 1 or chunkIndex == 0 then
        chunkIndex = chunkIndex % #chunks + 1
        showChunk(chunks[chunkIndex])
    end
end)
