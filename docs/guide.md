# Slashplayed guide

Everything past the [README](../README.md)'s getting started. When something goes wrong,
[troubleshooting](troubleshooting.md) has the fix for each message.

## Setup

Slashplayed comes in two parts: **Slashplayed Companion** on the Mac, which builds, signs, and
installs the app, and **Slashplayed** on the device, which runs the game.

The companion's setup assistant goes one step at a time and offers a fix for each problem it finds:
Xcode, your Apple ID and team, your devices, LocalDevVPN, and which games go on each device. An
optional step shows which games are installed on the Mac, if any. Then it installs Slashplayed on
each device you pick. **Help > Setup Assistant…** runs the checks again later.

- **Xcode** needs an administrator's password once, the first time it's set up. After that, a
  standard macOS account works ([details](troubleshooting.md#xcode)).
- **An iPad or iPhone** pairs over USB: click Allow when macOS asks to let the accessory connect,
  then tap Trust on the device.
- **Vision Pro** pairs in Xcode > Open Developer Tool > Device Hub, with Settings > General > Remote
  Devices open on the headset.

## Playing

Open Slashplayed on the device and tap a game. The Mac can be asleep or away.

Or press **Play** in the companion, with the game picked in the menu next to it. Battle.net doesn't
need to be running. After a game patch, Play copies just the new game program to the device (about
50 MB). It rebuilds the app itself only after a companion update, when you switch Apple ID or team,
and when the app's provisioning profile is two days from running out (every 5 days or so on a free
Apple ID, about once a year on a paid one). It installs the app again when the device's copy is
missing or came from another Mac.
Keep the device awake while it works: unlock the iPad or iPhone and connect its cable, or wear the
headset.

The first start of each game takes a few minutes while it fetches its data from Blizzard (about 2.5
minutes to character select for Classic Era on an iPhone over Wi-Fi). After that, it fetches what
each zone needs while the game is on screen.

## Signing in

The first time, Slashplayed asks for your **Battle.net email and password**. It keeps them in the
device's keychain (that device only, never synced) and signs the game in with them at every start.
If your account has an authenticator, type its code on the hardware keyboard. To sign in with another
account, tap **Forget My Sign-In** in Settings on Slashplayed's start screen (the gear).

If the device's sign-in stops working and the game is installed on the Mac, **Play with My Mac's
Battle.net** in the menu next to Play signs in through the Mac's Battle.net for that one launch. Click
the game's Play button in Battle.net when the companion asks. The companion catches the launch, moves
your Battle.net launch credentials to the device (it never reads their values), and closes the Mac's
copy of the game. Your saved sign-in stays for the next Play.

## Game patches on the device

A device updates a game itself when Blizzard patches it, with no Mac and nothing to set up, on a free
Apple ID too. When you open a game and Blizzard has a newer build, Slashplayed says so before the game
starts, downloads the new build's game program (about 50 MB; on cellular data or in Low Data Mode it
asks first), and checks that this version of Slashplayed can run it. Tap **Update**, and a few seconds
later the new version starts and fetches the patch's data as you play. **Play Anyway** plays the
version you have.

The companion's next Play copies the new build too, if the device hasn't taken it yet. Whichever gets
there first, the other leaves it alone, and a newer version the device took itself is never replaced by
an older one.

A game you haven't installed on the device reads **Install <game>** on Slashplayed's start screen: tap
it to download the game program, with no Mac. The game then fetches its data as you play.

## Game files on the device

Each game's folder is in the Files app, under On My iPad, On My iPhone, or On My Apple Vision Pro >
Slashplayed. A game's **Open in Files** in Slashplayed's Settings opens it.

- **Settings:** edit `WTF/Config.wtf`.
- **Addons:** put an addon's folder in `Interface/AddOns/`, making the folders if they aren't there.
- **Leave `Data/` and `.build.info` alone.** Deleting files there makes the game quit with
  ["installation is damaged"](troubleshooting.md#your-world-of-warcraft-installation-is-damaged).

## Copying game files from the Mac

If the game is installed on the Mac through Battle.net, turn on **Copy Game Files from This Mac** for
a device, and the companion copies the game's data before Play, instead of the device fetching it.
That helps on a slow connection. The first copy takes a while: Classic Era is ~25 GB, at ~33 MB/s over
the USB 2 cable an iPad or iPhone comes with (a USB 3 cable is several times faster). Later copies
send only what a patch changed.

The games share one store of data on the Mac, and Mists of Pandaria Classic's files are spread across
all of it, so copying it takes the whole store (~150 GB), though only about 23 GB is its own. Fetched
on the device, a game takes only what you've played: Classic Era is about 5 GB after 15 minutes
across three zones.

## Free Apple IDs and paid teams

A free Apple ID (a Personal Team) plays every game, with limits:

- The app's signature lasts **7 days**. The companion warns two days ahead and signs it again at the
  next Play. Or, optionally, sign in to Apple on the device (Slashplayed's **Settings > Signing > Sign In
  to Apple…**), and Slashplayed renews its own signing when a game starts in the last 3 days. That's a
  second sign-in to your Apple ID, through a third-party server, as sideloading tools do, so use a
  secondary Apple ID on the team if you can. Your password isn't kept.
- The first launch asks you to trust your Apple ID on the device.
- A free team can have only a few apps on a device.

A paid **Apple Developer Program** membership signs for a year, with none of those limits.
[Details](troubleshooting.md#free-apple-ids-personal-teams).

## Settings

- **The companion** (⌘,): team, bundle ID prefix, devices and their games, copying game files,
  the game install, and update checks. Changing the team or bundle ID
  prefix makes a new app on each device, with no game files: they're fetched or copied again.
- **The device** (the gear on Slashplayed's start screen): the saved sign-in, each game's build and
  where it came from, its region, Open in Files, Reset Game Settings, and Display (the render scale).

## Updates

The companion checks for its own updates (turn that off in Settings), or use **Slashplayed
Companion > Check for Updates…**. A game patch can need a new companion version: the companion then
says the game version isn't supported yet, and the device says "This patch needs a Slashplayed
update". If no update is out, the companion's **Report It…** opens a pre-filled issue.

## Known issues

- **Leaving the game for more than about 30 seconds can disconnect it**: closing its window, taking
  off the headset, or another app in front. The system suspends Slashplayed, and changes from that
  session can be lost. Use the game menu's **Exit** or **Log Out** first.
  [Details](troubleshooting.md#closing-the-window).
- **LocalDevVPN has to be on at every start.** Slashplayed's helper attaches to the game for a second
  or two to prepare its code, and reaches the device's developer services through LocalDevVPN. If
  it's off, Slashplayed opens LocalDevVPN and starts the game once it's on.
- **No on-screen keyboard in the game.** Chat and authenticator codes need a hardware keyboard, or on an
  iPad or iPhone, Paste from a two-finger hold.
  [Details](troubleshooting.md#no-on-screen-keyboard).
- **A mouse on an iPhone needs AssistiveTouch** for its cursor.
  [Details](troubleshooting.md#no-cursor-with-a-mouse-on-an-iphone).
- **No intro movie on a game's first launch.** On an empty device the intro never plays, so
  Slashplayed marks it seen; watch it from the game's Cinematics menu.
  [Details](troubleshooting.md#no-intro-movie).
- **A cinematic can stay black** in the game. Tap the screen, then **Yes**, to skip it.
  [Details](troubleshooting.md#a-cinematic-stays-black).
- **The window can vanish** after the headset has been off for a few minutes. Press Play again: it
  stops the running client first. [Details](troubleshooting.md#the-window-vanished).
- **Heat.** Capping the frame rate in game helps. [Details](troubleshooting.md#heat).
- **No voice chat yet.** The game shows "Can't connect to a voice chat server right now", and
  Slashplayed doesn't ask for the microphone. [Details](troubleshooting.md#no-voice-chat).
- **A game patch can break it** until Slashplayed catches up. See [Updates](#updates).

To report something else, attach the zip from **Help > Export Diagnostics…**. It leaves out your
launch credentials and blanks your devices' identifiers and personal details.
