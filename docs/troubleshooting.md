# Troubleshooting

What each companion message means and what to do about it. The headings follow the onboarding steps,
then the steps of a Play, then problems while playing. The quoted titles are what the companion shows.

When something here doesn't fix it, use **Help > Export Diagnostics…** (also offered as a button on
any failure) and attach the zip to a [bug report](https://github.com/paulstraw/slashplayed/issues/new/choose).
See [Export Diagnostics](#export-diagnostics) for what it holds.

## Setup

Each onboarding step has **Check Again**. **Help > Setup Assistant…** runs the steps again from the start.

### Xcode

The companion uses Xcode's own tools (`devicectl`, `xcodebuild`) to sign, install, and start
the client, so Xcode has to be installed, selected, set up, and licensed. Each of those setup steps
(Xcode's components, its platforms in Xcode > Settings > Components, `xcode-select`, the license)
changes the whole Mac, so macOS asks for an administrator's name and password. In a standard
account, have an administrator type theirs; the companion itself needs no administrator rights.

- **"Xcode isn't selected"**: no developer tools are selected, or the selected ones are the
  Command Line Tools rather than Xcode. Install Xcode from the App Store, open it once, then run:

  ```sh
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  ```

  (adjust the path if Xcode isn't in `/Applications`).
- **"Xcode isn't set up yet"**: open Xcode once so it installs its components, or run
  `sudo xcodebuild -runFirstLaunch`.
- **"Xcode's license isn't accepted"**: open Xcode once and accept the license, or run
  `sudo xcodebuild -license`.

### Apple account and team

The device app is signed with your own Apple developer team. Teams come from the accounts signed in
to Xcode.

- **No account**: sign in to Xcode with your Apple ID (Xcode > Settings > Apple Accounts,
  **Sign In…**), then **Check Again**. Your developer account's Apple ID, or any Apple ID for a free
  Personal Team (see below). The step sees a sign-in or sign-out in Xcode without restarting the
  companion. Once you've signed out of Xcode, Play and the step say
  **"No Apple account in Xcode for …"**, even with a team you used before.
- **"Xcode hasn't listed your teams yet"**: you're signed in, but when the companion asked Xcode for
  the account's teams, it listed none. Check that the Mac is online and that the account in Xcode
  doesn't ask for its password, then **Check Again**. Or type your Team ID (developer.apple.com >
  Account > Membership details) and click **Use This Team**: the companion checks it with Xcode before
  using it. A free Personal Team has no Team ID there: in Xcode, open any project, select its target,
  and choose your team in **Signing & Capabilities > Team**; the step then passes on its own.
- **Several teams**: pick one in **Settings > Signing**, which lists every team of every account
  signed in to Xcode, Personal Teams included (opening Settings asks Xcode for them again, so an
  account you just added shows). For a team that isn't listed, type its Team ID there and click
  **Use…**, or in Help > Setup Assistant under **Use a team that isn't listed**.
- **"Team … isn't signed in"**: the device app was signed with a team that no account in Xcode has
  any more. Sign that Apple ID back in to Xcode, or pick another team in Settings > Signing.
- **"No signing key for …"**: Xcode signed with a certificate whose private key isn't in this Mac's
  keychain (it was made on another Mac). In Xcode > Settings > Apple Accounts, select your account,
  then the team, **Manage Certificates…**, and add an Apple Development certificate. If it was made in
  another macOS user account on this Mac, see
  [Several macOS users on one Mac](#several-macos-users-on-one-mac).

#### Free Apple IDs (Personal Teams)

A free Personal Team signs Slashplayed and runs every game, Retail included. Apple doesn't give
free teams the `extended-virtual-addressing` entitlement, so the companion leaves it out for them;
`increased-memory-limit` is enough. The differences from a paid team:

- **The signature lasts 7 days.** After that the device won't open Slashplayed. Within two days of
  that, the main window warns and offers **Rebuild Now**, and **Play** signs the app again on its
  own. Once a game has started on the device in its last 3 days, the device's start screen says so
  too, with the day it stops opening (nothing checks before a game starts). Rebuilding is about a minute on the Mac plus an install; the game files on the device stay.
  To skip the weekly rebuild, sign in to Apple on the device (Slashplayed's **Settings > Signing > Sign
  In to Apple…**, optional): Slashplayed then renews its own signing when a game starts in its last 3
  days. It's a second sign-in to your Apple ID through a third-party anisette server, so a secondary
  Apple ID on the team is safest. The password is used once and isn't kept; only an Apple token is, in
  the device's keychain, until **Forget Apple Token**.
- **Trust the developer once.** The first launch on each device fails with "Untrusted Developer".
  On the device open **Settings > General > VPN & Device Management**, tap your Apple ID under
  Developer App, tap **Trust**, then press **Retry Launch** in the companion.
- **App limits.** A device holds at most three apps signed by free teams, counting every free Apple
  ID together (an app's extensions don't count), and a free team can make only a few new App IDs a
  week. If the install fails with "maximum number of installed apps using a free developer profile",
  delete another app signed by a free Apple ID from the device. If Xcode refuses ("… is a free team
  and Apple refused this"), wait a few days.

With both a paid and a free team in Xcode, the companion picks the paid one; Settings > Signing
switches.

Changing the team or the bundle ID prefix (Settings > Signing) makes a **new app** on each device,
and a new app starts with no game files: it fetches them from Blizzard again as you play, or with
copying on, every game file is copied again. Only change them on purpose.

### Device and Developer Mode

- **"No device is paired yet"**: pair the device with this Mac. The step keeps these instructions on
  screen after the first device, for adding another.
  - iPad or iPhone: connect it with its USB cable and unlock it. Click Allow when the Mac asks to let
    the accessory connect, then tap Trust on the device. It shows up in the step on its own.
  - Vision Pro: on the headset open Settings > General > Remote Devices; then in Xcode choose
    Xcode > Open Developer Tool > Device Hub, select the headset, and pair it.
- **"This iPad can't run Slashplayed"** (or "This iPhone…", or your device's name): Slashplayed needs
  an iPad with an M1 chip or later or the A17 Pro iPad mini, an iPhone 15 Pro or later, or a Vision
  Pro. The game is built for the M1's instruction set and stops at once on an older chip, and it needs
  8 GB of memory, which the other A-chip iPads (the iPad mini 6, the 10th- and 11th-generation iPads,
  and the 4th-generation iPad Air) and the iPhone 15 don't have. The device menus still list such a
  device, marked "not supported", but don't let you pick it, and Play stops before building anything
  for one picked earlier: choose another device.
- **"Untested: Slashplayed hasn't been tried on an M1 iPad yet"**: M1 iPads (the 2021 iPad Pros and
  the 5th-generation iPad Air) run the game's instructions, but they protect code differently from
  the M2 and later, and Slashplayed has only been played on the newer chips. Nothing stops you: play
  as usual, then please [report how it goes](https://github.com/paulstraw/slashplayed/issues/new/choose),
  working or not, with the zip from **Help > Export Diagnostics…**.
- **"Untested: Slashplayed hasn't been tried on the A17 Pro iPad mini yet"**: the iPad mini (A17 Pro)
  has the iPhone 15 Pro's chip and 8 GB of memory, so it should run the game, but no one has played on
  one yet. Nothing stops you: play as usual, then please report how it goes in the same way.
- **"Developer Mode is off"**: on the device, Settings > Privacy & Security > Developer Mode (it only
  shows there once the device has been paired with Xcode), turn it on, restart when asked and confirm.
- **"Xcode can't see the device"** (while making the provisioning profile): Xcode couldn't reach the
  device to register it with your team. Unlock it, keep it on the same network as the Mac (or on
  USB), check it's listed in Xcode > Open Developer Tool > Device Hub, and try again.

### Games per device

Each device holds only the games ticked for it (onboarding, or Settings > Games, which
**File > Games…** opens). Copied from this Mac, they take: Classic Era ~25 GB, Classic Era + Anniversary ~37 GB,
MoP Classic ~150 GB, Retail ~150 GB. The games share one store on the Mac: MoP
Classic's ~23 GB of blocks are spread over every archive of it, so its copy takes the whole
store and covers the others as well, and Retail uses nearly every archive. A game that fetches its own
data takes only what it has needed so far (Classic Era: about 5 GB after 15 minutes across three zones).

Retail on the iPad or iPhone needs a 512 GB or larger device.

Ticking a game copies its game program to the device at the next Play (about 50 MB); neither ticking nor
unticking rebuilds the app. See
[Not enough space on the device](#not-enough-space-on-the-device) for what unticking frees.

### Copying game files, or not

**Copy Game Files from This Mac** is a choice per device, in Settings > Games (**File >
Games…**). With no game installed on this Mac it's shown off and can't be turned on. It's off for a device paired after it was added, and on for devices Slashplayed already
knew.

- **Off**: Play sends only the few small files the game needs to start, and the game fetches the rest
  of its data from Blizzard on the device as you play. The first launch of a game from nothing takes a
  few minutes (see [The first start of a game](#the-first-start-of-a-game)), and the game's
  "downloading" indicator may stay up while it fetches what each zone needs. It only fetches while
  it's on screen. A patch needs no copy. This is the only way when no game is installed on this Mac.
- **On**: Play first copies this Mac's game files, as Copy Game Files in the File menu always does
  (whichever way the setting is). The first copy is large; later copies send only what changed.

**The cable sets the speed** of a copy to an iPad or iPhone. The cable that comes in the box is USB 2,
about 32 MB/s: Classic Era (33 GB) took 17 minutes on an iPhone 16 Pro. An iPhone 15 Pro or later Pro
and every M-chip iPad do up to 10 Gbit/s with a USB 3 cable, several times faster. When one of them
copies over a USB 2 link, the main window says **"This cable is USB 2; a USB 3 cable copies game files
several times faster"** by the device's status, and under a copy's progress. With a USB 3 cable and
the line still there, try another port: some Macs have a USB 2 port. The headset copies over Wi-Fi
(about 27 MB/s).

Even with copying on, a copy leaves the device's game data as it is when it can't be mixed with this
Mac's, and the files step says which:

- **"The <device> has a newer build of <game> than Slashplayed built"**: the device has a later
  version than its copy of the game, so nothing of the Mac's goes over it. The game updates its data
  itself.
- **"This Mac's <game> isn't the build Blizzard has out now"**: the companion builds every game from
  Blizzard's current build, and the Mac's install is older (Battle.net hasn't updated it yet), so its
  data isn't copied. The game on the device fetches what the new build needs. Let Battle.net update
  the game on this Mac to copy from it again.
- **"This Mac's <game> hasn't run since Battle.net updated it"**: Battle.net finishes a game's data
  only after it next runs on this Mac, so a copy made before that can leave the game unable to start
  on the device (see [below](#invalid-schema--for-table-startupfiles)). The game on the device fetches
  what it needs instead. Play the game once on this Mac through Battle.net (to the character list is
  enough), quit it, and the next Play copies it. This happens after every patch Battle.net installs
  for a game you don't then play on this Mac.
- **"The game on the <device> has added data of its own since the last copy"**: the game on the device
  fetched data itself (with copying off, or for content this Mac didn't have), and copying this Mac's
  files under it would leave its indexes pointing at data that isn't there. It keeps fetching what it
  needs.

### Game install and Battle.net (optional)

Neither is needed. The companion builds each game from the Mac client it downloads from Blizzard, the
game on the device fetches its own data, and you sign in on the device. A game Battle.net installed on
this Mac adds two things: **Copy Game Files from This Mac** (above), and **Play with My Mac's
Battle.net** in the menu by Play, which shows only when one of the device's games is installed here.
The onboarding step lists what it found and always passes.

- **No game found, though one is installed**: it's somewhere other than `/Applications/World of
  Warcraft`. Choose its folder (the one holding `_classic_era_`, `_anniversary_`, `_classic_`, `_retail_`, or `_forever_`) in
  the onboarding step or Settings > Game Install.
- **"No game in …"**: the folder you chose holds none of those. Choose the World of Warcraft folder
  itself, or use the default.
- **Battle.net not running**: Play doesn't need it. Open it for **Play with My Mac's Battle.net**,
  which moves your Battle.net launch credentials to the device and closes the Mac game before it
  starts. The values are never read or logged. Battle.net also keeps the Mac's games up to date; a
  Mac install that's older than Blizzard's current build isn't copied (see above).
- **Battle.net quits or crashes as it opens** in a second macOS user account: see
  [Several macOS users on one Mac](#several-macos-users-on-one-mac).

### Install Slashplayed

The step installs Slashplayed on each device you press **Install** for, as Play does without starting
the game: it builds the app, signs it, installs it, sends each game's small build files, and pairs an
iPad or iPhone over USB. It passes once one device has it; the others can be installed later from the
step (Help > Setup Assistant…) or with Play.

- **"Slashplayed isn't on a device yet"**: press **Install** for the device you'll play on.
- **"… needs an update"**: the device has Slashplayed, but not this Mac's current build: an earlier
  one (the iPad and iPhone share one build, so installing on one can leave the other behind), one with
  other games than the ones you chose, or one installed from another Mac or Xcode. Press **Update**.
- **"Not installed from this Mac"**: this Mac hasn't installed Slashplayed there. The device may have
  another Mac's, or none. Press **Install**.
- An install that stops shows the same message Play would, under the device list: see
  [Playing](#playing) for each one, e.g. ["Couldn't install the client"](#couldnt-install-the-client).

### Several macOS users on one Mac

Slashplayed works from any macOS user account. Some things it relies on are kept once per Mac and
others in one account's keychain, so a second account on a Mac where another one already uses Xcode
(or Battle.net) runs into these:

- **"This Mac's signing certificate is in another keychain"**: Apple gives an Apple ID one Apple
  Development certificate per Mac, and its private key stays in the login keychain of the macOS user
  whose Xcode made it. In that account, open Xcode > Settings > Apple Accounts, select the account,
  then the team, **Manage Certificates…**, Control-click the Apple Development certificate and choose
  **Export**, with a password. Open the exported file in this account (it goes into the login
  keychain), delete the file, and **Check Again**. If no account has the key any more (or macOS was
  reinstalled since), revoke the certificate in Manage Certificates and Xcode makes a new one; anything
  signed with the old one has to be signed again. ["No signing key for …"](#apple-account-and-team) is
  the same problem when the certificate came from another Mac.
- **Xcode's sign-in is gone after the login keychain was reset**: Xcode keeps its account's sign-in,
  and your Apple Development key, in the login keychain. When an account's password is reset rather
  than changed (by an administrator, or at login), macOS can't open the old login keychain, starts a
  new one, and keeps the old one beside it as `~/Library/Keychains/login_renamed_1.keychain-db`.
  Xcode's settings may still list the Apple ID, and the companion says
  **"No Apple account in Xcode for …"**. Sign in to Xcode again (Settings > Apple Accounts, **Sign In…**). The key went with the old
  keychain: if you know its old password, add it in Keychain Access (File > Add Keychain), unlock it,
  and export the Apple Development certificate from it as above; otherwise revoke the certificate and
  let Xcode make a new one.

Battle.net is optional (see [above](#game-install-and-battlenet-optional)); these only matter for
**Copy Game Files from This Mac** and **Play with My Mac's Battle.net** in a second account:

- **The account has to be an administrator.** Blizzard's games need an admin login on a Mac.
- **One Battle.net per Mac at a time.** Quit Battle.net in the other account first, including its
  background **Agent** (Activity Monitor, filtered on "Agent"; after a repair it may run as root).
- **Battle.net quits silently as it opens**: Blizzard's shared folders belong to the account that installed
  it first, and Battle.net quits when it can't make them writable. Blizzard keeps them writable by every
  account; from an administrator account run
  `sudo chmod -R a+rwX /Users/Shared/Blizzard /Users/Shared/Battle.net`.
- **Battle.net's installer crashes within seconds** (each account installs its own copy of the app on
  first open): on Apple silicon, Blizzard's installer crashes when its error reporter,
  `/Users/Shared/Battle.net/Agent/Blizzard Error.app`, is already there from the first account's install.
  Rename it (for example to `Blizzard Error.app.aside`) while the installer runs, and rename it back
  afterwards. A Mac's first install never has it, which is why only second accounts, repairs, and
  reinstalls hit this.

## Playing

### "Battle.net didn't start the game"

These come from **Play with My Mac's Battle.net** (the menu by Play), the only Play that uses Battle.net.

- **"… isn't on the <device>"**: you pressed Play in Battle.net on a game that isn't ticked for this
  device. Tick it in Settings > Games, or pick a ticked game in Battle.net.
- **"Battle.net launched … without -launcherlogin, so it made no new token"**: Battle.net started
  the game without fresh launch credentials. This happens after Battle.net has been open a long time
  (overnight, for example). Quit Battle.net completely, reopen it, and try again. Without this check
  the old, already-used credentials would be sent, and the login on the device fails.
- **Nothing happens after Play in Battle.net**: Battle.net sometimes starts no game at all (its own
  log shows an SSO timeout). Quit and reopen Battle.net, wait a moment, and try again.

### "No new login token"

"Battle.net didn't write a new token within 15 s": as above, restart Battle.net and try again.

### "<device> not found" / waiting for the device

- **Vision Pro**: it has to be awake and on the same Wi-Fi network as the Mac. Put it on (or wake
  it) and the step continues on its own. Unworn on a desk, it usually stays reachable for listings,
  copies and installs; once taken off it locks.
- **iPad or iPhone**: connect it with its USB cable.

### "Waiting for Battle.net to finish updating…"

Game files are only copied once the Mac's install has been untouched for 2 minutes, so a copy never
catches a half-written patch. Battle.net also touches some files when you press Play, so this wait
can appear right after a Play that has files to copy. Wait it out.

### "The game install isn't responding"

The Mac's game install (Settings > Game Install) didn't answer a read within 5 seconds. That usually
means an external drive that's asleep, busy (a Time Machine backup can hold it for many minutes), or
disconnected. Play reads the install only when it needs it: to copy game files to a device that has
Copy Game Files from This Mac on, to finish a copy that stopped, or for Play with My Mac's Battle.net.
With copying off, Play doesn't touch it at all. Press Play again once the drive answers, or turn
copying off for the device (Settings > Games) so the game streams its data instead.

### "Couldn't update the game files"

- **"The system failed to get a list of files on the remote device"** or **"the device was still
  locked"**: the device locked during a listing or copy. The companion retries a few times, but a
  locked headset can refuse file access entirely. Keep the headset on, or unlocked, while it copies;
  on the iPad or iPhone, set Auto-Lock to Never (Settings > Display & Brightness) during a long
  copy. Then press Play again: the copy resumes where it stopped (only changed files are sent).
- A first copy is large (Classic Era ~25 GB, Retail ~150 GB at roughly 30 MB/s over a USB 2 cable or
  the headset's Wi-Fi: about 13 minutes for Classic Era and over an hour for Retail; a USB 3 cable is
  several times faster, see [Copying game files, or not](#copying-game-files-or-not)). Later copies
  send only what a patch changed. Or turn
  copying off and let the game fetch its own data (see
  [Copying game files, or not](#copying-game-files-or-not)).

### "The last copy of game files … stopped before it finished"

A copy of game files was stopped partway (the Mac slept, the cable came out, or the companion quit).
The game data on the device is then a mix the game can't read, so it would quit with "Your World of
Warcraft installation is damaged"; Slashplayed says this instead. Connect the device and press Play
in the companion: it finishes the copy first, even if copying is off for the device (only the games
ticked for it). If the companion says the copy can't be finished, do what it says (for example, let
Battle.net finish updating the Mac's game), then press Play again.

### "Your World of Warcraft installation is damaged"

The game quits a few seconds in with this when the game data in `Documents/Data/` can't be read: a copy
of game files stopped partway (Slashplayed catches that one and says so, above), or files were deleted
from `Data/` (or `.build.info`) in the Files app or Finder. To fix deleted files:

- **Copying game files on**: press Play in the companion. It copies what's missing again.
- **Copying off**: delete the whole `Data` folder (in Files: On My iPhone, On My iPad, or On My Apple
  Vision Pro > Slashplayed), then press Play in the companion. It sends the game's configs again, and
  the game fetches its data from Blizzard as on its first start.

Edit only a game's own folder (`_classic_era_`, `_retail_`, and so on): its `WTF/` and
`Interface/AddOns/`.

### "Invalid schema … for Table StartupFiles"

The game sits on its loading screen for a few minutes, then quits with this error. Its game data was
copied from this Mac after Battle.net patched the game there but before the game ran on this Mac
again, and Battle.net only finishes a patched game's data after that run. This version of Slashplayed
doesn't copy a game's data in that state (the files step says "hasn't run since Battle.net updated
it"), but a device copied by an earlier version can still have it. To fix it, play the game once on
this Mac through Battle.net, quit it, then press Play in the companion with copying on: it copies
only what changed (1.64 GB for TBC Anniversary).

### Not enough space on the device

"<games> needs … more on the <device>, but it has … free": the copy is stopped before it starts, so
the device isn't filled partway.

- Untick a game in Settings > Games, or free space on the device.
- **Unticked games are freed only at the next client start.** Xcode's device tools can copy files but
  not delete them, so the companion leaves a list, and the client deletes those files when it next starts.
  So to swap one game for another: untick the new game for now, play the remaining game once (that
  frees the old one's files), then tick the new game and play again.
- The free space shown is the figure in the device's Settings > General > <device> Storage (e.g. iPhone
  Storage), which counts space the device can clear (caches) as free. An iPad or iPhone the Mac can
  reach reports it as it is now; the headset, as of the client's last start. Before Slashplayed first
  starts on an iPad or iPhone, the Mac only knows the space free without what it can clear, and shows
  it as "at least …". Before the headset's first start it's unknown, and the first copy goes ahead
  unchecked.

### "<Game> <build> isn't supported yet"

"<Flavor> <build> isn't supported by this version of Slashplayed yet. Check for updates; if there
isn't one, report it."

A game patch made the client use a system function the shims don't provide yet. That game's new
version isn't copied, and nothing of it reaches the device.

1. **Slashplayed Companion > Check for Updates…**: a release with support for the new build may
   already be out.
2. If not, click **Report It…**: it opens the "New game patch broke it" issue form with the flavor,
   build and missing functions filled in. Submit it as is.

Other flavors that aren't affected keep working if you untick the broken one.

### "Couldn't install the client"

Usually a signing problem (see [Apple account and team](#apple-account-and-team)) or Developer Mode
(see [Device and Developer Mode](#device-and-developer-mode)). The message names which.

### "Lost the connection to the headset" (or iPad, or iPhone)

The connection over Wi-Fi was cut off four times in a row, during the install, a copy, or the launch.
A headset that isn't worn drops its connection to the Mac every minute or so, and the companion already
waits for it to come back and tries again. Put the headset on, or keep the iPad or iPhone unlocked (or
connect it with a USB cable), and press **Play** again.

### "Slashplayed isn't installed on the iPad" (or iPhone, or headset)

The app was deleted on the device, so there's nowhere to copy its files. Press **Play**: the companion
installs it again, and on an iPad or iPhone pairs it over USB as it does.

### "The client didn't start"

- **Vision Pro**: "no process after 60 s". The client can only start while the headset is worn;
  a launch while it's locked waits until it's put on. Put the headset on and press **Retry Launch**. (While locked, the companion shows "Put on the headset
  to start the client" and waits.)
- **iPad or iPhone**: unlock it and press **Retry Launch**.
- **"Untrusted Developer"** on the device (free Personal Teams, first launch): trust your Apple ID in
  Settings > General > VPN & Device Management, then press **Retry Launch**. See
  [Free Apple IDs](#free-apple-ids-personal-teams).
- **The profile ran out** (free teams, after 7 days): press **Rebuild Now** in the main window, or
  **Play**, which signs the app again. To keep it from running out, see the device's Sign In to Apple in
  [Free Apple IDs](#free-apple-ids-personal-teams).

### "Preparing code pages failed"

Every launch, Slashplayed's helper, an extension inside the app, attaches to the game once, at
startup, to prepare its code (see [The on-device JIT helper](architecture.md#the-on-device-jit-helper)).
When it can't, Slashplayed shows why on the device instead of starting the game, and the companion
shows the same message:

- **"Turn on LocalDevVPN"**: it's off (it doesn't turn itself back on after a restart). Slashplayed
  opens LocalDevVPN to turn it on, which comes straight back to Slashplayed, and the game starts once
  it's on. If that didn't take, press **Turn On LocalDevVPN**, or turn it on in LocalDevVPN and come
  back: there's no need to close Slashplayed. While the device waits, the companion's step says the same.
- **"couldn't reach this … 's developer services, though LocalDevVPN is on"**: the tunnel didn't come
  up anyway. In LocalDevVPN, turn it off and on again, then close Slashplayed and open it again (or
  press **Retry Launch**).
- **"isn't paired with this … yet"** or **"no longer accepts Slashplayed's pairing"**: the app has no
  pairing record, or the device stopped accepting it. On an iPad or iPhone, connect it to the Mac with
  its USB cable and press **Play** (or **File > Update Client**): the companion pairs it over USB, with
  no prompt on the device. **File > Pair Again** makes a new pairing at any time. The Vision Pro pairs
  on its own instead (below).
- **"Pair Slashplayed with this Vision Pro"** (on the headset): its first launch, or after Slashplayed
  was removed under Remote Devices. Open **Settings > General > Remote Devices** and keep it open; when
  it shows a code, type it into Slashplayed. The first time, the headset asks to let Slashplayed find
  devices on the local network: allow it (if it was refused, turn it on in **Settings > Apps >
  Slashplayed**). LocalDevVPN has to be on for this too. Once paired, Slashplayed shows under Remote
  Devices. If no code shows, press **No code? Get a new one**. Don't clear the whole Remote Devices
  list: this Mac is in it too, and the companion can't reach the headset until it's paired again in
  Xcode's Device Hub. To pair Slashplayed again later, use **File > Pair Again** with the headset
  selected; its next launch asks for a code.
- **"needs Apple's developer disk image"**: the device has none mounted, and the app has no copy to
  mount. **Play** or **Update Client** copies the one from the Mac's Xcode.
- **"Mounting Apple's developer disk image failed"**: the device asks Apple's server for the image's
  signature, so it has to be online.

The launch's log is `~/Library/Logs/Slashplayed/console.txt`: the launcher's lines start with
`[sp:launch] jit:`.

### "<Game> <version> is out" on the device

Before the game starts, the device asks Blizzard's patch service which build is current, and that one
is newer than the device's copy of the game. The screen first checks whether this version of Slashplayed
can run the new build: the device downloads the new version's game program from Blizzard (about 50 MB,
once per version; on cellular data or in Low Data Mode it asks first) and compares what it needs with
what Slashplayed provides. Then it says one of three things:

- **"This <device> can update itself in a few seconds"**, with **Update**: tap it, and the device puts the
  new version in place and starts it. Nothing on the device needs a signing key, so this works on a free
  Apple ID too.
- **"This patch needs a Slashplayed update"**: the new build uses something this version of Slashplayed
  doesn't provide yet. Check for updates in the companion (Slashplayed Companion > Check for Updates…);
  if there isn't one yet, the companion's own check reports it when you press Play, with a link to
  report it.
- **"Whether Slashplayed can run it couldn't be checked"**: the download failed, or you chose Not Now.
  Open the game again on Wi-Fi, or press Play in the companion, which copies Blizzard's current build to
  the device itself.

**Play Anyway** starts the copy the device has; the game's servers may not accept an outdated build.
When the device can't reach the patch service (no network, or it's slow to answer), it starts the game
without checking, after a few seconds at most. The log lines start with `[sp:launch] patch:`, and an
update's with `[sp:launch] update:`.

The companion's next Play or Update Client copies Blizzard's current build to the device when the
device's is older, and the device then deletes the download it kept for Update (`update: retired`). If
the device's own update is newer than the build the companion found (it couldn't reach Blizzard), its
main window says so ("Classic Era 1.15.9.70003, updated on the iPhone"), the device keeps playing its
own, and the companion leaves that game's build files on the device as they are, even with Copy Game
Files from This Mac on.

### Updating on the device: the update didn't work

- **On cellular data or in Low Data Mode**, the device asks before the ~50 MB download: **Download** or
  **Not Now**. Not Now starts nothing new, and the next start on Wi-Fi downloads it without asking. A
  download is made once per version; Update itself downloads only the new version's two small build
  files (under 100 KB).
- **"<Game> couldn't be updated on this <device>"**: putting the new version in place failed; the screen
  gives the reason, and `[sp:launch] update: failed after …` has it too. Play Anyway starts the version
  the device has. Press Play in the companion to copy it from the Mac, and export diagnostics if it
  repeats.
- **"<Game> <version> couldn't be loaded on this <device>"**: the game program didn't load (the reason
  follows: something it needs that Slashplayed doesn't provide, or a file that isn't a game program it can
  load). A bad file is deleted, so the next start downloads it again, or the companion's next Play copies
  it. If it keeps happening, check for a Slashplayed update and export diagnostics.
- **"This version of iOS (or visionOS) doesn't have what Slashplayed needs to load the game"**, before
  the sign-in: Slashplayed loads the game program with system functions Apple doesn't document, and this
  OS version doesn't have one of them. Nothing else on the device changed. Check for a Slashplayed update.

### Installing a game on the device

A game you haven't put on the device reads **Install <game>** on Slashplayed's start screen. Tapping it
downloads the game program from Blizzard (about 50 MB, asking first on cellular data), in the device's
region, and then the game fetches its data as you play. Any failure says why, with **Back**.

After an update from Slashplayed 1.4 or earlier, the first start of each game shows **"Getting <game>
ready…"**: the device downloads its game program once (about 50 to 58 MB), since the app no longer
carries the games. It needs the network that one time. Pressing Play in the companion first copies it
from the Mac instead.

### The first start of a game

A game that has no data on the device yet (a new device with copying off, or no game installed on
this Mac) starts with only a few small files the companion sends, and fetches the rest from Blizzard
itself. That first start takes a few minutes:

1. The game's name with **Preparing game data** and a percentage, for 10 to 15 seconds while the game
   sets up its data.
2. **Loading…** with a spinner, for up to a minute and a half while it fetches what it needs to start.
3. The login screen (under a minute in for Classic Era on an iPhone over a good Wi-Fi connection,
   about 2 minutes over a slower one), then character select. The world's first load takes about a
   minute more.

On later starts the loading screen shows for a few seconds. If it stays on **Loading…** for many
minutes, the device is likely offline or the connection is very slow (see
[Slow loading](#slow-loading-or-the-downloading-indicator-stays-up)); a black
screen with no loading screen at all means the device has an older Slashplayed build: press Play in
the companion again.

It only fetches while it's on screen: leave the device unlocked with Slashplayed in front until
character select. The device's free space drops by a few hundred MB in the first minute (the game's
indexes) and grows from there. Later starts take seconds, and a patch fetches only what changed.

### No intro movie

Slashplayed marks each game's intro movie as seen on its first launch on a device, so the game goes
straight to its login. A game's first session on an empty device sets up its data first, and an intro
started then never plays: the game waits on a black screen with only its download bar at the top for
as long as it's left. Its next session plays the intro at once. To watch it, use **Cinematics** in the
game's menu on its login or character screen. If a black screen with only the download bar shows up
anyway, press **Play** in the companion again.

### A cinematic stays black

In the game, a cinematic (entering a new zone, or one a quest plays) can stay black with no sound
while the game carries on underneath. It's intermittent on a device: the same cinematic plays
later. Tap the screen to bring up **Are you sure you want to skip this cinematic?** and tap **Yes**
(or press Escape on a keyboard). A tap does this on any cinematic in the game, so one that's playing
can be skipped the same way, and **No** goes back to it. On the login and character screens (the
intro, the **Cinematics** menu) a tap doesn't: press Escape on a keyboard, or close Slashplayed.

### "The client stopped"

"It quit with exit code …": the last messages are in `~/Library/Logs/Slashplayed/console.txt`, and
the device's own log is `Documents/spconsole.log` (File > Pull Device Logs fetches it, plus crash and
jetsam reports). Export Diagnostics and file a bug if it repeats.

**Login fails on the device** (an error at the login screen right after starting): see
[Signing in](#signing-in).

### Signing in

- **"You have been disconnected. (BLZ51914500)"** right after starting: Battle.net refused the email
  or password Slashplayed saved. Open Slashplayed, tap the gear on its start screen, tap **Forget My
  Sign-In**, then **Sign In…**, and sign in again. (Typing them into the game's own login screen doesn't work: it fails
  with the same error even when they're right.)
- **Stuck at the authenticator prompt**: the game asks for the code in its own window, and takes typing
  only from a hardware keyboard. Connect one, type the code, and press Return.
- **"Unlock this iPad/iPhone, then open Slashplayed again"**: the saved sign-in is in the keychain,
  which can't be read while the device is locked (a launch from the companion with the device asleep).
- **Using the Mac's Battle.net instead**: **Play with My Mac's Battle.net** in the menu by Play signs
  in with the Mac's Battle.net for that launch, saved sign-in or not, and leaves the saved sign-in for
  the next Play. If that login fails, its launch credentials were stale: restart Battle.net and try
  again.
- **The game's login screen, with no sign-in tried**: the client signs in from the saved sign-in only
  when it's started with Battle.net's `-launcherlogin` option. Play and the home screen both pass it;
  a launch from another tool with no arguments may not.

## While playing

### Heat

Heat is the main limit on session length. On the Vision Pro the device reaches a `serious` thermal
state after a few minutes to about a quarter of an hour, depending on the game, settings and how
cool it started; on the iPad the game runs
uncapped by default, at 120 fps, and long sessions get hot. Retail on an M2 iPad reaches
`serious` within minutes and gets a memory warning, though the system doesn't stop it. What helps:

- Scale **1x** in the app's Settings on the device (the start screen's gear, Display; Automatic's
  choice, except on an iPhone) cuts GPU work a
  lot, though measurements show it doesn't delay heat much on the headset. An iPhone defaults to 2x,
  with the game's own render scale at 50%, so its UI is readable; if you switch an iPhone to 1x,
  set the game's render scale back to 100% in its graphics settings, or the world looks blurry.
- In-game: cap the frame rate (the graphics settings' maximum foreground FPS), and lower render
  scale and graphics quality.
- Take breaks; a cool-down of 15 minutes or more makes the next session last noticeably longer.

Measurements are in [architecture.md, Heat](architecture.md#heat).

### Space does nothing (no jumping) with a hardware keyboard

Turn off **Full Keyboard Access** on the device (Settings > Accessibility > Keyboards > Full Keyboard
Access). While it's on, the system takes a plain Space press as "activate" and the game never sees
it; other keys, and Space with Shift held, still get through. Seen on the Vision Pro and the iPhone.
It can be turned off while the game runs; no relaunch is needed.

### No cursor with a mouse on an iPhone

Turn on **AssistiveTouch** (Settings > Accessibility > Touch > AssistiveTouch). An iPhone has no
pointer of its own: without AssistiveTouch a Bluetooth mouse connects, but the system passes the game
no movement, buttons or scrolling. With it on, the game's cursor follows the mouse and all five
buttons work, as on an iPad.

AssistiveTouch draws its own circle at the pointer, over the game's cursor; the game can't hide it,
and it keeps moving during mouselook (an iPhone doesn't lock the pointer, as an iPad does): turning
works, and the cursor comes back where mouselook started.
To make it much less obtrusive, recolor it and turn off its border in
Settings > Accessibility > Accessories > **Pointer Control**, which is listed only while the mouse is
connected. Touch and a hardware keyboard work without AssistiveTouch.

### No on-screen keyboard

Tapping the chat box (or any text field) brings up no on-screen keyboard: the game takes typing only
from a hardware keyboard, so chat, and an authenticator's code at sign-in, need one. Tested on the
iPhone; a Bluetooth keyboard works, chat included. (Slashplayed's own screens, such as the sign-in
screen, do get the on-screen keyboard.)

On an iPad or iPhone you can paste instead: copy the text in another app, tap the game's text box, hold
two fingers still on it for a moment, and lift them. Tap **Paste** in the menu that opens. The same
menu's **Copy** copies what's selected in the box.

### Closing the window

The same goes for anything that takes the game off screen: taking off the headset, or another app in
front.

- **A short close (about 30 s or less)** usually keeps you in the game: Slashplayed asks the system
  for time to keep running in the background, and gets about 30 s. Reopening resumes it.
- **Longer closes** can drop the server connection: after that the system suspends the game, and no
  app can keep running longer. The client often reconnects by itself (if it shows you disconnected,
  see [below](#the-connection-dropped-while-backgrounded)), but **settings and keybind changes made in
  that session can be lost**: the game saves them to the server only when you log out or exit, and
  after a dropped connection it downloads the old server copy over them.
  To keep changes, use the game menu's **Exit** (or Log Out) before closing the window. Killing the
  client (Stop Client) loses unsaved changes the same way.

### The window vanished

Seen once: after the headset was off for a couple of minutes (and hot), the game window didn't come
back, and tapping the app icon did nothing, though the client was still running. Press **Stop
Client** in the companion (or force-quit the app on the device), then Play again. If it happens to
you, pull the device logs right away (File > Pull Device Logs) and include them in a bug report: the
log records the window's state for exactly this case.

### Slow loading, or the downloading indicator stays up

A game that fetches its own data (copying off) shows the game's own "downloading" indicator while it
fetches what a zone needs; on a good connection it plays normally meanwhile (Classic Era held 60 fps on
an iPhone while it was up). The game fetches at about 2 MB/s on a device, so it needs a steady
connection more than a fast one. On a poor one:

- The first start takes longer, and loading screens (zoning, the first world load) wait for what they
  need. Textures or models can show late in a zone it hasn't fetched yet.
- Retail fetches far more than Classic Era: on an M2 iPad its first start from nothing reached
  character select in about a minute, then sat at the in-game loading bar for a few minutes.
- It fetches only on screen. iOS suspends the game about 12 seconds after it leaves the screen, so it
  can't fetch ahead in the background.
- If the connection is too slow to play from, and the game is installed on this Mac, turn on **Copy
  Game Files from This Mac** for the device (see
  [Copying game files, or not](#copying-game-files-or-not)) and press Play: the companion copies the
  data before the game starts.

### No voice chat

In game, chat says "Can't connect to a voice chat server right now. Please try again. (VoiceError:
14)". Voice chat isn't supported on the device yet: on the Mac the game runs it in a separate helper
app it starts, and an iPad, iPhone, or Vision Pro won't let an app start another program. Text chat
is unaffected. Slashplayed doesn't ask for microphone access, since nothing would use it. Progress is
tracked in [issue #12](https://github.com/paulstraw/slashplayed/issues/12).

### The connection dropped while backgrounded

The game resumes after a suspension, but the server connection often drops while it's away (seen
after about 2 minutes off the headset). The client usually reconnects on its own. If it shows you
disconnected, exit to the login screen and log in again, or close Slashplayed and open it again.

## Export Diagnostics

**Help > Export Diagnostics…** (also a button on any failure) writes
`~/Library/Logs/Slashplayed/diagnostics/Slashplayed-Diagnostics-<time>.zip` with:

- the companion's logs and the window's steps,
- the device's `spconsole.log` files and any crash or jetsam reports (if the device is reachable; if
  not, wake or connect it and export again),
- a triage summary and versions (companion, macOS, device OS and model, flavor, game build, Xcode).

Any Battle.net value is blanked before it's written, the launch credential export is never
included, and neither is the game's own `Logs`/`Errors` folders (they can hold account details).
Device identifiers and personal details are blanked too: your name, signing certificates' names and
IDs, team IDs and names, Apple IDs, device and Mac names, and your user folder in paths.
`summary.txt` says how many of each.
Never paste Battle.net preference contents into an issue yourself.

See [Logs and diagnostics](architecture.md#logs-and-diagnostics) for where each log comes from.
