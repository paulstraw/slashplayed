# jittest: executable memory under TXM

Tests whether a development-signed (`get-task-allow`) app on visionOS or iPadOS can execute code it
wrote itself, and in particular at the address of its own signed `__TEXT`, which is what the game
client's startup code rewrite needs. One experiment per launch (a code-signing violation kills the
process outright), chosen by the first argument. Background and full results:
[docs/research.md](../../docs/research.md#executable-memory-jittest).

- `main.c`: the app. Each experiment logs to stdout and `Documents/spjit.log`.
- `../../apps/client/helper/` (the client's helper, built here too), `helper_host.swift`: the on-device JIT helper (H experiments), an app extension bundled
  in SPJitTest that does the debugger's side of the protocol from the device itself. See
  [The helper extension](#the-helper-extension).
- `build-idevice.sh`: builds [idevice](https://github.com/jkcoxson/idevice)'s C library from source at
  a pinned release into `work/idevice/`, for the helper's H2–H4 work.
- `push-pairing.sh`, `push-ddi.sh`: put the RemotePairing record and the developer disk image in
  SPJitTest's container for H2–H4.
- `jit.py`: the lldb side of the StikDebug-compatible `brk #0xf00d` protocol (`x16 = 1` prepares
  `x0..x0+x1`, `x16 = 0` detaches). The companion bundles this same file and uses it at every game
  launch.

## Experiments

| Name | What it does |
|---|---|
| `e1` | Debugger allocates a 1 MB RX region; write `mov x0,#42; ret` through a `vm_remap` RW alias; detach; call it |
| `e2` | The same at an app-chosen fixed address |
| `e3` | Prepared region, then `mprotect` RW → write → RX, no alias |
| `e4a` | Own `__TEXT` filler: the app's own `vm_protect(RW \| VM_PROT_COPY)`, then RX |
| `e4b` | Own `__TEXT`: debugger prepare, then `mprotect` RW → RX |
| `e4c` | No debugger: what the app can do to its own `__TEXT` alone (`mprotect`, `MAP_JIT`, `munmap` + remap) |
| `e4d` | Own `__TEXT`: debugger prepare, alias write of 1 MB, detach, execute in place |
| `e5` | `e4d` at the client's size (a 44 MB filler), for timing the prepare modes |
| `e6`, `e6b` | Prepare, detach, and only then make (`e6`) or write (`e6b`) the alias |
| `e7` | The real libSystem shim (`shims/system`) servicing the client's sequence through `dlsym` over 44 MB |
| `h1` | Start the bundled helper extension and ping it: both pids, and whether the helper reaches 10.7.0.1:49152 and gs.apple.com |
| `h2` | The helper opens the RemotePairing tunnel (idevice) and reports the endpoint, TXM, and the mounted developer disk image |
| `h3` | `e4d` with the helper as the debugger: it mounts the disk image if needed, attaches to the app, prepares, and detaches |
| `h4` | `e7` (the real shim, 44 MB) with the helper as the debugger |
| `h5` | misagent through the helper's tunnel: lists the device's provisioning profiles and installs `Documents/spjit-profile.mobileprovision` if it's there. Needs idevice built with the `misagent` feature (`SP_IDEVICE_DIR`) and `SP_MISAGENT=1` at build time; the shipping helper leaves it out |
| `p1` | The app makes its own RemotePairing record: a fresh one through 10.7.0.1:49152, pair-setup with the PIN the device shows (from `Documents/spjit-pin`) |
| `p2` | The same through visionOS's manual pairing service (Settings > General > Remote Devices open), then a tunnel with the new record; runs under UIKit |

## Running it

Needs a paired device in Developer Mode, Xcode, and `config/local.env` (see
`config/local.env.example`) with your team and signing identity. Make the development profiles (the
app's and the helper's) once with `apps/client/signing/regen.sh <device UDID>`.

```sh
research/jittest/build.sh                       # build, sign, install SPJitTest (com.strawdynamics.spjittest)
research/jittest/run.sh e4d                     # launch stopped, attach Xcode's lldb with jit.py, print the log
SP_JIT_MODE=bulkx research/jittest/run.sh e7    # pick the prepare mode: page (default), pagew, bulk, bulkz, bulkx
SP_PLATFORM=ios research/jittest/build.sh       # the same on an iPad
```

An on-device debugger such as StikDebug launches the app with no arguments; it then runs the
experiment named in `Documents/spjit-which`:

```sh
echo e4d > $TMPDIR/spjit-which
xcrun devicectl device copy to --device <udid> --domain-type appDataContainer \
  --domain-identifier com.strawdynamics.spjittest --source $TMPDIR/spjit-which \
  --destination Documents/spjit-which
```

The H experiments use no lldb: `run.sh h1` (or `h2`, `h3`, `h4`) writes `Documents/spjit-which`,
launches the app with no arguments and prints this run's part of `Documents/spjit.log`. H1 needs
nothing more. H2–H4 need idevice, a RemotePairing record, LocalDevVPN on, and (H3, H4, after a reboot)
the developer disk image:

```sh
scripts/build-idevice.sh              # once: idevice from source, pinned, into work/idevice/
SP_PLATFORM=ios research/jittest/build.sh      # the helper links idevice when work/idevice/ has it
SP_PLATFORM=ios research/jittest/push-pairing.sh   # StikDebug's record into SPJitTest's container, unread
SP_PLATFORM=ios research/jittest/push-ddi.sh       # Xcode's disk image cryptex into Documents/DDI
SP_PLATFORM=ios research/jittest/run.sh h2
```

On the Vision Pro, StikDebug keeps the record elsewhere: `SP_STIKDEBUG_BUNDLE_ID=<its bundle ID>
SP_STIKDEBUG_PAIRING="Library/Application Support/Pairing/pairingFile.plist" research/jittest/push-pairing.sh`.

## The helper extension

A process can't service its own debugger stops (it sits in the `brk`), so the helper is a second
process: a classic app extension inside SPJitTest, which the host starts with NSExtension's private
request calls. It's built with plain `swiftc` and `codesign` like the rest of jittest:

- `SPJitTest.app/PlugIns/SPJitHelper.appex`, `CFBundlePackageType` `XPC!`, an `NSExtension` dictionary
  with `NSExtensionPointIdentifier` `com.apple.ar.viewer` (Apple's AR viewer point, the one LiveContainer's
  LiveProcess and several JIT helpers on iOS use; nothing else starts ours, since its activation rule is
  `FALSEPREDICATE`) and `NSExtensionPrincipalClass` (`SPHelper`, `apps/client/helper/Helper.swift`), and `XPCService`
  with `_ProcessType` `App` and `_MultipleInstances`. installd also requires a non-empty
  `CFBundleDisplayName` (`MissingBundleDisplayNameString`).
- Compiled with `-parse-as-library -application-extension` and linked with `-e _NSExtensionMain`
  (Foundation's), which finds the principal class in the Info.plist.
- Each bundle is signed with its own `application-identifier` and `get-task-allow`, the extension first.
  The team wildcard profile works only for devices registered when it was made, so the helper gets an
  explicit profile from `regen.sh` (`com.strawdynamics.spjittest.helper`).
- No public API starts an app's own classic extension, so the host (`helper_host.swift`) uses
  NSExtension's private class: `+extensionWithIdentifier:error:` with the helper's bundle ID,
  `-beginExtensionRequestWithInputItems:completion:`, and the request's completion, cancellation, and
  interruption blocks. Each request is a new helper process; the request and the reply are the items'
  `userInfo`, and the helper's log comes back with the reply, since there's no channel to stream it.
  Looking the helper up by bundle ID also survives a sideloader renaming the app.
- A launch is up to three requests: `status` (the tunnel, TXM, and whether the disk image is mounted),
  `mount` if it isn't, then `attach`, which replies once the helper has detached. The mount comes first
  because debugserver is in the image. Without UIKit (jittest) all of it has to fit in the 20 s launch
  watchdog; the client brings its scene up before the debugger is involved (`sp_uikit_early` on iOS), so
  there it doesn't.

### Why not ExtensionKit

The helper was first an ExtensionKit extension (`Extensions/SPJitHelper.appex` on an extension point the
host declares in `Extensions/SPJitTest.appexpt`, started with `AppExtensionProcess` and reached over
`NSXPCConnection`), the public way on iOS 26. It passed `h1`–`h4` on the iPhone, but visionOS 27.0.1's
installd refuses it: "Appex bundle … does not specify an Apple extension point as the value of the
EXExtensionPointIdentifier key" (`AppexBundleUnknownExtensionPointIdentifier`). An extension point the app
defines is iOS 26 and later only, although the visionOS SDK has the API (Swift infers visionOS from
iOS). The classic helper works on both, so it replaced it; the ExtensionKit version (and Xcode's layout
for it) is in git history up to eb7f181.

With idevice (`apps/client/helper/Device.swift`, compiled only when `work/idevice/` has the library): the tunnel is
`tunnel_create_rppairing` to 10.7.0.1:49152 and, if that fails, to the ports the device advertises over
Bonjour (found by the host). An earlier visionOS 27 run saw that fixed port reset; on visionOS 27.0.1 it
works. The pairing record is parsed in memory
(`rp_pairing_file_from_bytes`), never written to the helper's disk, and checked for the RemotePairing kind by
key names only. If the device doesn't accept it, idevice falls back to pair-setup and asks for a PIN; the
helper gives none, so that fails and is reported as such. The developer disk image is checked with cryptexd
(and the image mounter, for pre-26.4 images) and, if missing, personalized and installed from the files the
host passes (`cryptex1_assets_load`, `cryptexd_install_ddi`). The prepare speaks to debugserver directly:
`QStartNoAckMode`, `QThreadSuffixSupported`, `QSetDetachOnError:1` (so a helper that fails or dies leaves
the app running instead of debugserver's default, killing it), `vAttach`, register numbers from
`qRegisterInfo` (only after the attach: with no process, debugserver answers it with an error), then at each
stop on our `brk` one `M<addr>,1:<byte>` per 16 KB page in batches of 128, with full 64-bit addresses and
the page's own first byte when the app passes them in x2 (so the contents don't change), a read-back of the
first and last page, x0 set and pc stepped past the `brk`. Other signals pass through; x16 = 0 detaches.

`h1` passes on the iPhone 16 Pro (iOS 27.0.1) and the Vision Pro (visionOS 27.0.1) on the first launch,
with no prompt or approval: the helper is up as its own process (its own `PluginKitPlugin` data
container) 0.06–0.22 s after the request and replies 0.05–0.1 s later, and its TCP connects to
10.7.0.1:49152 (1–2 ms, LocalDevVPN on) and `gs.apple.com:80` (Apple's signing server, which the disk
image's personalization uses; 42–91 ms) succeed. The host needn't be a UIKit app: jittest has no
`UIApplicationMain`.

The Vision Pro, with LocalDevVPN on and the RemotePairing record StikDebug holds there: `h2` brings the
tunnel up through 10.7.0.1:49152 in 0.18 s (no Bonjour needed) and sees TXM and Xcode 27.1's cryptex,
already mounted; `h4` (`e7`, the real shim) is traced 1.4 s after launch, prepares 2,891 pages in
0.143 s with 0 failed writes, and detaches 1.36 s after attaching; contents match and the first and last
pages execute. The whole run takes 1.7 s.

`h2`, `h3`, and `h4` pass on the iPhone (first with the ExtensionKit helper; the classic one gives the
same numbers: `h4` 2,890 pages in 0.105 s, detached 1.28 s after attaching), with idevice v0.1.68 (rustls with the rustcrypto provider),
the RemotePairing record copied from StikDebug, LocalDevVPN on, and the phone on USB and Wi-Fi to the Mac
(neither is used: everything goes through the tunnel):

- `h2`: the tunnel is up through 10.7.0.1:49152 in 0.10–0.19 s, and the helper sees TXM and the mounted
  disk image (the cryptex `com.apple.MobileAsset.DDI` 27.1.9275.0, Xcode 27.1's, mounted earlier by the
  Mac), so H3 and H4 didn't mount one.
- The disk image outlives a reboot on iOS 27.0.1. With the Mac's Wi-Fi off before the iPhone rebooted and
  until after the run (and no cable), `h4` launched from the home screen found the cryptex already
  installed 0.4 s in and passed (2,890 pages in 0.119 s; debugserver took 1.5 s to answer, against ~30 ms
  warm). So once a device has had the image, a launch after a reboot needs no Mac and no mount. The
  helper's mount path is still untested: it matters on a device that never had the image, and probably
  after an OS update or a newer Xcode image.
- `h3` (`e4d`): the helper attaches 1.1 s after the request (the app sees `P_TRACED` 1.2 s after launch),
  prepares 64 pages in 11 ms with the pages' own first bytes and a read-back, and detaches; the code
  written through the alias returns 42 after detach.
- `h4` (`e7`, the real shim): 2,890 pages prepared in 0.131 s, 0 failed writes, detached 1.33 s after
  attaching; contents match and the first and last pages execute. lldb from the Mac took 8.3 s (USB, iPad)
  to ~57 s (Wi-Fi, headset) for about as many pages.

The tunnel needs Wi-Fi on. With Wi-Fi off (cellular data on, LocalDevVPN connected, just after a reboot),
10.7.0.1:49152 fails ("device socket io failed"), and the device advertises `_remotepairing._tcp` only on
`::1%lo0` port 49152, which resets the connection. So a launch with the helper, like one with StikDebug,
needs the device on a Wi-Fi network (any network; the Mac isn't involved).

## Pairing on the device (p1)

Can the app make its RemotePairing record itself, with no Mac? Not on iOS through the loopback VPN. On
the iPhone 16 Pro (iOS 27.0.1), a fresh record's connection to 10.7.0.1:49152 is reset 30 ms in
(`ECONNRESET`), before pair-verify could fail and pair-setup could ask for a PIN: the device's network
RemotePairing service talks only to hosts it already trusts. Nothing was paired, so no trusted host was
added. On iOS the record has to come from a computer the device trusts. The companion does that
(`apps/companion/Sources/Pairing.swift`, `-pair`): over USB, through usbmuxd and lockdown's
remotepairingdeviced service (idevice's `remote_pairing_lockdown_*`), with no prompt on the device. On
the iPhone 16 Pro it took 0.4 s; that record, copied into SPJitTest's container unread, passed `h2` and
`h4` (3,034 pages, 0 failed writes) with no StikDebug involved.

visionOS can do it, the way Xcode pairs a Vision Pro over Wi-Fi (`p2`). With Settings > General > Remote
Devices open, the headset advertises `_remotepairing-manual-pairing._tcp` (here on a high port, found by
browsing Bonjour from the app). Through the loopback VPN (10.7.0.1 at that port), a fresh record's
pair-setup gets the device to show a six-digit code; with it, `rppairing_pair_network` finishes and writes
a 501-byte RemotePairing record, and a tunnel with that record comes up through 10.7.0.1:49152 in 0.16 s.
On the Vision Pro (visionOS 27.0.1) the pair-setup itself took 0.1 s plus the time to type the code. The
paired host then shows under Remote Devices, where it can be removed. Two things about running it:

- The first Bonjour browse asks for local network access (`NSLocalNetworkUsageDescription`).
- It waits on a person, so it can't run in jittest's usual windowless mode: an app with no scene is
  killed by the 20 s launch watchdog (the first try died there, during the permission prompt). `p2` runs
  under `UIApplicationMain` with a window (`ui_host.swift`, the scene manifest in `Info.plist`).

An app that waits for a debugger that never comes is killed by the 20 s launch watchdog
(`0x8badf00d`, "process-launch watchdog transgression"), which main.c's 60 s wait doesn't prevent; a
traced process isn't subject to it.

## Results

Vision Pro (M2, visionOS 27.0) and iPad Pro 12.9" 6th gen (M2, iPadOS 26.6):

- `e1`, `e2`, `e4d`, `e5`, `e6`, `e6b`, `e7` pass; `e3`, `e4a`, `e4b` fail; `e4c` is refused at every
  step. A page made writable in place never executes again; a debugger-prepared page stays `r-x`
  (max `rwx`) and runs code written through an alias, at any address, after detach too.
- Prepare time for 2,820 pages over the headset's Wi-Fi: `page` ~62 s, `pagew` 33–36 s, `bulk`
  24–35 s, `bulkz` 15.6–17.6 s, `bulkx` ~11 s. Over USB to the iPad, `e7` with `bulkz` took 8.3 s.
- `e7` (2,887 pages): contents match, and the first and last pages execute after detach. Most of the
  stop's ~57 s on the headset was lldb's own overhead, not the prepare; the client launch avoids it by
  attaching late (see [docs/architecture.md](../../docs/architecture.md#executable-memory-under-txm)).
- `h5`, on an iPhone 16 Pro (iOS 27.0.1), 2026-11-02, with LocalDevVPN on: the helper's tunnel came up
  through 10.7.0.1:49152 in 0.15 s, misagent (`com.apple.misagent.shim.remote` over RSD) listed 32
  profiles, and installing a fresh free-team profile for another app took 0.08 s (33 after, the new UUID
  among them). So the device can install a renewed profile itself, the last piece of the profile-only
  refresh in [research/isideload](../isideload/README.md). Xcode's developer disk image happened to be
  mounted; misagent is a lockdown service, not one the disk image brings.
