# guestloadtest: an unsigned Mac program loaded without dyld

Can the launcher run the game client unchanged and unsigned, the way Tolkara does, instead of rewriting,
retyping, and signing it for dyld? This harness answers that for a program of our own built like the client
(`MH_EXECUTE`, dyld-info opcode fixups from `-mmacosx-version-min=11.0`), with the prepare done by the
client's own on-device JIT helper. Background: [docs/research.md](../../docs/research.md),
[jittest](../jittest/README.md) (the helper, TXM, the prepare), [dlopentest](../dlopentest/README.md) (why a
team-signed image is needed for dyld).

- `spguest.h`, `spguest.c`, `spguest_tlv.S`: the loader, modelled on Tolkara's (MIT,
  github.com/tolkara/tolkara, `runtime/`). It maps the segments into one reserved span, applies the rebase,
  bind, lazy, and weak opcode streams (lazy pointers bound at load), serves thread-locals through its own
  `__tlv_bootstrap`, registers unwind info (`__unw_add_find_dynamic_unwind_sections`) and Objective-C
  (`_objc_map_images`, `_objc_load_image`), runs initializers, and calls `main`. The guest's `dladdr` and `_dyld_*`
  answer for the guest; with `prepare_text` set, `__TEXT` stays `r-x` and is written only through the alias
  that callback returns. `dlsym` and `_NSGetExecutablePath` are the guest's libraries': on the device the
  shims', whose `dlsym("mprotect")` and `dlsym("memcpy")` write through that alias (`sp_set_client`), and
  whose executable path is the host's, as the dyld-loaded client sees the launcher's.
- `toy.mm`: the guest. 20 checks (23 with `SP_GUEST_REFS`), logged ok or FAIL: constructor order, `+load`, a subclass, protocol and
  category, C++ exceptions and NSExceptions across guest frames, thread-locals (template, per thread,
  destructors), a missing weak import, lazy binds, the guest's self-queries, `backtrace`, rewriting its own
  code through `dlsym`'d `mprotect`/`memcpy`, and both ends of a 44 MB `__TEXT` filler (Classic Era's size).
  With `SP_GUEST_REFS=<game>` (build.sh's default, `retail`; `none` skips it) it also imports every symbol
  that game's client does, from the same library (`../loadertest/gen_refs.py`, symbol names only, from the
  local recon and thinned client into the ignored `out/`), subclasses AppKit's `NSView`, and checks that
  libspSystem's `sp_client_text` is the guest.
- `host.c`: the Mac host. A `vm_remap` alias stands in for the device's prepared region, and its `dlsym` (the
  loader's `symbol` option) for libspSystem's, which the Mac host has no shims for.
- `device.c`: the device host. The helper attaches, spguest reserves the span, the helper prepares
  `__TEXT` in one `brk #0xf00d` stop and detaches, and the toy's `__TEXT` is copied in through the alias. The
  toy's libraries are opened through `shims/generated/rewrite-map.txt`, bundled beside the executable, so the
  shims in `Frameworks/` take the client's libraries as they do today. libspSystem is told where the guest is
  (`sp_set_client`: dyld never lists it), so its stubs' caller offsets, the `__TEXT` services, and crash
  reports name the guest.
- `build.sh mac` builds and runs the toy on the Mac; `build.sh device` builds and installs
  `SPGuestLoadTest.app` with the helper (`SP_GUEST_BUNDLE_ID` reuses another test app's profiles and
  container). `run.sh` copies the unsigned toy into `Documents/`, launches the app, and prints the run.

## Running it

```sh
research/guestloadtest/build.sh mac
SP_PLATFORM=ios SP_GUEST_BUNDLE_ID=com.strawdynamics.spdlopentest research/guestloadtest/build.sh device
SP_PLATFORM=ios SP_PUSH_TO=com.strawdynamics.spdlopentest SP_STIKDEBUG_BUNDLE_ID=<Slashplayed's bundle ID> \
  SP_STIKDEBUG_PAIRING=Library/sppairing.plist research/jittest/push-pairing.sh
SP_PLATFORM=ios SP_PUSH_TO=com.strawdynamics.spdlopentest research/jittest/push-ddi.sh
SP_PLATFORM=ios SP_GUEST_BUNDLE_ID=com.strawdynamics.spdlopentest research/guestloadtest/run.sh
```

The helper needs what jittest's `h3` does: LocalDevVPN on, Wi-Fi, the pairing record, and the disk image.

The harness has no App ID of its own yet (`com.strawdynamics.spguestloadtest`, build.sh's default, isn't in
`apps/client/signing/regen.sh`), so every run so far installed it as dlopentest's
(`SP_GUEST_BUNDLE_ID=com.strawdynamics.spdlopentest`), which replaces SPDlopenTest on the device and keeps its
container; `research/dlopentest/build.sh` puts SPDlopenTest back.

## Results

- Mac (macOS, arm64): 21 of 21.
- iPhone 16 Pro (iOS 27.0.1, TXM), 2026-11-06: 21 of 21. The helper was attached 1.61 s after launch;
  the prepare covered the toy's whole `__TEXT` (2,822 pages, 44 MB) in 0.129 s (0.105 s of writes), detach
  0.017 s, load 0.175 s with both included, link 0.009 s, `main` reached 1.90 s after launch. The private
  Objective-C and unwinder hooks resolve and work on iOS.
- Vision Pro (visionOS 27, TXM), 2026-11-06: 21 of 21, twice. Attached 1.66–1.86 s after launch, prepare
  0.112–0.130 s for the same 2,822 pages, detach 0.017–0.019 s, link 0.010–0.014 s, `main` 1.94–2.11 s
  after launch. The hooks work on visionOS too.
- iPad: not run.

Those runs had the loader answer the guest's `dlsym` and `_NSGetExecutablePath` too (and a 21st check, the
guest's own export through `dlsym(RTLD_MAIN_ONLY)`); now the shims do, as for the real client below. The Mac
run after that change: 20 of 20, and 22 of 22 with `SP_GUEST_REFS=retail`.

With `SP_GUEST_REFS=retail`, the shims in the bind path, 2026-11-06: 23 of 23 on the Mac (real frameworks),
24 of 24 on the iPhone and the Vision Pro. All 1,084 of Retail's imports bind through the shims (none absent;
the two weak ones are present); the link takes 0.033 s on the Mac, 0.082 s on the iPhone, 0.111 s on the
headset, and `main` is reached 1.96 s (iPhone) and 1.97 s (headset) after launch.

## The real client, through the launcher

`SP_GUEST_CLIENT=<path in the app's home>` (`apps/client/spguestlaunch.m`, a dev switch; `run.sh` passes it)
has the launcher load that file, the game's client unchanged and unsigned, with spguest instead of dlopen'ing
the bundled image. Everything before the load is the launcher's as for any start (flavor, region, the game
data's checks, the saved sign-in and `login.txt`, the helper's attach, the loading screen), in the installed
app's own container; the patch check is skipped (the file is the bundled image's build). The app still needs
the game's bundled image, which names the build.

```sh
# The unchanged arm64 slice of the build the device's game data is (the companion's CDN cache keeps one per
# build, cdn/<hash>.arm64; its LC_UUID matches the assembled image's), into the app's container:
xcrun devicectl device copy to --device "$SP_DEVICE" --domain-type appDataContainer --domain-identifier "$SP_BUNDLE_ID" \
  --source <slice> --destination Library/spguest/wow-classic_era
SP_PLATFORM=ios SP_FLAVOR=classic_era SP_GUEST_CLIENT=Library/spguest/wow-classic_era SP_SKIP_INTRO=1 apps/client/run.sh
```

iPhone 16 Pro (iOS 27), Classic Era 1.15.9.70576, 2026-11-06: **character select**, signed in from the saved
sign-in (`login.txt` opened and deleted by the client as with dyld), then 60 fps at character select. The
helper attached 1.54 s after launch; the prepare covered `__TEXT` (2,817 pages, 44 MB) in 0.125 s, detach
0.017 s, load 0.172 s with both, link 0.067 s (every import bound, none unresolved), the client's
initializers 0.106 s, so `main` 2.68 s after launch. Its startup rewrite went through libspSystem's
`dlsym`'d `mprotect` and `memcpy` (no-ops on `__TEXT`, writes through the alias), the path redirect took the
launcher's executable path as for the dyld-loaded client, and the first frame came 6.4 s after the client was
asked for.

The first try named the guest by the bundled image's path (for `dladdr` and image 0); something in the
client's start then had dyld load that image too: a second client, every Objective-C class twice, and a hang
on the loading screen. Named by its own file, which dyld can't load, it runs. The AppKit shim's stats name
most of the client's threads `?` as they do for the dyld-loaded client (the threads are unnamed), but its
stall stacks showed the client's frames as bare addresses where the dyld-loaded client's read
`wow-<flavor>+offset`: dyld's `dladdr` has no image for the guest. libspSystem's `sp_dladdr` now names them
from what `sp_set_client` told it, and the shims' stall, render-callback, crash, and exception stacks use it:
Retail's 3 s stall stack on the iPhone, 2026-11-07, reads `wow-retail+offset` for every client frame.

iPhone 16 Pro (iOS 27), Retail 12.1.5.70688, 2026-11-06: **in the world**, past character select, with no
change to the loader. The app needs Retail's bundled image only for its stamp; an iOS app built with Classic
Era alone took the companion's visionOS Retail image, retargeted to iOS with `vtool -set-build-version` and
signed (never loaded), with `spbuild-retail` beside it. The helper attached 1.41 s after launch; the prepare
covered `__TEXT` (3,268 pages, 51 MB) in 0.093 s, detach 0.018 s, load 0.145 s with both, link 0.074 s (every
import bound, none unresolved), 13,072 initializers in 0.122 s, `main` 2.55 s after launch. One client
image, no class loaded twice. The first frame came 15.9 s after the client was asked for (the main thread
waits in the client's own startup for most of it, a stall reported every 3 s from 6.6 s to 15.6 s), the
client opened and deleted `login.txt` at 19.8 s, and once in the world it held 60 fps (worst frame 18 to
42 ms) at about 4.2 GB footprint, 1.9 GB left, thermal fair, as large as the dyld-loaded Retail on the
headset.

### The dyld baseline, Retail on the iPhone

The same client loaded the usual way, iPhone 16 Pro (iOS 27), Retail 12.1.5.70688, 2026-11-06: the same
command without `SP_GUEST_CLIENT`, the app's bundled `wow-retail` now a real iOS image (`build.sh`'s steps,
`install_name_tool`, `vtool` to iOS 26.0, `retype.py`, on the companion's cached arm64 slice of that build,
the one the guest loads; the same steps to visionOS give the companion's image byte for byte up to the
signature), signed and dlopen'ed. Same app, same bundle ID and container, same launcher. A newer build
(12.1.5.70783) is out, which the guest path never looks for but the dyld path stops for on its newer-build
screen, so these runs passed `SP_PATCH_SERVICE=Library/sppatchtest` with a one-row `versions` naming the
image's build (written from its stamp): "up to date" in 0.0 s, no screen, nothing fetched. Then three runs of
each path back to back, to character select (nobody pressed Enter World), seconds on run.sh's clock:

| Run | Attached | Prepare | `main` | First frame | 3 s stalls | `login.txt` | 30 s | 60 s at character select |
|---|---|---|---|---|---|---|---|---|
| guest 1 (above) | 2.18 | 0.093 s | 2.55 | 15.9 s | 4 | 19.8 | 21.9 fps | (in the world) |
| guest 2 | 2.89 | 0.122 s | 3.29 | 6.0 s | 1 | 10.7 | 31.7 fps | 60.0 fps, 3385 MB, 2758 left |
| guest 3 | 2.27 | 0.128 s | 2.60 | 5.6 s | 1 | 9.6 | 30.3 fps | 60.0 fps, 3358 MB, 2785 left |
| dyld 1 | 2.28 | 0.123 s | 2.78 | 6.3 s | 1 | 10.4 | 36.4 fps | 60.0 fps, 3481 MB, 2662 left |
| dyld 2 | 2.56 | 0.119 s | 2.97 | 5.8 s | 1 | 10.2 | 30.8 fps | 59.9 fps, 3467 MB, 2676 left |
| dyld 3 | 2.65 | 0.124 s | 3.08 | 5.7 s | 1 | 10.1 | 29.7 fps | 59.7 fps, 3470 MB, 2673 left |

Prepare is the helper's write time for dyld and spguest's prepare for the guest (both 3,268 pages). `main` is
spguest's "calling main", and for dyld the end of the dlopen ("loaded the bundled image"), initializers
included in both. From the helper's attach to `main`: 0.33 to 0.40 s through spguest, 0.41 to 0.50 s through
dyld. First frame is "after the client was asked for". Every run: one client image, no class loaded twice.

Our own loader costs nothing at startup: the client's start is 5.6 to 6.3 s either way, with one 3 s stall,
and spguest reaches `main` a little sooner than dyld. The first guest run's 15.9 s and four stalls aren't the
loader: run again, the guest starts like dyld. That run was the first Retail start in days and the phone
was cooler (thermal nominal at 30 s; these runs were fair, then serious from 30 or 60 s on), so a cold
cache is the likely cause, not checked. At character select both hold 60 fps; the guest's footprint is
about 100 MB smaller (3358 to 3385 MB against 3467 to 3481 MB), but that doesn't hold in the world (below).

In the world, 2026-11-07: the same setup, alternating guest and dyld, Enter World pressed by hand as
character select showed (about 10 s in), each run to the same spot (Murloc Hideaway, the Wandering Isle, a
level-3 character, at 61.8, 79.8 for guest 4 and 62.2, 81.5 for the rest; guest 1 was in the same sub-zone).
The stats, fps / worst frame /
footprint / left / thermal:

| Run | First frame | 60 s | 90 s | 120 s |
|---|---|---|---|---|
| guest 1 (above) | 15.9 s | 40.2 / 1431 ms / 4288 / 1855 / fair | 60.0 / 18 ms / 4241 / 1902 / fair | 60.0 / 42 ms / 4267 / 1876 / fair |
| guest 4 | 5.6 s | 55.9 / 655 ms / 4287 / 1856 / nominal | 60.0 / 17 ms / 4316 / 1827 / nominal | 59.9 / 43 ms / 4338 / 1805 / nominal |
| guest 5 | 5.4 s | 57.3 / 843 ms / 4187 / 1956 / serious | 60.0 / 18 ms / 4213 / 1930 / serious | 60.0 / 18 ms / 4227 / 1916 / serious |
| dyld 4 | 5.4 s | 58.3 / 831 ms / 4245 / 1898 / fair | 59.9 / 70 ms / 4263 / 1880 / fair | 60.0 / 26 ms / 4275 / 1868 / fair |
| dyld 5 | 6.1 s | 53.5 / 874 ms / 4238 / 1905 / serious | 60.0 / 17 ms / 4247 / 1896 / serious | 60.0 / 17 ms / 4255 / 1888 / serious |

(A dyld run where Enter World was pressed late, still at character select at 30 s, is left out: 46.3 fps at
60 s, then 60.0 at 90 and 120 s, 4266 to 4272 MB.) At 60 s every run is still streaming the world in (the
world's first frames, a worst frame of 0.7 to 0.9 s); from 90 s every run holds 60 fps with worst frames of
17 to 70 ms. In the world the footprints overlap, guest 4213 to 4338 MB, dyld 4247 to 4275 MB at 90 and 120 s,
so the character-select gap isn't the loader's: just after the client loads both are 140 to 176 MB, and the
gap opens while the client streams character select in (likely what it streams varies run to run; not checked). Thermal varied with the
order of the runs, not the path. Every run: one client image, no class loaded twice. Loading through spguest
costs nothing in play either.
