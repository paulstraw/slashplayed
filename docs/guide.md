# Slashplayed guide

Everything past the [README](../README.md)'s getting started. When something goes wrong,
[troubleshooting](troubleshooting.md) has the fix for each message.

## Setup

Slashplayed comes in two parts: **Slashplayed Companion** on the Mac, which builds, signs, and
installs the app, and **Slashplayed** on the device, which runs the game.

The companion's setup assistant goes one step at a time and offers a fix for each problem it finds:
Xcode, your Apple ID and team, your devices, LocalDevVPN, and which games go on each device. An
optional step shows which games are installed on the Mac, if any. Then it installs Slashplayed on
each device you pick, and a last optional step sets up
[Update Games on This Device](#update-games-on-this-device). **Help > Setup Assistant…** runs the
checks again later.

- **Xcode** needs an administrator's password once, the first time it's set up. After that, a
  standard macOS account works ([details](troubleshooting.md#xcode)).
- **An iPad or iPhone** pairs over USB: click Allow when macOS asks to let the accessory connect,
  then tap Trust on the device.
- **Vision Pro** pairs in Xcode > Open Developer Tool > Device Hub, with Settings > General > Remote
  Devices open on the headset.

## Playing

Open Slashplayed on the device and tap a game. The Mac can be asleep or away.

Or press **Play** in the companion, with the game picked in the menu next to it. Battle.net doesn't
need to be running. Play updates the app first when it needs to: after a game patch, after you
change a device's games, and every 7 days on a free Apple ID. Keep the device awake while it works:
unlock the iPad or iPhone and connect its cable, or wear the headset.

The first start of each game takes a few minutes while it fetches its data from Blizzard (about 2.5
minutes to character select for Classic Era on an iPhone over Wi-Fi). After that, it fetches what
each zone needs while the game is on screen.

## Signing in

The first time, Slashplayed asks for your **Battle.net email and password**. It keeps them in the
device's keychain (that device only, never synced) and signs the game in with them at every start.
If your account has an authenticator, use the four-finger text composer on iPhone or iPad, or type its
code on a hardware keyboard. To sign in with another
account, tap **Forget My Sign-In** in Settings on Slashplayed's start screen (the gear).

If the device's sign-in stops working and the game is installed on the Mac, **Play with My Mac's
Battle.net** in the menu next to Play signs in through the Mac's Battle.net for that one launch. Click
the game's Play button in Battle.net when the companion asks. The companion catches the launch, moves
your Battle.net launch credentials to the device (it never reads their values), and closes the Mac's
copy of the game. Your saved sign-in stays for the next Play.

## Update Games on This Device

With this on, a device updates a game itself when Blizzard patches it, with no Mac. It's off until
you turn it on, per device, in the companion's Settings > **Updates on Devices**.

When you open a game and Blizzard has a newer build, Slashplayed says so before the game starts,
downloads the new build's game program (about 50 MB; on cellular data or in Low Data Mode it asks
first), and checks that this version of Slashplayed can run it. Tap **Update**, and a few seconds
later the new version starts and fetches the patch's data as you play. With the setting off, the
screen says to update on your Mac instead: the next Play from the companion installs the new build.

The device signs the new game program itself, so it needs a signing key from your team. Turning the
setting on says what will be sent and asks first.

- **A free Apple ID** sends a copy of the key the companion signs Slashplayed with: your team's
  Apple Development certificate and its private key. macOS asks once to allow the export.
- **A paid team** sends a certificate made only for Slashplayed, so nothing else on your Mac signs
  with it and you can revoke it on its own. Set it up once in Settings > Updates on Devices:
  1. **Make Certificate Request** saves `Slashplayed.certSigningRequest` to Downloads. Its key stays
     in a keychain of the companion's own, which Xcode never uses.
  2. On developer.apple.com, open Certificates, IDs & Profiles > Certificates, click +, choose Apple
     Development, upload the request, and download the certificate.
  3. **Choose Certificate…**, or drop it on the section. The companion checks it's for its key and
     your team.

  **Stop Using the Slashplayed Certificate** deletes it from the Mac, and each device deletes its
  copy at its next Play or Update Client. Revoke it on developer.apple.com to end it everywhere at
  once.

At every Play and Update Client, the companion checks with Apple that the certificate hasn't expired
or been revoked. If it has, nothing is sent, and the companion says what to make instead. When the
key changes, a game the device updated with the old key is signed again with the new one at its next
start; if no key on the device can sign it, the device plays the version the companion installed.

On the device, the key lives in Slashplayed's keychain only (that device only, never synced or backed
up) and signs only game programs. Turning the setting off deletes it at Slashplayed's next start;
**Forget Signing Identity** in Slashplayed's Settings deletes it at once. More in
[troubleshooting](troubleshooting.md#update-games-on-this-device).

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
  next Play.
- The first launch asks you to trust your Apple ID on the device.
- A free team can have only a few apps on a device.

A paid **Apple Developer Program** membership signs for a year, with none of those limits.
[Details](troubleshooting.md#free-apple-ids-personal-teams).

## Settings

- **The companion** (⌘,): team, bundle ID prefix, devices and their games, copying game files,
  updating games on devices, the game install, and update checks. Changing the team or bundle ID
  prefix makes a new app on each device, with no game files: they're fetched or copied again.
- **The device** (the gear on Slashplayed's start screen): the saved sign-in, the signing identity,
  each game's build, Open in Files, Reset Game Settings, and Display (the render scale).

## Touch controls on iPhone and iPad

Drag anywhere on the left or right half of the game to start a floating thumbstick. Each stick
appears where your finger landed and disappears when you lift. Short taps still click action bars
and game menus. Hold still for about half a second to right-click; keep holding and move to right-drag.

For mouse gestures, place **two fingers on the same half** before moving. Pinch apart to zoom in,
or together to zoom out. Move both fingers together to orbit the camera, or to drag an item or UI
element under the first finger. Two-finger tap right-clicks. One finger on each half still controls
the two sticks, and a movement stick can stay active while the other half handles a gesture.
Lift both gesture fingers before starting another gesture.

For precise dragging with one finger, **tap, then touch the same spot again within 0.3 seconds and
drag**. This sends a normal left-button drag instead of starting a stick. Action-bar locks still
apply: unlock the bar or hold the modifier the game requires using a custom touch button.

The small pill buttons use solid backdrops and cutout icons, with larger invisible touch targets.
The **LB** and **RB** buttons start in Toggle mode: tap to hold, then tap again to release.
The two upper buttons send the controller's **View** and **Menu** inputs as short taps. The game's
controller bindings decide what these do, just as with an Xbox controller.

Open **Settings > Touch > Touch Controls** before playing, or **four-finger tap > Controls** in game.
You can turn each stick off, change its radius and dead zone, adjust stick and button opacity
separately, change button size, and change the long-press delay. With a stick off, a drag on that half
acts as a mouse drag.

Pinch zoom, two-finger right-click, and double-tap dragging can each be turned off. **Two-Finger
Drag > Turn Character** makes the gesture a right-button camera drag; **Orbit / Drag Items** uses
the left button. **Zoom Sensitivity** adjusts the pinch's mouse-wheel input.

Each button has an editable label, position, binding, and **Hold**, **Tap**, or **Toggle** behavior.
**Add Button** supports gamepad buttons, keys or combinations such as `Shift+1` or `Ctrl+Alt+R`,
mouse clicks, **Keyboard**, and **Controls**. Keyboard and Controls always open on a tap.
Use **Arrange Buttons** in game to drag buttons into place, then tap **Done Arranging**.
Preferences stay on this device. Opening an editor or leaving the app releases held touch inputs.

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
- **Typing in the game:** on iPhone and iPad, tap with four fingers together for the text composer;
  Vision Pro needs a hardware keyboard. [Details](troubleshooting.md#no-on-screen-keyboard).
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
