# Security policy

## Reporting a vulnerability

Please report security issues **privately**, through GitHub's private vulnerability reporting: open
the repository's [Security tab](https://github.com/paulstraw/slashplayed/security) and choose
**Report a vulnerability**. Don't open a public issue, pull request, or discussion for them.

Include the Slashplayed Companion version (Slashplayed Companion > About), your macOS version, the
device and its OS version, what an attacker can do, and steps to reproduce. A proof of concept helps
but isn't required. You'll get a reply in the advisory thread, and a fix ships as a normal release
through the companion's automatic updates.

**Never include your Battle.net email or password, a `login.txt`, `net.battle` preference values,
the contents of the companion's credentials export, a signing identity (`.p12`) or its password, or a
pairing record** in a report, even your own. If a report needs to show that a value leaks, use a fake
one you planted, a throwaway signing identity, or a device you've paired again since.

Only the latest release is supported. Please check that the issue still reproduces there.

## Scope

In scope:

- **The companion** (Slashplayed Companion.app), as built from this repository: what it runs on your
  Mac (`xcrun`, `devicectl`, `xcodebuild`, `codesign`, and the `/usr/bin` tools), what it writes to
  `~/Library/Application Support/Slashplayed` and `~/Library/Logs/Slashplayed`, what it fetches from
  Blizzard's patch service and CDN, and what it sends to your device.
- **Pairing records.** The RemotePairing record the companion makes for an iPad or iPhone over USB,
  and the one the headset makes with itself on first launch: each lets the holder reach that device's
  developer services. They must never be read into a log, left on the Mac after the copy, readable by
  other users, or included in Export Diagnostics.
- **The JIT helper** (`SPJitHelper.appex`, inside the device app): its RemotePairing tunnel through
  LocalDevVPN to the device's own developer services, the developer disk image it mounts, its
  debugger attach to Slashplayed, its requests from the launcher, and the pairing listener the
  launcher opens on 127.0.0.1. Anything that lets another app or a host on the network use the helper,
  the tunnel, or the record is in scope.
- **Signing identities.** The development identity the app is signed with (Xcode's, in your login
  keychain) and `slashplayed-companion`'s signing key (in the OS's credential store). Neither ever goes
  to a device or into a log. Slashplayed 1.4 and earlier sent an identity to devices for Update Games
  on This Device; the device app deletes it at its next start, and the companion deletes the Slashplayed
  certificate's key from the Mac. Anything that leaves one behind is in scope.
- **The Battle.net sign-in on the device**: the sign-in screen, the email and password in the device's
  keychain (this device only, never synced), the `login.txt` written just before the game loads and
  deleted when it closes (while it exists, it's in the app's `Documents/`, which Finder and the Files
  app show), and Forget My Sign-In.
- **Updating on the device**: the check for a newer build and its fetches from Blizzard's patch
  service and CDN (checked against the keys they're named by), the bind check, and the loader (spguest)
  that loads the new client, unsigned, into the app. Anything that lets someone on the network, or
  another app, get code of their choosing loaded is in scope.
- **The token relay**, the "Play with My Mac's Battle.net" fallback: how the companion catches the
  Battle.net launch, moves your launch credentials to the device and deletes them there. The
  credentials must never be read, logged, left on disk longer than needed, readable by other users, or
  included in Export Diagnostics.
- **The shims** and the device app's launcher: anything that lets content from outside (the network,
  a game server, another app) do more on the device than the game itself could, or that exposes the
  sign-in, the credentials, or the Mac's identity file on the device.
- The update path: the Sparkle feed at `https://slashplayed.strawdynamics.com/appcast.xml`, update
  signature checks, and the signed, notarized DMGs on GitHub Releases.
- The release pipeline in `.github/workflows/` and `scripts/release/`, if a change from outside could
  make it publish something it shouldn't.

Out of scope:

- World of Warcraft, Battle.net and Blizzard's servers. Report those to Blizzard.
- Vulnerabilities in Sparkle, idevice, zsign, OpenSSL, LocalDevVPN, Xcode, visionOS, iPadOS, iOS, or
  macOS themselves. Report those upstream. If one affects Slashplayed, please do let us know so we can
  ship an update.
- That the device app is development-signed with `get-task-allow`, that the helper attaches a
  debugger at every launch, and that Developer Mode is on: the game can't run without them, as
  [How Slashplayed works](docs/architecture.md) explains. How the helper and its tunnel could be misused is
  in scope, above.
- Attacks that need an attacker who already has admin rights on your Mac, or physical access to it or
  the device while unlocked.
- Account actions by Blizzard. Slashplayed is unofficial, and running the game this way is at your
  own risk.
- The project website, beyond the appcast above.
