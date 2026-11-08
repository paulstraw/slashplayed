# Changelog

All notable changes to Slashplayed are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Slashplayed uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- A game patch no longer rebuilds and reinstalls Slashplayed. Play copies just the new game client to
  your iPad, iPhone, or Vision Pro, in a few seconds, and ticking or unticking a game no longer rebuilds
  it either.
- Updating and installing games on the iPad, iPhone, or Vision Pro works on every team, free Apple IDs
  included, with nothing to turn on: when a new build is out, the device offers Update and sets it up in
  seconds.
- Settings on the device says where each game came from: From your Mac, Updated on this device, or
  Installed on this device.

### Removed

- Update Games on This Device, the signing key it sent to your device, and the Slashplayed certificate:
  they're no longer needed. The companion's Updates on Devices settings and Setup Assistant's updates
  step are gone, the key is deleted from your device the first time Slashplayed starts there, and the
  certificate's key from your Mac the first time the companion starts. On a paid team, you can revoke the
  "Slashplayed" certificate on Apple's developer site (Certificates, IDs & Profiles > Certificates).

### Fixed

- slashplayed-companion no longer stops with "…helper's profile grants … which it shouldn't" on a paid team
  whose Slashplayed helper has the memory capabilities turned on, as Xcode's setup can leave it.
- The iPad mini (A17 Pro) was refused as an iPad that can't run the game, though it has the iPhone
  15 Pro's chip and 8 GB of memory. It can now be picked and played on. It hasn't been played on yet,
  so the companion marks it untested, as it does M1 iPads: if you try one, please report how it goes,
  working or not, on GitHub with the zip from Help > Export Diagnostics….
- Copy Game Files from This Mac copies every game installed on your Mac, even one that Battle.net's record
  of the install has lost track of. That can happen when Battle.net is reset or reinstalled and then
  installs another game into the same folder. Before, the companion said those games weren't the build
  Blizzard has out now and left the device's game data as it was, and it couldn't show how much space
  they'd take.

## [1.4.0] - 2026-11-06

### Added

- Forever (World of Warcraft: Forever) is a game you can install and play, beside the others.
- Games can be installed on the iPad or iPhone itself, with no game files from a Mac: tap
  Install on the start screen, and the device downloads the game from Blizzard and sets it up.
- Each game installed on the device has a Region in Settings (Americas, Europe, Korea, or Taiwan),
  next to its build. A game installed from your Mac shows the region it plays in there; change that one
  in Battle.net on your Mac.

### Fixed

- A game installed on the device now plays in your region, taken from the device's region in
  Settings, with the game's text and speech in your device's language when the game has it. Before, it
  always played in the Americas in US English, so players elsewhere couldn't reach their realms. The
  install screen says which region it's installing for.

- With a free Apple ID (a Personal Team), a game installed or updated on the device itself (including
  with Update Games on This Device turned on in the companion) now starts. Before, the device refused the
  game it had just signed, so it couldn't install or update games on its own.
- A game installed or updated on the device itself no longer stops with error #134 ("Invalid schema …
  for Table StartupFiles") a few minutes after it starts. This happened when the start that installed or
  updated it ended before the game opened (at the sign-in, say), or when the game's data was removed
  afterwards. The device now records which version of the game it has every time it starts one.

## [1.3.0] - 2026-11-01

### Added

- M1 iPads (the 2021 iPad Pros and the 5th-generation iPad Air) can now try Slashplayed. It hasn't
  been played on one yet, so the companion marks them untested: if you try one, please report how it
  goes, working or not, on GitHub with the zip from Help > Export Diagnostics….

## [1.2.0] - 2026-11-01

### Added

- Tap a cinematic in the game to skip it: the tap brings up the game's "skip this cinematic?"
  question, as Escape does on a keyboard. A cinematic that stays black (entering a new zone, say)
  no longer leaves an iPhone or iPad without a keyboard stuck.

### Known issues

- A cinematic in the game can stay black with no sound on a device. Tap it, then Yes, to skip it.

## [1.1.0] - 2026-11-01

### Added

- Right- and middle-click by touch on an iPhone or iPad: press with two fingers together to
  right-click, or three to middle-click, and hold them down to drag, so a two-finger drag is
  mouselook. The click is where the leftmost finger is, or the rightmost with Settings > Touch >
  Click With. A one-finger click now waits a moment (50 ms) to tell it from a chord. With
  Accessibility Zoom on, three-finger presses lag about half a second.

### Fixed

- A device that can't run the game (an iPad older than M2, an iPhone older than the 15 Pro) could
  still be picked in the device menus after setup, and Play then installed the game there and it
  crashed at once. The menus now list such a device as not supported and don't let you pick it,
  Automatic passes over it, and Play, Update Client, and Copy Game Files stop on it with the reason.
- The crash report in the device's log named the game's own frames as frames of another library, far
  past its end. Each frame is now named by the library that holds it, the game's as the client's,
  and an address in none of them is shown as it is.

## [1.0.1] - 2026-11-01

The first public release. Early and experimental: expect rough edges, and expect a game patch to
break it now and then until Slashplayed catches up. Slashplayed is unofficial and not affiliated with
Blizzard Entertainment, and it includes no Blizzard files; use it at your own risk.

### Added

- Play the Mac World of Warcraft clients (Classic Era, TBC Anniversary, MoP Classic, and
  Retail) on Apple Vision Pro, M2-or-later iPads, and iPhone 15 Pro or later. Classic Era's Hardcore
  and Season of Discovery are played by switching game mode in game. MoP Classic has
  been played on the Vision Pro and an iPhone 16 Pro, and is untested on the iPad. Retail has been
  played on an M2 iPad, where it runs hot and gets a memory warning, and on an iPhone 16 Pro. Of the
  iPhones, only the 16 Pro has been tested. On an iPhone, the game keeps clear of the Dynamic Island,
  with a black strip on that side, in either landscape orientation.
- Slashplayed Companion, a Mac app that builds the Slashplayed app, signs it with your own Apple ID,
  and installs it on your device. It needs Xcode and an Apple ID, nothing else: no game install or
  Battle.net on the Mac.
- No game install on the Mac needed. The companion downloads the game client from Blizzard's servers,
  and the game on the device fetches its data from Blizzard as you play, only what's on screen. The
  first start of a game takes a few minutes.
- Copy Game Files from This Mac, an option per device when the game is also installed on the Mac:
  the companion copies the game data over first, and later copies send only what a patch changed.
- Sign in on the device. The first time, Slashplayed asks for your Battle.net email and password and
  keeps them in the device's keychain (that device only, never synced), so the game signs in at every
  start with no Mac. Forget My Sign-In in the app's Settings signs out at once, after a confirmation.
- Play from the device alone: once installed, open Slashplayed on the device, with the Mac asleep or
  away, and pick a game on its start screen. Every launch from the home screen opens on it, even with
  one game.
- Settings on the device, from the start screen's gear: show the saved Battle.net email, sign in
  ahead of time or forget the sign-in, see and forget the signing identity, see the build each game
  runs, reset a game's settings (keybindings, macros, and addon settings are kept), set the display
  scale (Automatic, 1x, or 2x), and read the acknowledgements.
- The games' folders show in the Files app, and each game's Open in Files in the app's Settings opens
  its folder there, to edit its settings or add addons.
- An on-device helper prepares the game's code at each start, through
  [LocalDevVPN](https://apps.apple.com/app/id6755608044) (free, from the App Store). The headset
  pairs with itself on its first launch; the companion pairs an iPad or iPhone over USB.
- Update Games on This Device, off until you turn it on for a device. When Blizzard patches a game,
  the device checks that this Slashplayed can run the new build, then makes and signs the new game
  program itself with a signing key of your team, no Mac needed. A free team sends a copy of its Apple
  Development key; a paid team can use a Slashplayed certificate of its own, made in the companion's
  Settings. Forget Signing Identity in the app's Settings deletes the key from the device at once,
  after a confirmation. With the setting off, the device says to update on your Mac.
- Free Apple IDs (Personal Teams) work, every game included. Their signature lasts 7 days: the
  companion warns two days ahead and signs the app again when you rebuild or play. A paid team signs
  for a year.
- A setup assistant that checks Xcode, your Apple account and team, the device, LocalDevVPN, and the
  games for each device one step at a time, with a fix for each problem it finds.
- Play with My Mac's Battle.net, a fallback sign-in for a game installed on the Mac: the companion
  moves your Battle.net launch credentials to the device (it never reads their values) and closes the
  Mac copy of the game.
- A clear "this game version isn't supported yet" message after a game patch the release doesn't
  cover, on the Mac with a link that opens a pre-filled issue, and on the device as "This patch needs
  a Slashplayed update."
- Help > Export Diagnostics…, a zip of logs and versions to attach to bug reports, with your
  credentials left out.
- Automatic updates. The companion checks for new versions itself; turn that off in Settings, or use
  "Check for Updates…" any time.

### Known issues

- The device gets hot: the headset within minutes, the iPad and iPhone over long sessions. The game runs
  uncapped by default; capping it with its Max Foreground FPS setting helps.
- Leaving the game for more than about 30 seconds (closing its window, taking off the headset, or
  another app in front) can disconnect it and lose that session's settings and keybind changes. Exit
  or log out from the game menu first.
- The game window has once vanished after the headset was off for a few minutes. Stop the client and
  play again.
- LocalDevVPN has to be on every time the game starts. If it's off, Slashplayed opens it.
- On an iPhone, a mouse needs AssistiveTouch on to show a cursor.
- Voice chat doesn't work yet: the game says "VoiceError: 14" in chat when you enter the world
  ([#12](https://github.com/paulstraw/slashplayed/issues/12)). Slashplayed doesn't ask for the
  microphone.
- The game shows no on-screen keyboard: typing in chat, or an authenticator's code at sign-in, needs
  a hardware keyboard.
- A game patch can need a Slashplayed update before that game plays again.
- A game's intro movie doesn't play on its first launch on a device (the game's first session there
  would wait on it forever). It's in the game's Cinematics menu.
