# Research

The experiments behind [architecture.md](architecture.md). Each harness in `research/` is a small
app built from our own code only; none of them contains or reads game files, except `loadertest`,
which reads the list of import names from the user's own installed client to build its toy. Every
device harness runs on visionOS (`SP_PLATFORM=xros`, the default) and iOS/iPadOS (`SP_PLATFORM=ios`);
`isideload` is a Mac command-line tool, tested with an iPhone.

| Harness | Question | Answer |
|---|---|---|
| [`research/jittest`](../research/jittest/README.md) | Can a development-signed app execute code it wrote, at the address the client needs, under TXM? | Yes, with a debugger preparing the pages once per launch and every write going through an RW alias. |
| [`research/loadertest`](../research/loadertest/README.md) | Will the device's dyld load a macOS AppKit program whose load commands point at the shims, and bind every import the client has? | Yes: every import binds, AppKit subclasses work, no debugger needed. |
| [`research/metaltest`](../research/metaltest/README.md) | Can macOS-built metallibs load and run on the device? | Yes, after clearing one header bit, for container versions v2.2–v2.5; v2.6+ load as they are. |
| [`research/dlopentest`](../research/dlopentest/README.md) | Can the app load an image it didn't install with, from its data container, and can the device sign one itself? | Yes, when a profile installed on the device lists the signing certificate; ad hoc and unsigned are refused. The device signs with zsign, patched. |
| [`research/isideload`](../research/isideload/README.md) | Can the isideload crate replace Xcode for provisioning (Apple ID sign-in, teams, device, App IDs for the app and `.helper`, capabilities, certificate, profiles), so a Windows or Linux host can do it? | Yes, on iPhone, with free and paid teams: a zsign-signed app installs, and the JIT helper attaches (a free team's on-device-signed image needs the app's bundle ID as its signing identifier, which the launcher now uses). It needs Mac-ADI anisette (Android-ADI servers now get `-80045`), its lower-level API (the high-level one can revoke), and a decision on the LGPL signer it links. |

## Executable memory (jittest)

The starting facts, from XNU's source and public reports:

- `mmap(MAP_JIT)` is gated by the code-signing monitor (`vm_map_csm_allow_jit`), and on TXM devices
  (M2 or later) that policy lives in TXM. No entitlement a third party can get grants it on visionOS;
  `com.apple.security.cs.allow-jit` is macOS-only, and BrowserEngineKit's JIT is iOS-only and
  EU-only. Development signing does give `get-task-allow`, so a debugger can attach.
- Since TXM, pages an app writes code into won't execute until a debugger has written to them
  ([iCube #11](https://github.com/Provenance-Emu/iCube/issues/11),
  [Play-CodeGen #34](https://github.com/jpd002/Play--CodeGen/pull/34)). Emulators on iOS use the
  StikDebug protocol: the app executes `brk #0xf00d` with a command in `x16`, and the debugger writes
  one byte per 16 KB page of the requested region
  ([StikDebug](https://github.com/StikDebug/StikDebug), [visionOS fork](https://github.com/rebelancap/StikDebug-visionos)).
  Every working project then writes code through a `vm_remap` RW alias of the prepared RX region.
- Signed executable mappings are made permanent on code-signing-monitor systems
  (`vm_map_executable_immutable`), so `munmap` leaves an inaccessible hole and a new mapping can't
  land there. Debugger writes are the exception: `VM_PROT_COPY` may replace permanent executable
  entries when Developer Mode is on. That's how breakpoints land in signed code.

No precedent ran code at the address of the app's own signed `__TEXT`, which is what the client
needs (its code is position-dependent and rewrites itself in place). The experiments, on Vision Pro
(visionOS 27.0) and iPad Pro M2 (iPadOS 26.6), with Xcode's lldb servicing the protocol
(`research/jittest/jit.py`):

| Test | What | Result |
|---|---|---|
| E4c | No debugger: own `__TEXT` `mprotect` RW/RWX, `MAP_JIT`, `munmap` + remap | All refused; `munmap` leaves a `0/0` hole |
| E1 | Debugger allocates an RX region, write via an RW alias, detach, execute | Pass |
| E2 | App maps RX at a fixed address, debugger prepares it, alias write, execute | Pass |
| E3 | Prepared region, then `mprotect` RW → write → RX | Fail: RW drops max protection to `rw-` for good |
| E4a | Own `__TEXT`: the app's own `vm_protect(RW \| VM_PROT_COPY)` | Writable, but never executable again |
| E4b | Own `__TEXT`: debugger prepare, then `mprotect` RW → RX | Fail, as E3 |
| E4d | Own `__TEXT`: debugger prepare, alias write of 1 MB, detach, execute in place | **Pass** |
| E5 | E4d at the client's size (44 MB, 2,820 pages), timing the prepare modes | Pass in every mode |
| E6, E6b | Prepare, detach, *then* make the alias and write | Pass: the debugger needn't stay |
| E7 | The real libSystem shim servicing the client's sequence through `dlsym`, 44 MB | Pass: contents match, first and last pages execute after detach |

Rules learned: a page made writable in place can never execute again; a debugger-prepared page stays
`r-x` with max `rwx`, and code written through a separate alias runs at any address, after detach
too. The shim design in [architecture.md](architecture.md#executable-memory-under-txm) follows
directly.

Prepare cost is the debugger link. Over the headset's Wi-Fi a round trip is ~11–12 ms and bulk
throughput ~3 MB/s:

| Mode | How | 2,820 pages | Contents |
|---|---|---|---|
| `page` | read and write back the first byte of each page | ~62 s | kept |
| `pagew` | one 1-byte write per page, bytes supplied by the app | 33–36 s | kept |
| `bulk` | read everything, write it all back | 24–35 s | kept |
| `bulkz` | write zeros over everything | 15.6–17.6 s | zeroed (the shim restores them through the alias) |
| `bulkx` | as `bulkz`, but filler bytes in raw binary `X` packets (half the packets of lldb's hex `M`) | ~11 s | overwritten (restored likewise) |

`bulkx` is what the companion uses. One trap: the device writes the `X` packet's `,len:` header as
data too, so a full-size payload overran the region by a few bytes; payloads are cut by the header
length, and `jit.py` checks the bytes just past the region are unchanged. On the iPad over USB, E7's
prepare took 8.3 s (2.9 ms per page); on an iPhone 16 Pro (A18 Pro, iOS 27.0.1) over USB, 4.0 s
(1.4 ms per page), with E4d and E7 passing as on the M2 devices.

Before the prepare, lldb itself cost far more: launched stopped, it took 70–100 s to reach the
prepare stop, stopping on every image load, reading dyld's symbols from memory a string at a time,
and answering debugserver's request for `dispatch_queue_offsets` about 920 times. Launching the app
running and attaching late (the shim waits for `P_TRACED`), plus exporting `dispatch_queue_offsets`
from the shim, brought launch to first frame from ~130 s to ~48 s on the headset and ~16 s to detach
on the iPad. The rest is lldb reading the headers of ~940 loaded modules, which is latency-bound.

### On the device, with no Mac: StikDebug

[StikDebug](https://github.com/StikDebug/StikDebug) runs the debugger on the device itself: a
loopback VPN (LocalDevVPN) routes it to the device's own debug services, authenticated with a
RemotePairing file made once from a Mac over USB (`idevice-tools remotepairing_lockdown pair`, from
[idevice](https://github.com/jkcoxson/idevice); the file is a credential that can do anything the
Mac's pairing can, revoked with Settings > Developer > Clear Trusted Computers). Its `universal.js`
script speaks our protocol unchanged: `x16 = 1` prepares `x0..x0+x1` and returns the address in x0,
`x16 = 0` detaches, and other signals are passed through. It writes one byte (`0x69`) per 16 KB page,
128 `M` packets per batch before reading the replies, so the contents change (the shim restores them
through the alias, as with `bulkz`) and the x2 extension is ignored.

It launches the app itself, suspended, then attaches (`vAttach`). The app gets no arguments, so
jittest reads its experiment from `Documents/spjit-which`. A launch without a script assigned ran the
app untraced, so jittest waits for `P_TRACED` as the shim does; with `universal.js` assigned, the
attach had landed before `main`. The app can also name the script and target itself, with
`stikjit://enable-jit?bundle-id=…&script-name=…` or `pid=…`.

On the iPhone 16 Pro (iOS 27.0.1), E4d and E7 pass under StikDebug, and E7's whole debugger stop (the
shim's `mprotect` through detach, 2,887 pages) took **0.38 s**, against 41.7 s under lldb from the Mac
over USB (3.98 s of it the page writes, the rest lldb's launch-stopped attach). On the device the
prepare costs nothing worth optimizing.

The client then launched from StikDebug with no Mac: traced when the shim loaded, all of the client's
`__TEXT` (2,820 pages) prepared and detached within a second, the first stats line 30 s after launch
(~45 s to first frame with the Mac and lldb), and the launch token already on the device logged it in to
character select and the world. With no arguments from StikDebug, the launcher replays the last ones
saved for the flavor (`Library/splaunch-args-<flavor>`). Login itself still needed the Mac's token
then (see **Login without Battle.net**, below).

### On the device, with no StikDebug: a helper extension

The goal is to do StikDebug's part from inside our own app, so a launch needs neither the Mac nor
another app. A process can't service its own debugger stops (StikJIT's integration notes say the same:
a process that attaches a debugger to itself deadlocks), so the helper is a second process: an
app extension bundled in the app. It was first an ExtensionKit extension on an extension point the app
declares (`AppExtensionProcess`, `NSXPCConnection`), the public way on iOS 26; visionOS doesn't install
that, so it's now a classic extension (below).

visionOS's installd accepts an extension only on one of Apple's extension points (the app-defined point
is iOS 26 and later only), so the helper claims Apple's AR viewer point (`com.apple.ar.viewer`, the
point LiveContainer's LiveProcess and other JIT helpers on iOS use), and the app starts it by bundle ID
with NSExtension's private request calls. The same helper serves the iPhone and the Vision Pro.

jittest's `h1` starts the bundled helper and pings it. On the iPhone 16 Pro (iOS 27.0.1) and the Vision
Pro (visionOS 27.0.1) it passes at the first launch with no prompt or approval: the helper is up as its
own process (with its own data container) 0.06–0.22 s after the request. A host without UIKit is fine.
The helper's sandbox reaches the loopback VPN (a TCP connect to 10.7.0.1:49152, the RemotePairing tunnel
endpoint, takes 1–2 ms with LocalDevVPN on) and Apple's signing server (`gs.apple.com:80`, which
personalizing the developer disk image needs). Its layout and the host's calls are in
[research/jittest/README.md](../research/jittest/README.md#the-helper-extension).

With idevice linked in, the helper does the whole job on the device. With LocalDevVPN on and the
RemotePairing record StikDebug uses, on both devices: the tunnel comes up through 10.7.0.1:49152 in
0.1–0.2 s, debugserver attaches about 1.1 s after the app asks, and the shim's prepare of 2,890 pages
(`h4`, the real shim) takes 0.10–0.15 s with no failed writes; launch to detach is 1.7 s, against 8.3 s
to ~57 s for lldb driven from the Mac. The pages execute after detach, as with any debugger. The
developer disk image (a cryptex on iOS 26.4 and later) outlives a reboot on iOS 27.0.1: the iPhone,
rebooted with no Mac reachable, still had it, so a launch after a reboot needs no Mac. The RemotePairing record can come from the device itself on visionOS: with Settings > General > Remote
Devices open, the app pairs through the loopback VPN with the six-digit code the headset shows, as Xcode
does over Wi-Fi, and the new record opens the tunnel. iOS refuses this (its RemotePairing service resets
a host it doesn't trust before pair-setup), so there the companion makes the record once, over USB,
through lockdown (idevice, linked into the companion), with no prompt; on the iPhone that record runs the
whole helper flow with no StikDebug. The helper costs a free Personal Team nothing on the device: a
device holds at most three apps signed by free teams, counting every free team together, and on the
iPhone (iOS 27.0.1) jittest re-signed by a free team, helper inside, took one of the three. The refusal
of a fourth app listed the three apps and not the helper. It does take one of the team's 10 App IDs a
week, as an extension has its own. What's left: mounting the disk image from the helper on a device that
has never had it, the iPad, and the client.

## Loading a macOS program (loadertest)

A toy macOS AppKit program, built against the macOS SDK with the client's deployment target (so its
fixups have the same format), imports every symbol the client imports from the same library and
subclasses the same five AppKit classes. Its load commands are rewritten with the shims' rewrite map,
its platform set with `vtool`, and the shims bundled. On the device:

- dyld binds all 1,062 references (none NULL, 2 weak).
- `dlsym` hides the JIT toggle and hands out the shim's `mprotect`/`memcpy`.
- Subclasses of stub `NSApplication`/`NSView`/`NSWindow`/`NSResponder`/`NSOpenGLContext` realize and
  dispatch, Metal finds the M2 GPU, and `NSColor` comes back as UIKit's.

Lessons that carried over to the real client:

- Today's macOS SDK no longer exports `exp2`/`log2`/`modff` from CoreServices, though the client
  binds them there (the toy links against a patched `.tbd`; the shim re-exports them).
- **The launch watchdog.** With no `UIApplicationMain`, the toy was killed with signal 9 about 21 s
  after launch, with no crash report. The client needs a real UIKit scene within ~20 s, which led to
  the event loop coroutine. The toy pumped events through it at ~59 fps for 60 s.
- On iPadOS the same toy passes (1,062/1,062, UIKit scene, Metal).

The one-app-every-game launcher came from the same kind of toy test on the headset:
`posix_spawn` of a bundled executable fails (`EPERM`), `execve` fails (`EACCES`), `dlopen` of an
`MH_EXECUTE` is refused, and launching by executable path through devicectl is refused by
LaunchServices. `dlopen` of the same file retyped `MH_BUNDLE`, then a call to its `LC_MAIN` entry,
works.

## Metal shader libraries (metaltest)

The client's shader libraries failed to load with `MTLLibraryErrorDomain Code=1 "This library format
is not supported on this platform"`. `research/metaltest` compiles **our own** small shader for the
device and for macOS at deployment targets 10.11 through 14 (which pick metallib container versions
v2.2 through v2.7), makes copies with the header's macOS flag cleared (`mtlb.py retag`), and on the
device loads each one, runs a compute kernel over 256 threads and draws a textured triangle, checking
every output value and pixel.

| macOS deployment target | Container | Platform field | As built | macOS flag cleared |
|---|---|---|---|---|
| 10.11, 10.13 | v2.2 | none | Code=1 | compute and render OK |
| 10.14 | v2.3 | none | Code=1 | OK |
| 10.15 | v2.4 | none | Code=1 | OK |
| 11.0 | v2.5 | none | Code=1 | OK |
| 12.0 | v2.6 | macOS 12 | OK | OK |
| 13.0, 14.0 | v2.7 | macOS 13/14 | OK | OK |
| device control | v2.7/v2.9 | visionOS/iOS | OK | — |

The container header, as observed: `MTLB` magic; at offset 4 a u16 target whose bit 15 means macOS;
a u16 major and minor version; a library type byte; from v2.6 a platform byte (`0x80 | id`) and
platform version; then the file size and the offsets of the function list, metadata and bitcode.
The AIR target triple inside the bitcode names macOS in every case and is accepted. The results are
identical on the iPad. The client's libraries turned out to be v2.2 with the macOS flag, and with the
Metal shim's one-bit retag they render correctly.

## Platform findings from the client itself

Not every finding came from a harness. These came from running the client on the devices, and each
is described in [architecture.md](architecture.md):

- The sandbox redirects (install root, shared memory, root certificates, `SIGPIPE`).
- The RemoteIO sample-rate bug that garbled the headset's audio, and the session restart after an
  interruption.
- Scene tracking and the display size the client caps its drawable at.
- Pointer lock (honoured on iPadOS, ignored for a window on visionOS) and `GCMouse` for button chords
  and raw mouselook deltas.
- Look highlights through the system's out-of-process gaze glow.
- Heat: the 1x render scale frees the GPU but doesn't delay the headset reaching `serious`.

Also checked on the Mac before any of it ran on a device: `shims/system/test-mac.sh` runs the
user's own thinned client through a macOS build of the libSystem shim, with lldb and `jit.py`
servicing the prepare stop, and confirms its startup code rewrite goes through the alias the same way
(it exits offline, as the unmodified client does with no game data).

## iPhone, update checks and login without Battle.net (2026-10-21)

**iPhone.** An iPhone 16 Pro (A18 Pro, 8 GB, iOS 27.0.1) behaves like the M2 iPad for everything in
[architecture.md](architecture.md#ipad): the same SDK, shims, rewrite map and debugger prepare. The
app only needs device family 1 (iPhone) next to 2. Classic Era, run with the script tools over USB:

| | 1x render scale | 2x render scale |
|---|---|---|
| Render size | 874x402 (the screen's points; ~1/3 of native per axis, looks soft) | 1748x804 (much sharper) |
| Prepare (2,820 pages) | 4.6 s (1.6 ms per page) | 3.8 s (1.4 ms per page) |
| Footprint, login screen | ~700 MB | ~740 MB |
| Footprint, in the world | ~1.55 GB | ~1.85 GB (peak 2.7 GB at character creation) |
| Memory left, minimum | 4.6 GB | 3.5 GB |
| GPU per frame, in the world | ~10.7 ms | ~34 ms |
| Frame rate | 60 fps | 57–60 fps |
| Thermal | nominal (1 min) | `fair` after ~2.5 min in the world, still `fair` 4.4 min later |

At 1x the UI's text is unreadable while the 3D world looks fine, so the iPhone now defaults to 2x
with the game's own render scale at 50%: a sharp UI, and in the world 60 fps at ~9.9 ms GPU per frame,
thermal nominal (first 90 s), about 1x's cost. A longer run, about 10 minutes in Stormwind (not
busy, on battery): 60 fps throughout (worst frame ~22 ms, none over 50 ms), 8.7–13.1 ms GPU per frame
(average 10.7), footprint peak 1.72 GB, thermal nominal the whole time and the back no warmer than
the room. The client paces itself at 60 fps, so the iPhone needs no frame cap.

Memory isn't a limit for Classic Era. Touch (tap to click, drag), a Bluetooth keyboard (including
chat) and backgrounding to Settings and back all work. Found along the way:

- **No system pointer.** iOS on an iPhone delivers no pointer or hover events for a Bluetooth mouse
  (iPadOS does; on the iPhone only AssistiveTouch draws a pointer), so the shim's cursor never
  appears, though `GCMouse` sees the mouse. A cursor has to be driven from `GCMouse`'s movement.
- **Full Keyboard Access** takes plain Space for "activate" before the app sees it (on the Vision
  Pro too); Space with Shift held gets through. See [troubleshooting.md](troubleshooting.md).
- **An AssistiveTouch left click is a finger-type touch.** It moves with the mouse, and `GCMouse`
  reports that movement too, so while the cursor is frozen for camera-look its movement has to be
  left to `GCMouse`, or the camera turns twice as fast; a real finger's must not be, or a finger
  drag stops turning at the freeze. What tells them apart is `majorRadiusTolerance`: the click is
  synthesized and reports a fixed radius with no tolerance (43.7±0 on the iPhone 16 Pro), while a
  finger's always has some (12.1±6.1, 24.3±6.1). Force and `tapCount` don't help (both 0 and 1 for
  each). The mouse's other buttons come as a pointer-type touch (`UITouchTypeIndirectPointer`).
- **Orientation.** With rotation lock on, the app comes up portrait and cropped; it should be
  landscape only.
- A new device needs `Library/spidentity`, the small identity file login needs from the Mac, before
  its first login, or the login fails. The companion sends it; `apps/client/seed.sh` now does too. (That's
  for the launch credentials the companion moves from the Mac. A device that signs in itself, through the
  launcher's sign-in, reaches character select without it: the host tool's install, 2026-11-01.)
- The Dynamic Island covers none of the default UI in landscape.

**Update checks.** Blizzard's public patch service answers which build is live, without Battle.net:
`https://us.version.battle.net/v2/products/<product>/versions` (and the same table over plain HTTP at
`http://us.patch.battle.net:1119/<product>/versions`), in 60–95 ms. Its region row's `BuildConfig`
equals the `Build Key` that `.build.info` holds for the installed build (checked for Classic Era,
Anniversary, and Retail), so the companion or the device's launcher can tell when a new build is out.
Rebuilding the client image for it needed the Mac then; the device now does it itself
([Updating on the device](architecture.md#updating-on-the-device)).

**Login without Battle.net.** The unmodified client logs in by itself, with no Battle.net launch
and no launch credentials, when its game folder holds a `login.txt` with the account's email and
password (the approach of an Android launcher for another WoW client). On 2026-10-22 it worked on the
Mac for Classic Era and Retail, each with an account without an authenticator and one with: the
client shows its own authenticator prompt, and the code typed there completes the login. On the
iPhone, through the shims, it reached character select (Classic Era). The client's console shows
the file feeds the same logon form exchange as typing into the login screen, with the authenticator
step after it. A wrong password ends at the form's result with BLZ51914500 ("Okay" goes back to the
empty login screen; the client doesn't retry).

**The typed login form.** Typing the same test account's email and password into the login screen,
a minute after the file signed it in, fails with that same BLZ51914500, at the same step of the same
sequence. An earlier experiment (2026-10-12) found the account service returns that error when the
password proof the client sends doesn't verify, and that an independent client signs the same account
in. With the file, the same client's proof verifies, so what differs is the email or password the
typed route hands it. Not pursued: the file covers sign-in, and the cause is inside the
client.

**What the launcher does with it.** The client never deletes the file, and while it exists, even
empty, it takes that path instead of a Battle.net launcher token it was given (it still decrypts the
token, then connects without it; an emptied one ends at the account form and a captcha that fails
even when answered right, BLZ51914400). On the iPhone the client opens the file once, within seconds
of loading, closes it, and never opens it again: the libSystem shim deleting it on that close leaves
the login (and the authenticator step) working. So the launcher writes it just before the client
loads, from a sign-in it keeps in the keychain, and the shim deletes it on the close (see
`docs/architecture.md`). The Android launcher instead deletes it once `Logs/Hotfix.log` passes
50 kB, or after 180 s.

**It needs `-launcherlogin`.** On the iPhone (2026-10-22, Classic Era, saved sign-in, no relayed
token), a launch with no arguments at all read the file within seconds and stopped at the login
screen, with no error: the client never asked the stand-in agent, decrypted no stored launcher data,
and never connected to the account server. The same launch with `-launcherlogin` as its only argument
took the working route (agent queries, the stored data decrypted, the file read, the account server)
and reached character select. So the file is read on the launcher-login route, which that option turns
on, and a fresh token isn't needed: the companion's Play passes the flavor's Battle.net arguments
without one (verified on the headset), and the launcher uses them for a launch with none saved.

## Streaming game data on the device (2026-10-23)

The client has its own streamer: when its local store lacks what `.build.info`'s build needs, it fetches
the CDN archive indexes and then the content itself, from Blizzard's CDN, and writes them into its store.
On the Mac this was known; on the iPhone 16 Pro (iOS 27.0.1, Wi-Fi), Classic Era, it works through the
shims: its connections and the sandbox redirects need nothing more. The tests:

| Store at launch | What happened |
|---|---|
| Nothing but `.build.info` and `Data/config/` (7 MB) | One launch, no exits. Every CDN index (1,504 files, 322 MB) within 30 s; the login screen at 120 s; character select at 150 s; 2.2 MB/s steady after that, in front. |
| What that left (2.9 GB), then about 15 minutes of play across three zones and a zeppelin | In the world about a minute after launch, 60 fps throughout (one 103 ms frame at a zone-in), no missing textures noticed, footprint peak 1.7 GB, thermal nominal. The store grew 2.2 GB in 24 minutes (about 1.5 MB/s), with the client's download indicator up most of the time. |
| The previous build's image on today's full store | The client fetched the 102 indexes it lacked and 1.2 GB in about 5 s, then exited, before the fix below. Not repeated since. |

- **The setup dialog.** With data to fetch first, the client puts up a progress dialog through
  `CFUserNotification` and waits for it. iOS has no alert server for apps, so the real call answers
  at once with Cancel and the client quits; its icon comes from the bundle's `wow.icns`. The
  CoreFoundation shim keeps the notification itself and never answers it, and the app carries an
  empty `wow.icns` (see [architecture.md](architecture.md)). The screen is black for the 13–15 s the
  dialog would be up, then the window stays black for about 90 s while startup content streams.
- **Foreground only.** iOS suspends the app about 12 s after it leaves the screen, and the store stops
  growing. Back after 3 minutes, the game was alive but the server had dropped it. Pre-fetching in the
  background would need a background task the client doesn't have.
- **The device's pace.** About 2 MB/s once set up, half the Mac's 4.7 MB/s on the same kind of run,
  while bursts during setup reached about 25 MB/s. The client paces it, not the network.
- **For Retail** (estimated, not run): the three games share one set of CDN indexes; Retail's build
  metadata is about 240 MB against Classic Era's 20 MB (seconds at the setup rate), but its content
  before character select is several times Classic Era's, so at the device's pace a first launch from
  empty could take tens of minutes, and a hotfix a few (the Mac streamed 417 MB of Retail for one,
  35 MB of Classic Era).
- **A launch that exits early leaves `login.txt`** (the client never opened it, so the shim's close
  never deleted it). The launcher deletes a leftover one at the next launch.
- Not about streaming: the default UI clears the Dynamic Island in landscape, but windows opened in play
  (NPC dialogs, the map) can sit under it, depending on which way the iPhone is turned. The app
  needs to keep the game's window inside the safe area.

## Loading and signing images on the device (2026-10-24)

Every game patch is a new client executable, so an update on the device has to make, sign, and load a
new image from the app's data container. `research/dlopentest` tested that with a `MH_BUNDLE` of our own
(a function returning 42 and a 1 MB `__TEXT` filler), loaded with `dlopen` from `Library/`, on the iPhone
16 Pro and the Vision Pro (both 27.0.1, TXM); then the launcher's update did it with the real client, on
the iPhone. The iPads were never reachable for any of it.

| Image in `Library/`, signed | iPhone | Vision Pro |
|---|---|---|
| With the app's own development identity, on the Mac | loads; `F_ADDFILESIGS_RETURN` and `F_CHECK_LV` pass; the JIT helper's prepare works on it as on the bundle's own image | loads |
| Ad hoc, or unsigned | refused with an ordinary `dlopen` error ("code signature invalid", or "missing code signature"; `F_CHECK_LV` EPERM, "no cdhash"); the process lives | the same |
| With a second development certificate of the team that some **installed** profile lists | loads | not run |
| With that certificate when no installed profile lists it | refused, exactly as ad hoc | not run |
| With that certificate, by zsign **on the device**, from the app's keychain | loads (64 MB signed in 0.15 s) | loads (0.17 s) |

- **Profiles are device-wide.** The profile embedded in the app doesn't have to list the certificate:
  any profile installed on the device (`devicectl device profile list`) that does is enough, and
  `devicectl device profile install` adds one in about a second, with no reinstall. Xcode's managed
  profiles list every development certificate the team has when they're made. The app can't read the
  device's list, so the companion copies a profile it installs into the container for the launcher to
  check. Not tested: whether a profile for another App ID counts, and whether an installed one lasts
  across a reboot.
- **No entitlements blob in a library's or bundle's signature**, not even an empty one: iOS 27 refuses
  the image although macOS's `codesign --verify --strict` accepts it. zsign as published writes one for
  every image; `scripts/zsign.patch` writes it only for an `MH_EXECUTE`. 4 KB code pages are fine.
- **Never load a file written through a shared writable mapping.** zsign signs in place through one,
  and an image `dlopen`ed from that file was killed in dyld's fixup walk (`EXC_BAD_ACCESS`, `SIGKILL -
  CODESIGNING`, Invalid Page) instead of being refused, though the same bytes copied to the device load.
  The signer writes the signed bytes into a new file with `write()` and renames it into place.
- **A reinstall keeps the keychain item and the container**, so an identity and an image made under one
  install survive the next (a free team's weekly re-sign included); what can change is which certificates
  the profiles list.
- **Assembly on the device is cheap.** Rewriting load commands, setting the platform, and retyping a
  50 MB slice in Foundation takes 0.03–0.07 s on the iPhone, and its output is byte-identical to
  `install_name_tool`, `vtool`, and the retype on the Mac for the same slice. Importing a pushed `.p12`
  with `SecPKCS12Import` takes 0.004 s; signing the client image 0.2 s.
- **The whole update on the iPhone**, from a client one build behind (Classic Era 1.15.9.69722, against
  the live service's 70003): the new build's slice 2.0 s (45 MB fetched), its two configs 0.4 s, assembly
  0.03 s, signing 0.2 s; the helper's prepare (2,820 pages, none failed) ran on the image in `Library/`, and
  the client reached character select. The next start loaded it with no screen. A bogus image there was
  refused with a `dlopen` error, and the launcher fell back to the bundled one. With the slice kept, a
  second Update took 0.4 s in all.
- **A certificate's revocation, seen from the Mac.** A development certificate revoked on
  developer.apple.com stayed trusted, hours later, to `SecTrustEvaluateWithError` with an OCSP
  revocation policy that requires a positive answer, and to `security verify-cert -p codeSign -R ocsp -R
  require`, while Apple's OCSP responder (the address in the certificate) answered `revoked` with a
  signature that verifies. So the companion asks the responder itself (`/usr/bin/openssl ocsp`).
- **Old builds leave the HTTPS CDN.** Blizzard's HTTPS mirrors answer 403 or 404 for the files of builds
  a few versions old, while plain HTTP still serves them. The device fetches over HTTPS only, so a check
  of such a build says it couldn't tell. In real use the newer build is the current one, which is always
  there.
- Not tested: the iPads, and (at the time of writing) the visionOS update end to end. A free team's
  certificate signed on the device was tested later, with isideload (below): it loads once the image is
  signed as the app's bundle ID.

## Provisioning without Xcode (isideload, 2026-11-01)

The first step towards a Windows/Linux host ([research/isideload](../research/isideload/README.md)). A
Mac CLI on the isideload crate signed in to a free and a paid Apple ID, registered the iPhone, made the
App IDs for the app and its `.helper` (increased-memory-limit, plus extended-virtual-addressing on the
paid team), made a development certificate with its own key, and downloaded both profiles. A no-image
build signed with zsign from those installed and launched (a free team's needs the developer trusted on
the device first), the launcher imported the pushed `.p12` and signed a game image with it, and the JIT
helper attached on both teams. On the paid team the image loaded and the helper prepared it as under
Xcode's signing. On the free team dyld refused the image the device signed: a free team's profiles are
local, and amfid matches a local profile to code from outside the bundle by the signature's identifier
(`<team>.<identifier>` against the profile's application-identifier). The launcher signs images as
`wow-<flavor>`, so nothing matches. Signed with the app's bundle ID instead, the image loaded, and the
launcher now signs every image that way (checked again on both teams).

- Sign-in needs anisette from a Mac-ADI server: since mid-October 2026 Apple answers `-80045` to the
  Android-ADI servers most tools used.
- listTeams can't tell a free team from a paid one; the profile can.
- isideload links an LGPL-2.1 signer; zsign, the one the device already runs, is the one to use.
- A no-image install into an empty container starts the client with no `.build.info`
  ([#36](https://github.com/paulstraw/slashplayed/issues/36)).
- Open: how long the stored session lasts (measured daily).
