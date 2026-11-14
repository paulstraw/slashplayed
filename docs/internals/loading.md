# Running the client

How the device runs the game's unchanged, unsigned Mac client: executable memory under TXM, the
on-device debugger that makes it possible, and spguest, the loader.

## Executable memory under TXM

The client rewrites its own code at startup: it makes regions of its own `__TEXT` writable, writes
new code there, and makes them executable again. On macOS that's ordinary. On M2-era devices running
visionOS 26+/iPadOS 26+, the Trusted Execution Monitor (TXM) decides what may execute, and no
certificate a third party can get grants `MAP_JIT` there. The M1 iPads predate TXM (the Page
Protection Layer, PPL, enforces code signing there instead), and the path below runs on them too, as
players have found.

What does work, on visionOS 27 and iPadOS 26 alike (measured in `research/jittest`):

- A page that a **debugger** has written to stays `r-x` with maximum protection `rwx`. Code written to
  it afterwards **through a separate read-write alias** (`vm_remap`) executes, at any address,
  including the app's own signed `__TEXT` at its real load address, and keeps working after the
  debugger detaches.
- A page made writable **in place** (`mprotect` RW, or even `vm_protect` with `VM_PROT_COPY`) can
  never be executable again.

So the client's rewrite is serviced through an alias mapping, by the launcher's loader and the libSystem
shim (`shims/system/spsystem.c`):

- The loader reserves the client's span before its code is in it, and asks the debugger, with one
  `brk #0xf00d` (the StikDebug-compatible protocol), to prepare all of `__TEXT` (`prepare_text` in
  `apps/client/spguestlaunch.m`). The debugger writes over every page (`research/jittest/jit.py`, mode
  `bulkx`: raw binary `X` packets, the fewest round trips), then detaches. The loader maps a read-write
  alias of `__TEXT`, copies the client's code in through it, and tells the shim where both are
  (`sp_set_client`).
- The client looks up its memory functions with `dlsym`. The shim's `dlsym` hides
  `pthread_jit_write_protect_np` (no `MAP_JIT` here), so the client takes its plain
  `mprotect`/`memcpy` path, and hands out the shim's own `mprotect` and `memcpy`.
- `mprotect` inside `__TEXT` returns 0 without doing anything, and the shim's `memcpy` writes into
  `__TEXT` through the alias. `__TEXT` itself is never writable.

A `brk` with no debugger kills the process, so the launcher waits for the helper's attach and checks
`P_TRACED` before the stop. The debugger is needed at every launch (the prepare can't happen after
detach).

## The on-device JIT helper

A process can't service its own debugger stops, so the debugger is a second process: an app extension
bundled in the app (`apps/client/helper`, `PlugIns/SPJitHelper.appex`). It's a classic extension that
claims Apple's AR viewer extension point (`com.apple.ar.viewer`), with an activation rule nothing
matches, because visionOS installs an extension only on one of Apple's points. The launcher starts it
by bundle ID with `NSExtension`'s private request calls, the ones LiveContainer uses; each request is a
new helper process. On a free Personal Team the helper takes one more of the team's weekly App IDs, but
not one of the three app slots a device has for free teams.

The helper reaches the device's own developer services the way a Mac does over the network: it opens
a RemotePairing tunnel through a loopback VPN (LocalDevVPN, at `10.7.0.1:49152`) with
[idevice](https://github.com/jkcoxson/idevice), linked statically (`scripts/build-idevice.sh`). Through
the tunnel it starts debugserver and speaks the GDB remote protocol to it. The launcher (`spjit.m`)
runs, before the client is loaded:

1. **status**: the tunnel, and whether the developer disk image is mounted.
2. **mount**, only when it isn't: debugserver is in the image. The helper personalizes the image's
   cryptex with Apple's signing server and installs it. On iOS 27 it stays mounted across a reboot.
3. **attach**: the helper attaches, and once the launcher sees `P_TRACED` it starts loading the client.
   The helper services the loader's prepare stop (one byte written to every 16 KB page of `__TEXT`,
   2,800 to 3,300 pages in about 0.1 s) and detaches (`guest: detached`, the line the companion's launch
   follows).

One more request, **profiles**, installs provisioning profiles through misagent over the same tunnel
(`com.apple.misagent.shim.remote`) and lists the device's: iOS opens an app on any valid installed profile
for its App ID, not only the one it embeds, so a renewed profile keeps the app opening with no re-sign
and no reinstall. The launcher's `sp_jit_profiles` hands over only the app's and its helper's own
profiles.

A launch with the image mounted takes about 1.5 s from start to attached. On iOS the launcher shows the
scene first (see [iPad](shims.md#ipad)), and if the helper can't do its part, the launcher puts the
reason on the scene and doesn't load the client: no pairing record, no image to mount. LocalDevVPN off
isn't one of those: before pairing and each status request, the launcher tries a TCP connect to
`10.7.0.1:49152`, and when that fails it shows a screen and waits (`spvpn.m`). The screen opens
`localdevvpn://enable?scheme=slashplayed`, once by itself and again from its button: LocalDevVPN turns
its VPN on and opens `slashplayed://` (the app's one URL type), back to the app. The connect, tried every
second off the main thread, is what ends the wait, so turning it on by hand works too. An app that a
debugger already holds (StikDebug launched it) skips the helper. When the device no longer accepts the
record (the status reply says `rejected`: the tunnel's pair-verify failed and idevice asked for a
pair-setup code), the launcher deletes it, so it's made again.

What the helper needs is in the app's data container. The companion puts it there when it installs,
except the headset's record:

- **The RemotePairing record** (`Library/sppairing.plist`), on an iPad or iPhone. iOS won't make one on
  the device (its network RemotePairing service resets a host it doesn't trust before pair-setup), so
  the companion makes one over USB, through lockdown's `remotepairingdeviced` service, with no prompt
  (`Pairing.swift`). It's a credential: never read or logged, 0600 on the Mac and deleted after the
  copy. The launcher hands it to the helper in memory.
- **The headset's RemotePairing record**, made on the headset, by Slashplayed, on its first launch. With
  Settings > General > Remote Devices open, visionOS advertises `_remotepairing-manual-pairing._tcp`
  and does pair-setup with a six-digit code it shows, the way Xcode pairs a Vision Pro over Wi-Fi. The
  launcher shows a pairing screen (`sppair.m`; UIKit starts before the client for it, as on iOS, since
  the launch watchdog kills an app that waits on a person without a scene), finds the service over
  Bonjour (so the local network prompt is the app's), and sends the helper a **pair** request. The
  helper runs pair-setup with idevice (`helper/Pair.swift`), so idevice stays out of the launcher. The
  code is needed while that request is running, and a request has no way in, so the helper connects
  back to a listener the launcher opens on 127.0.0.1 (its port and a random token are in the request;
  the code goes only to a connection that sends the token). The helper proves the new record with a
  tunnel and returns it in its reply, and the launcher writes it to `Library/sppairing.plist` (0600)
  and goes on with the launch. iOS refuses pair-setup with itself, hence the companion's USB pairing
  there.
- **The developer disk image** (`Library/spddi/`), copied from the Mac's Xcode
  (`DeveloperDiskImage.swift`): the cryptex only, ~17 MB for iOS and ~13 MB for visionOS. It's copied
  again when Xcode has a newer one.

## Loading the client: spguest

visionOS won't `exec` or `posix_spawn` another executable from an app bundle, dyld won't `dlopen` an
`MH_EXECUTE`, and the system runs no code that isn't signed. So the launcher loads the game's client
itself, with spguest (`apps/client/spguest.c`, `spguest.h`, and `spguest_tlv.S`; its load step is
`spguestlaunch.m`), a loader of our own modelled on Tolkara's (MIT, github.com/tolkara/tolkara,
`runtime/`). The client is `Library/spgames/wow-<flavor>`, the arm64 slice of Blizzard's Mac file as it
is: no load-command rewrite, no retype, no signature. dyld never sees it. spguest:

- **maps** its segments into one reserved span. On the device `__TEXT` is prepared by the helper first and
  written only through a read-write alias ([above](#executable-memory-under-txm));
- **binds** it, applying the rebase, bind, lazy, and weak opcode streams (the clients' dyld-info fixups;
  lazy pointers are bound at load). Each library the client names is opened through the app's
  `rewrite-map.txt`, so the shims in `Frameworks/` take the macOS frameworks and the device's own
  libraries the rest, as the bind check assumed. An import nothing provides fails the load with its name;
- **registers** it with the Objective-C runtime (`_objc_map_images`, `_objc_load_image`) and the unwinder
  (`__unw_add_find_dynamic_unwind_sections`), so its classes, categories, `+load`, C++ exceptions, and
  NSExceptions work as from a dyld-loaded image, and serves its thread-locals through its own
  `__tlv_bootstrap`;
- runs its initializers and calls `main`.

Those three hooks are private. The launcher checks for them before the start screen
(`sp_guest_hooks_problem`), so a new OS that took one away says so before anything is downloaded. Before
the sign-in it checks the client's file with spguest's own parse of its header and load commands
(`spguest_check_file`, through `sp_guest_preflight`), so a file the device can't load (one with chained
fixups, say, which spguest doesn't apply) says why before anyone types a password, not after the helper's
attach. The start's retire and Update's check of a new slice use the same parse, so none of them passes a
file the load refuses.

**The client's questions about itself.** dyld never lists the client, so spguest answers for it: `dladdr`
and the `_dyld_*` image calls give it as image 0, named by its own file. Its `dlsym` and
`_NSGetExecutablePath` are the libSystem shim's, as for a dyld-loaded client; the executable path is the
launcher's, which the [install-root redirect](shims.md#sandbox-redirects) expects. The loader tells the
shim where the client and its `__TEXT` alias are (`sp_set_client`), so the shims' caller offsets and the
`__TEXT` services find it, and `sp_dladdr` names the client's frames (`wow-<flavor>+offset`) in the
shims' stall, render-callback, crash, and exception stacks, where dyld's `dladdr` has nothing.

**The self-`dlopen`.** Once, early in `main`, the client `dlopen`s the path `dladdr` gives for its own
code. Under dyld that returned the loaded image. For the client's own file, an unchanged `MH_EXECUTE`,
dyld refuses ("cannot dlopen a main executable") and the client goes on with NULL. spguest's `dlopen`
hook answers that path with NULL without asking dyld, in case a later dyld would load it. Every game has
played into the world that way; what the client keeps the handle for isn't known.

A load that fails after the attach ends the launch with spguest's reason (an unresolved import, an opcode
it doesn't know, a refused hook). A file in `Library/spgames` that isn't a client spguest can load (not an
arm64 `MH_EXECUTE`, or cut short) is retired at the start
with its stamp, row, and `spsource` (`sp_slice_retire`), so the next Play or Update replaces it. Loading
through spguest costs nothing measurable against dyld, at startup or in play
(`research/guestloadtest/README.md`, "The dyld baseline"). Its test is the guest toy in
`apps/client/guesttest/`, a program of our own built like the client: CI runs its checks on the macOS
runner (`SP_GUEST_REFS=none apps/client/guesttest/build.sh mac`), which also shows the private hooks still
work there; the device runs are manual. The system's crash reports don't symbolicate the client, since
dyld doesn't list it; the shims' own crash and stall stacks name it.
