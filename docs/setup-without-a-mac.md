# Setting up without a Mac

**slashplayed-companion**, the Slashplayed Companion for Windows and Linux, sets up Slashplayed on an
**iPad or iPhone** from a PC, with no Mac. For now it's a command-line tool: plug in the device, run it,
and answer its questions. It's new.
Until a release includes it, it comes as test builds for volunteers (see [Testing it](#testing-it)).

**Apple Vision Pro still needs a Mac** with the [Slashplayed Companion](../README.md#get-started).

## What it does

It does what the Mac companion does with Xcode:
- Signs in to your Apple ID.
- Makes the app's signing profiles.
- Signs Slashplayed and installs it over USB.
- Gets the app ready to install games: its pairing record for starting games without a computer, and
  the developer disk image.

You install the games on the device itself: open Slashplayed and tap one.

## Before you start

- **Your device:** an iPad with M1 or later or the A17 Pro iPad mini, or an iPhone 15 Pro or later, on iPadOS 26 or iOS 26 or
  later, with a USB cable.
- **Apple's device driver.**
  - **Windows:** install **Apple Devices** from the Microsoft Store (or iTunes from apple.com).
  - **Linux:** install **usbmuxd** (most distributions package it) and make sure it's running.
- **An Apple ID.**
  - **A free one works.** The app then has to be signed again every 7 days, by running the tool again.
    A paid Apple Developer Program membership signs it for a year.
  - **Use a secondary Apple ID for a free team.** The tool signs in the way sideloading tools do, which
    Apple doesn't officially support.
- **[LocalDevVPN](https://apps.apple.com/app/id6755608044)** from the App Store, on when a game starts,
  and a **Battle.net account** with an active World of Warcraft subscription, as for the Mac way (see the
  [README's requirements](../README.md#requirements)).

## Running it

1. Unzip the download for your system.
2. Plug in the device, unlock it, and run the tool from a terminal:
   - **Windows:** in PowerShell, `.\slashplayed-companion.exe`
   - **Linux:** `./slashplayed-companion`
3. If the device asks whether to trust this computer, tap **Trust**.
4. If Developer Mode is off, the tool says so and shows the switch in Settings > Privacy & Security >
   Developer Mode. Turn it on, let the device restart, tap **Turn On**, then run the tool again.
5. Type your Apple ID and its password. The password isn't shown as you type, and it's never stored:
   the tool uses it once and forgets it. Then type the code Apple sends. Type `sms 1` at the code prompt
   to get it by text instead.
6. If the Apple ID has several teams, pick one.
7. The tool installs Slashplayed. On a free Apple ID, the first time only, open **Settings > General > VPN
   & Device Management** on the device and trust your Apple ID.
8. Open Slashplayed and tap a game to install it.

To sign the app again, run the tool again, the same way. Your games and settings stay. On a free Apple ID,
do this within 7 days of the last run, or the app won't open until you do.

### Options

| Option | What it does |
|---|---|
| `--apple-id <email>` | Don't ask for the Apple ID. |
| `--team <TEAMID>` | Pick the team without asking. |
| `--udid <UDID>` | Pick the device when several are plugged in (`slashplayed-companion devices` lists them). |
| `--bundle-id <id>` | The app's bundle ID. The default is `<team ID>.slashplayed`, the same as the Mac companion's, so the two sign the same app. |
| `--anisette <url>` | The anisette server Apple's sign-in needs. The default is `https://mac-ani.jkcoxson.com`. You can run your own. |
| `--pair-again` | Make a new pairing record, if starting games keeps failing at the pairing step. |

`slashplayed-companion forget --apple-id <email>` deletes the signing key the tool keeps for that Apple ID
(see below).

## What it keeps

- **Your Apple ID password:** never kept. You type it each run.
- **The signing key:** kept in your system's own credential store (Windows Credential Manager, the
  Secret Service on Linux, the Keychain on a Mac), so each run reuses the same certificate instead of
  making a new one. Where there's no credential store, each run makes a new certificate. Once the team
  has all the certificates Apple allows, such a run stops: free a slot, or run it with `--revoke-oldest`,
  which revokes the oldest certificate a Slashplayed tool made. If you use Slashplayed from another
  computer too, that one's device then needs its own run before Slashplayed opens again.
- **Certificates:** a free Apple ID can have only a few. When there's no room, the tool replaces one
  Slashplayed made. It never removes a certificate made by Xcode or another app; if those fill every
  slot, it says so and stops.
- **On the device:** the app, its pairing record, and the developer disk image, in Slashplayed's own
  data. No signing key goes to the device: it installs and updates games without one.

## Testing it

Test builds are posted as **prereleases** on the
[releases page](https://github.com/paulstraw/slashplayed/releases): `slashplayed-companion-windows-x86_64.zip`,
`slashplayed-companion-linux-x86_64.tar.gz`, and `slashplayed-companion-linux-aarch64.tar.gz`.

- **Windows:** the `.exe` isn't signed, so SmartScreen warns about it. Choose **More info > Run anyway**.
- **Checking a download:** compare it with `SHA256SUMS`. To check it was built by this repository's
  GitHub Actions, run `gh attestation verify <file> -R paulstraw/slashplayed`.
- **Reporting:** [open an issue](https://github.com/paulstraw/slashplayed/issues/new/choose) with:
  - Your system (Windows or Linux, and which).
  - Your device and its iOS or iPadOS version.
  - A free or paid Apple ID.
  - The tool's output. It never prints your password; check the output for anything else you'd rather
    not share before posting it.

## Troubleshooting

- **"couldn't reach usbmuxd":** Apple's driver isn't installed or running. Install Apple Devices on
  Windows, or start usbmuxd on Linux (`sudo systemctl start usbmuxd`), then plug the device in again.
- **"no iPhone or iPad on USB":** use a data cable, unlock the device, and plug it in directly rather
  than through a hub.
- **The sign-in fails with -80045 or "This action cannot be completed at this time":** the anisette
  server was refused. Try again later, or another server with `--anisette`.
- **"the team can make N more App ID(s)":** a free Apple ID can make 10 App IDs a week, and Slashplayed
  needs 2 the first time. Wait a few days.
- **The app won't open:** on a free Apple ID, it's been more than 7 days. Run the tool again.

More is in [troubleshooting](troubleshooting.md).
