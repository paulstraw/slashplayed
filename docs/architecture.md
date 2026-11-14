# How Slashplayed works

Slashplayed runs the unmodified Mac World of Warcraft clients on iPads with M1 or later and the A17 Pro
iPad mini (iPadOS), the iPhone 15 Pro and later (iOS), and Apple Vision Pro (visionOS). It's a
compatibility layer. The game's own arm64 code runs natively on the device, and a set of shim libraries
stands in for the macOS frameworks it expects (AppKit, CoreGraphics, Carbon, CoreAudio, Security, and
others), translating them to UIKit, RemoteIO, and friends. No game code is changed: the device loads
Blizzard's arm64 client as it is, unsigned, with a loader of Slashplayed's own, and no game files ship
with Slashplayed.

This page is the overview. [The internals](internals/README.md) have each part in detail, and
[research.md](research.md) has the experiments behind each technique.

## The parts

- **The Mac companion** (`apps/companion`, SwiftUI) builds the device app, signs it with the person's
  own Apple ID through Xcode, installs it, and puts each game's client and the start of its game data in
  the app's container. It can also copy the game data from a Battle.net install on the Mac, and relay a
  Battle.net sign-in from it, but neither is needed.
- **The Windows and Linux companion** (`apps/companion-rs`, Rust, experimental) does the same for an
  iPad or iPhone from a computer without Xcode: it signs in to Apple itself, signs the app, and installs
  it over USB. Vision Pro stays Mac-only.
- **The device app** (`apps/client`) holds no game. Its executable is a small launcher: it shows the
  start screen, signs in to Battle.net, keeps the app's signing renewed, updates and installs games, and
  loads the chosen game's client. Inside it are an on-device JIT helper (an app extension), the shims,
  and two small addons.

## From setup to play

1. The companion builds the app and signs it with explicit-App-ID development profiles on the person's
   team, one for the app and one for its helper, then installs it. The build is the same whatever
   games a device has, so it's rebuilt only when Slashplayed, the bundle ID, or the entitlements change,
   or the profiles near their end.
2. For each game the device has, the companion asks Blizzard's patch service for the current build and
   downloads just the arm64 slice of its Mac client from Blizzard's CDN, about 50 MB. Before copying it,
   it checks every import of the client against what the shims and the device's libraries export, so a
   patch that needs something new says so instead of failing on the device.
3. The client goes into the app's container unchanged, and so do the few files the game needs to start
   streaming its own data from Blizzard. A game patch is a ~50 MB copy, not a new app.
4. At launch, on the device, with or without the Mac: the JIT helper attaches to the app and prepares
   its executable memory, then detaches; the launcher maps the client, binds it to the shims, and calls
   its `main`. Battle.net sign-in happens in the game itself, from the email and password the launcher
   keeps in the device's keychain.

## Three hard problems

**Executable memory.** The client rewrites its own code at startup. On devices with Apple's Trusted
Execution Monitor (TXM), no certificate a third party can get allows an app to make memory writable and
then executable again. What does work: a page a debugger has written to may be executed after code is
written to it through a separate read-write alias of it, and stays so after the debugger leaves. So at
each launch a debugger prepares the client's code pages once, and the shim services the client's
rewrite through an alias mapping. The code itself is never writable. [Executable memory under
TXM](internals/loading.md#executable-memory-under-txm).

**A debugger with no Mac.** A process can't be its own debugger, so the app carries a second process, an
app extension, that reaches the device's own developer services the way a Mac does over the network:
through a loopback VPN (LocalDevVPN), with [idevice](https://github.com/jkcoxson/idevice). It mounts the
developer disk image when it isn't mounted, starts debugserver, attaches, services the one prepare stop,
and detaches, in about 1.5 s. It needs a RemotePairing record, which the companion makes over USB for an
iPad or iPhone, and which the headset makes itself, with a code, on its first launch. [The on-device JIT
helper](internals/loading.md#the-on-device-jit-helper).

**Loading a Mac program.** The device won't start another executable from an app, and dyld won't load
one. So the launcher loads the client itself with spguest, a loader of Slashplayed's own: it maps the
client's segments, applies its fixups, binds each macOS framework it names to the matching shim,
registers it with the Objective-C runtime and the unwinder, and runs it. Because nothing is signed on the
device, a new build of the client loads the same way, on every team, free ones included. [Loading the
client](internals/loading.md#loading-the-client-spguest).

## The shims

Most of what the client imports exists on the device as it is. A generator writes one shim per macOS
library from the client's import table: each import re-exports the device's own symbol, or is a stub
that logs its first call. Hand-written code fills in what the client really uses:

| Shim | What it does |
|---|---|
| libSystem | The executable-memory services, sandbox redirects (the game's folder, shared memory, `msync` on 16 KB pages), the Battle.net sign-in file, and the device's console log. |
| AppKit | The event loop, the window and screen, input (touch, pointer, keyboard, controllers), the clipboard, the loading screen, look highlights, and play-session stats. |
| CoreGraphics | One display, and the cursor's association for mouselook. |
| CoreAudio and AudioToolbox | A fake output device, the Mac's output unit mapped to RemoteIO, and no microphone. |
| Security | The client's legacy crypto calls, and bundled root certificates for its TLS. |
| CoreFoundation, Foundation, and IOKit | A made-up network interface, the small identity file login needs from the Mac, and the data setup dialog the device has no alert for. |
| Metal | The macOS-only device calls, and the shader-library retag: the device refuses the client's older macOS shader libraries over one header bit, which the shim clears in a copy as each loads. |

The client and UIKit both need the main thread, so the AppKit shim runs them as coroutines on it,
switching to UIKit whenever the client waits for events. [The shims](internals/shims.md) page has
them in detail, with what differs on the iPad and iPhone, and heat.

## Game data and patches

The game streams its data from Blizzard's CDN into the app's container as it plays, so the companion
sends only what the client needs to start. Optionally, it copies a Mac install's data instead, only the
archives the device's games use, and never mixed with what the device streamed.
[Game data on the device](internals/companion.md#game-data-on-the-device).

At each launch the device asks Blizzard whether a newer build is out. When one is, it downloads the new
client's arm64 slice, checks its imports against the shims, and offers **Update**, which puts it in place
in a few seconds; the game then streams the patch's data. The same steps install a game the device has
nothing of. The companion also copies a newer build at its next Play, and whichever is ahead keeps its
build. [Updating on the device](internals/device-app.md#updating-on-the-device).

## Signing

The app is development-signed on the person's own team. A free team's profile lasts 7 days; the Mac
companion signs again within two days of that. A device set up by the Windows and Linux companion, or
signed in to Apple in the launcher, renews its own profiles near their end instead, with an Apple token
kept in its keychain, and installs them through the JIT helper. [Keeping the app
signed](internals/device-app.md#keeping-the-app-signed).
