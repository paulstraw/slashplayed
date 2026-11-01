-- SPMovie: a way out of an in-game movie (a zone's or a quest's cinematic) with touch alone.
--
-- The game's MovieFrame leaves a movie only on a key: Escape, Space or Enter opens its close dialog
-- ("Are you sure you want to skip this cinematic?", Yes and No), whose buttons are clickable. An iPhone
-- or iPad without a keyboard has no such key, and a movie that never starts on the device (a black
-- screen with no sound, GitHub issue #24) would leave quitting the app as the only way out. So a tap
-- (a click) anywhere on a movie opens that same dialog. Every flavor's FrameXML has the same
-- MovieFrameMixin; a client without one is left alone.
--
-- Only in game: addons don't run on the login and character screens, whose movies (the intro, the
-- Cinematics menu) still take a key.

local frame = MovieFrame
if not frame or not frame.ShowCloseDialog or not frame.CloseDialog then return end

frame:EnableMouse(true)
frame:HookScript("OnMouseUp", function(self)
    if not self.CloseDialog:IsShown() then self:ShowCloseDialog() end
end)
