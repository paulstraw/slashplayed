# Slashplayed

Play the Mac World of Warcraft clients (Classic Era, TBC Anniversary, MoP Classic, and
Retail) on M2-or-later iPads, iPhone 15 Pro and later, and Apple Vision Pro.

> **Unofficial.** Slashplayed is not affiliated with, endorsed by, or supported by Blizzard
> Entertainment. It includes **no Blizzard files**: the game comes from Blizzard's own servers, and
> you need your own Battle.net account and subscription. Running the game this way isn't something
> Blizzard supports. **Use it at your own risk: your account could be actioned.**
>
> **Early and experimental.** This is v0.1: expect rough edges, and expect a game patch to break it
> now and then until Slashplayed catches up.

## What it is

Slashplayed is a compatibility layer that runs the unmodified Mac game clients on iPadOS, iOS,
and visionOS. The client's own arm64 code runs natively on the device; a set of shim libraries
stands in for the macOS frameworks it expects (AppKit, CoreGraphics, CoreAudio, Security, …) and
translates them to UIKit, RemoteIO and friends.

It comes in two parts:

- **Slashplayed Companion**, a Mac app. From the Mac game client it downloads from Blizzard, it
  builds the **Slashplayed** app, signs it with your own Apple developer account, installs it on your
  iPad, iPhone, or Vision Pro, and starts the game each time you play. The game on the device fetches
  its data from Blizzard as you play. If the game is also installed on the Mac, you can turn on **Copy
  Game Files from This Mac** to have the companion copy the game data over first.
- **Slashplayed**, the app on the device, which runs the game.

The games are the ones Battle.net offers for the Mac: **Classic Era**, **TBC Anniversary**, **MoP
Classic**, and **Retail**. Classic Era's Hardcore and Season of Discovery are played by switching game
mode in Classic Era, as on the Mac. MoP Classic has been played on the
Vision Pro and an iPhone 16 Pro, and is **untested on the iPad**.

## Requirements

- An **Apple Silicon Mac** with **macOS 15** or later and **Xcode** (from the App Store, opened once).
  Setting Xcode up asks for an administrator's password once; after that, a standard macOS account
  works ([details](docs/troubleshooting.md#xcode)).
- An **Apple ID signed in to Xcode**. A free Apple ID (Personal Team) works, every game included,
  with limits: the app's signature lasts **7 days** (the companion warns two days ahead and signs it
  again when you rebuild or play), the first launch asks you to trust your Apple ID on the device,
  and a free team can have only a few apps on a device. A paid **Apple Developer Program** membership
  signs for a year with none of those limits. See
  [troubleshooting](docs/troubleshooting.md#free-apple-ids-personal-teams).
- An **iPad with an M2 chip or later** on **iPadOS 26**, an **iPhone 15 Pro or later** on **iOS 26**,
  or an **Apple Vision Pro** on **visionOS 27**, paired with the Mac in Xcode, with Developer Mode on.
  Of the iPhones, only the 16 Pro has been tested.
- A **hardware keyboard** for typing in the game: chat, and an authenticator's code when you sign in
  (the game shows no on-screen keyboard;
  [details](docs/troubleshooting.md#no-on-screen-keyboard)). Touch works without one otherwise.
- On an **iPhone**: **AssistiveTouch** on to use a mouse (Settings > Accessibility > Touch >
  AssistiveTouch; [details](docs/troubleshooting.md#no-cursor-with-a-mouse-on-an-iphone)).
- A **Battle.net account** with an active World of Warcraft subscription. You sign in on the device.
- **Optional:** World of Warcraft installed through Battle.net on the Mac. Nothing needs it, but it
  adds two things: copying the game's data to a device instead of the device fetching it (faster on a
  slow connection), and **Play with My Mac's Battle.net**, a fallback sign-in.
- Room on the device for the games you put there. These are their full sizes, what a copy from the
  Mac needs up front; a game that fetches its own data grows toward them as you play (Classic Era:
  about 5 GB after 15 minutes across three zones):

  | Games | Space |
  |---|---|
  | Classic Era | ~25 GB |
  | Classic Era + Anniversary | ~37 GB |
  | MoP Classic | ~150 GB |
  | Retail | ~150 GB |

  The games share one store of data on the Mac, and MoP Classic's files are spread over
  all of it, so a copy of it takes the whole store; only about 23 GB of that is its own.

  Retail on the iPad or iPhone needs ~150 GB free (a 512 GB or larger iPad or iPhone) and 8 GB of
  memory. It has been played on an M2 iPad (8 GB), where it runs hot and gets a memory warning at
  about 4.2 GB in use, though the system didn't stop it. It has also been played on an iPhone 16
  Pro, from an empty device with copying off.
- **[LocalDevVPN](https://apps.apple.com/app/id6755608044)** (free, from the App Store) on the
  device, turned on when the game starts: Slashplayed's helper reaches the device's own developer
  services through it to prepare the game's code. The Mac isn't needed for that. See
  [Known issues](#known-issues).

## Install

1. Download **Slashplayed-Companion-*.dmg** from the
   [latest release](https://github.com/paulstraw/slashplayed/releases/latest).
2. Open it and drag **Slashplayed Companion** to Applications.
3. Open it from Applications.

## First run

The companion walks you through setup one step at a time, with a fix for each problem it finds:
Xcode, your Apple Account and team, your devices, LocalDevVPN, and which games go on each device. An
optional step shows which games are installed on the Mac, if any (Battle.net and a game install aren't
needed). Then it installs Slashplayed on each device you pick: it builds the app, signs it, installs
it, and pairs an iPad or iPhone over USB. A last, optional step sets up
[Update Games on This Device](#playing). Then it says **Ready**, and you play from the device.

Pairing an iPad or iPhone over USB, macOS asks on the Mac to allow the accessory to connect (click
Allow), and the device asks you to Trust the Mac.

If a step won't pass, [troubleshooting](docs/troubleshooting.md#setup) covers each one.
**Help > Setup Assistant…** runs the checks again later.

## Playing

Once setup has installed Slashplayed on the device, open it there. The companion's **Play** does the
same from the Mac, and updates the app first: after a game patch, after you change a device's games,
and every 7 days on a free team.

1. Open Slashplayed on the device, or pick the game in the menu by **Play** in the companion and press
   **Play**. Battle.net doesn't need to be running.
2. From the Mac, keep the device awake (unlock the iPad or iPhone and connect its cable, or wear the
   headset) while the companion builds and installs (and copies, if that's on). The **first start of a game
   takes a few minutes** while it fetches its data from Blizzard: about 2.5 minutes to character
   select for Classic Era on an iPhone over Wi-Fi, with a loading screen for most of it. After that it
   fetches what each zone needs as you play, only while it's on screen. With copying on, the first
   copy takes a while instead (Classic Era is ~25 GB at ~33 MB/s over the USB 2 cable an iPhone or
   iPad comes with, and a USB 3 cable is several times faster; Retail on the headset is over an hour),
   and later ones copy only what a patch changed.
3. The game starts on the device. The first time, Slashplayed asks for your **Battle.net email and
   password** on the device. It keeps them in the device's keychain and signs the game in with them
   at every start, with no Battle.net needed. If your account has an authenticator, the game asks for
   its code (type it on the hardware keyboard). To sign in with another account, tap **Forget My
   Sign-In** in Settings on Slashplayed's start screen (the gear).

The Mac isn't needed to play: open Slashplayed on the device, and tap a game on its start screen. The
gear there opens Settings: the saved sign-in, the signing identity, each game's build, and Reset Game
Settings.

Each game's folder shows in the Files app (On My iPhone, On My iPad, or On My Apple Vision Pro >
Slashplayed), and a game's **Open in Files** in Settings opens it there. Edit its settings in
`WTF/Config.wtf`, or add an addon by putting its folder in `Interface/AddOns/` (make the folders if
they aren't there yet). Leave `Data/` and `.build.info` alone: deleting files there makes the game quit
with "installation is damaged" (see
[Troubleshooting](docs/troubleshooting.md#your-world-of-warcraft-installation-is-damaged)).

If the device's sign-in ever stops working and the game is installed on the Mac, **Play with My Mac's
Battle.net** in the menu by Play signs in through Battle.net on the Mac instead, for that launch (the
menu shows it only for a game installed there): pick the game in Battle.net and click its
**Play** button when the companion asks. The companion catches the launch and moves your Battle.net
launch credentials to the device (it never reads their values), then closes the Mac copy of the game.
The saved sign-in stays for the next Play.

**Update Games on This Device** (Settings > Updates on Devices) is off until you turn it on, per
device. It lets the device update a game itself when Blizzard patches it, with no Mac: the device makes
and signs the new game program there, so it needs a signing key of your team. When you open a game and
Blizzard has a newer build out, Slashplayed says so before the game starts, downloads the new build's
game program (about 50 MB; on cellular data or in Low Data Mode it asks first), and checks that this
version of Slashplayed can run it. With the setting on, the screen offers **Update**: a few seconds later
the new version starts, and the game fetches the patch's new data itself as you play. With it off, the
screen says to update on your Mac (press Play in the companion). The next Play from the Mac installs that
build or a later one, and the device then deletes the copy it made. Which key depends on the team:

- **A free team** sends a copy of the key the companion signs Slashplayed with (your team's Apple
  Development certificate and its private key). At the next Play or Update Client, macOS asks you once to
  allow the export.
- **A paid team** sends a certificate of Slashplayed's own, made only for this, so nothing else on your
  Mac signs with it and you can revoke it on its own. Set it up once in Settings > **Updates on
  Devices**: **Make Certificate Request** saves `Slashplayed.certSigningRequest` to Downloads (its key
  stays in a keychain of the companion's own, which Xcode never uses). On developer.apple.com, open
  Certificates, IDs & Profiles > Certificates, click +, choose Apple Development, upload the request, and
  download the certificate. Then **Choose Certificate…** (or drop it on the section). The companion checks
  that it's for its key and your team. If no profile on the device lists the new certificate yet, the
  companion installs your team's current profile first (no reinstall). **Stop Using the Slashplayed
  Certificate** deletes it from the Mac, and each device it was sent to deletes its copy at its next Play
  or Update Client. To end it everywhere at once, also revoke it on developer.apple.com.

Before it sends the key, and at every Play and Update Client, the companion checks with Apple that the
certificate hasn't expired or been revoked. If it has, nothing is sent, and the main window says what to
do: a new Apple Development certificate in Xcode (free team), or a new Slashplayed certificate (paid team).
When the device's key changes (Xcode replaced your certificate, or you switched to the Slashplayed
certificate), a game the device updated with the old key is signed again with the new one at its next
start, or, if no key the device has can sign it, the device plays the version the companion installed.

Turning the setting on says what's sent and asks first. On the device the key is kept in Slashplayed's
keychain only (that device only, never synced or backed up), and used only to sign game programs.
Turning the setting off deletes it from the device at Slashplayed's next start, as does **Forget Signing
Identity** in Settings on Slashplayed's start screen, at once. A game the device already updated keeps
playing; the next patch shows "Update on your Mac" again. Troubleshooting:
[Update Games on This Device](docs/troubleshooting.md#update-games-on-this-device).

Team, bundle ID prefix, device, games per device, copying game files, updating games on the device, the
game install, and update checks are in **Settings** (⌘,). The render scale is the device's own: the
start screen's gear, Settings > Display. Changing the team or the bundle ID prefix makes a new app
on each device, with no game files: they're fetched or copied again.

## Updates

The companion checks for updates itself (turn that off in Settings), or use **Slashplayed Companion >
Check for Updates…**. After a game patch, a new companion version may be needed; see below.

## Known issues

- **Heat.** On the headset, the device gets hot within minutes; long sessions on the iPad get hot too
  (there's no frame-rate cap yet, so a ProMotion iPad renders at 120 fps). An in-game frame-rate cap
  helps. [Details](docs/troubleshooting.md#heat).
- **Leaving the game for more than about 30 s can disconnect it.** That's closing its window, taking
  off the headset, or another app in front: the system then suspends Slashplayed, and the server
  connection can drop. Settings and keybind changes from that session can be lost. Use the game
  menu's **Exit** or **Log Out** before you leave to keep them.
  [Details](docs/troubleshooting.md#closing-the-window).
- **The window can vanish.** Seen once, after the headset was off for a few minutes: the game kept
  running but its window didn't come back. Press **Play** again: it stops the running client first.
  [Details](docs/troubleshooting.md#the-window-vanished).
- **LocalDevVPN has to be on at every start.** Each launch, Slashplayed's helper attaches to the game
  for a second or two to prepare its code (that's how the game runs at all; see
  [how it works](docs/architecture.md#the-on-device-jit-helper)), and it reaches the device's developer
  services through LocalDevVPN. If it's off, Slashplayed opens LocalDevVPN to turn it on, and the game
  starts once it's on.
- **No on-screen keyboard in the game.** Chat and an authenticator's code need a hardware keyboard.
  [Details](docs/troubleshooting.md#no-on-screen-keyboard).
- **A mouse on an iPhone needs AssistiveTouch** for its cursor.
  [Details](docs/troubleshooting.md#no-cursor-with-a-mouse-on-an-iphone).
- **No intro movie on a game's first launch.** On an empty device, the game's first session never
  plays its intro: it waits on a black screen with its download bar. So Slashplayed marks the intro as
  seen on each game's first launch, and the game goes straight to its login. Watch it from the game's
  **Cinematics** menu. [Details](docs/troubleshooting.md#no-intro-movie).
- **Game patches can break it.** If a patch adds something Slashplayed doesn't cover yet, the
  companion says the game version isn't supported yet instead of installing it, and the device says
  "This patch needs a Slashplayed update" instead of updating it. Check for a Slashplayed update; if
  there isn't one, the companion's message has a **Report It…** link that opens a pre-filled issue.

Something else wrong? See [troubleshooting](docs/troubleshooting.md), then
[report an issue](https://github.com/paulstraw/slashplayed/issues/new/choose) with the zip from
**Help > Export Diagnostics…** (it leaves out your launch credentials and blanks your devices'
identifiers and your personal details, such as your name, team ID, and device names).

## How it works

[docs/architecture.md](docs/architecture.md) is the map: the build pipeline (thin, rewrite load
commands, retype, check binds, sign, prepare, run), executable memory under TXM, the shims, the
event loop coroutine, input, audio, Metal, and the iPad and iPhone differences.
[docs/research.md](docs/research.md) covers the experiments behind it.

## Building from source

You need everything in [Requirements](#requirements), plus [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`) and [rustup](https://rustup.rs) (the companion links
[idevice](https://github.com/jkcoxson/idevice), and the device app's launcher links
[zsign](https://github.com/zhlynn/zsign) and [OpenSSL](https://www.openssl.org) for signing on the device,
each built from source at a pinned commit). The shim sources are committed, so a fresh clone builds:

```sh
scripts/build-idevice.sh       # once: idevice for the companion and the JIT helper, into work/idevice/
scripts/build-zsign.sh         # once: zsign and OpenSSL for the launcher and the tests, into work/zsign/
shims/build.sh xros            # shim dylibs + exports.json into build/xros/ (and ios)
apps/companion/build.sh        # build/companion/Slashplayed Companion.app, with shims and launcher bundled
apps/companion/test.sh         # the companion's unit tests
```

The companion built this way works like the released one. For the command-line scripts
(`apps/client/build.sh`, `run.sh`, `seed.sh`, the research harnesses), copy
`config/local.env.example` to `config/local.env` and fill in your team, signing identity and bundle
ID. `SP_PLATFORM=xros|ios` picks the device platform and `SP_FLAVOR=classic_era|anniversary|classic|retail`
the game (`classic` is MoP Classic).

After a game patch, maintainers regenerate the shims from the installed clients with
`scripts/recon/regen.sh <platform>` (needs Python 3 with PyYAML) and review the diff. Its header
explains the rest.

## Layout

| Path | What |
|---|---|
| `apps/companion` | The Mac companion (SwiftUI, XcodeGen project). |
| `apps/client` | The device app: launcher, on-device JIT helper, Info.plist and entitlements templates, signing stub, dev scripts. |
| `shims/` | The shim libraries: hand-written (`appkit/`, `audio/`, `system/`, …) and `generated/`. |
| `addon/SPHover` | In-game addon that lets visionOS draw look highlights over the game's UI. |
| `scripts/` | Shared config and platform/flavor scripts; `recon/` regenerates shims after a patch. |
| `research/` | The experiments behind the techniques: `jittest`, `loadertest`, `metaltest`, `dlopentest`. |
| `docs/` | Architecture, research, troubleshooting. |

## Contributing

Bug reports, patch reports and pull requests are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md).
Two rules matter most: **no Blizzard files** in the repo, ever, and no client internals beyond what
[architecture.md](docs/architecture.md) describes. Report security issues privately, as
[SECURITY.md](SECURITY.md) explains.

## License

[MIT](LICENSE). Copyright (c) 2026 Straw Dynamics.

Slashplayed includes [Sparkle](https://sparkle-project.org) (MIT, the companion's updates),
[idevice](https://github.com/jkcoxson/idevice) (MIT) with the Rust crates it's built with (each under
its own license, mostly MIT or Apache 2.0) and the Rust standard library, and, in the device app,
[zsign](https://github.com/zhlynn/zsign) (MIT) and [OpenSSL](https://www.openssl.org) (Apache License
2.0). Their license texts ship in the companion (About Slashplayed Companion > Acknowledgements) and in
the device app's `licenses/` folder.

World of Warcraft and Battle.net are trademarks of Blizzard Entertainment, Inc. Apple Vision Pro,
iPad, iPhone, visionOS, iPadOS, iOS, macOS, and Xcode are trademarks of Apple Inc.
