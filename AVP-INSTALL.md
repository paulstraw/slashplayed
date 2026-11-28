# Installing Slashplayed on Apple Vision Pro

Slashplayed runs Blizzard's official Mac client for World of Warcraft, unmodified, on Apple Vision Pro, with the missing macOS frameworks translated for visionOS. It plays in a window on the headset; a Mac does the setup once, and after that the headset plays on its own.

> **Read this first.** Slashplayed is unofficial and isn't affiliated with or endorsed by Blizzard Entertainment. Blizzard doesn't support playing this way, and the developer warns that your account could be actioned. It's early, and a game patch can break it until Slashplayed catches up.

## Requirements

- An Apple silicon Mac on macOS 15 or later, with Xcode installed (the companion app walks you through setting it up)
- Apple Vision Pro on visionOS 27 or later, with Developer Mode on
- An Apple ID signed in to Xcode (a free one works, and the app is re-signed about every 7 days; a paid Apple Developer Program membership signs it for a year)
- A Battle.net account with an active World of Warcraft subscription
- A hardware keyboard paired to the headset, for chat and authenticator codes (the game has no on-screen keyboard on Vision Pro)
- [LocalDevVPN](https://apps.apple.com/app/id6755608044), free on the App Store, installed on the headset and turned on when the game starts
- Free space on the headset: about 25 GB for Classic Era, 37 GB for Classic Era with TBC Anniversary, and 150 GB for Mists of Pandaria Classic or Retail

## Game files

You need your own Battle.net account with an active World of Warcraft subscription. This repository contains no Blizzard files.

- You don't copy any game files yourself. The game client and its data download from Blizzard under your own account, the first time you start a game.
- Supported games: Classic Era (including Hardcore and Season of Discovery), TBC Anniversary, Mists of Pandaria Classic and Retail.
- Each game's folder shows in the Files app under *On My Apple Vision Pro > Slashplayed*.

## Build

The release's companion app builds and signs Slashplayed for you, so most players can skip to the install.

1. Download **Slashplayed Companion** from the [latest release](https://github.com/paulstraw/slashplayed/releases/latest) and drag it to Applications.

To build the companion from source instead, install XcodeGen (`brew install xcodegen`), [rustup](https://rustup.rs) and Python 3, then from a checkout of this repository run the build steps in [CONTRIBUTING.md](CONTRIBUTING.md), ending with `apps/companion/build.sh`. That writes `build/companion/Slashplayed Companion.app`, which works like the released one.

## Install on Apple Vision Pro

1. On the headset, open *Settings > General > Remote Devices* and keep it open. On the Mac, pair the headset in Xcode under *Open Developer Tool > Device Hub*.
2. Open Slashplayed Companion. Its setup assistant checks Xcode, your Apple ID and team, the headset, LocalDevVPN and which games to put on it, then installs Slashplayed on the headset. The headset has to be awake and on the same Wi-Fi network as the Mac.
3. On the headset, turn on LocalDevVPN, open Slashplayed and pick a game. The first start takes a few minutes while the game downloads from Blizzard.
4. Sign in with your Battle.net email and password. They're kept in the headset's keychain, so you sign in once.

When Blizzard patches a game, the headset updates it itself, or the companion's next **Play** copies the new version over.

## Controls and known issues

- Typing in chat and entering authenticator codes needs a hardware keyboard paired to the headset.
- The client only starts while the headset is worn. If a launch from the companion waits, put the headset on and choose **Retry Launch**.
- Taking the headset off, closing the window or switching apps for more than about 30 seconds can disconnect the game. Use **Exit** or **Log Out** first to keep that session's settings.
- In-game voice chat isn't supported yet ([#12](https://github.com/paulstraw/slashplayed/issues/12)).
- [Troubleshooting](docs/troubleshooting.md) covers each error message. To report a problem, attach the zip from the companion's *Help > Export Diagnostics…* to a [new issue](https://github.com/paulstraw/slashplayed/issues/new/choose).
