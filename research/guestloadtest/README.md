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
on the loading screen. Named by its own file, which dyld can't load, it runs. The AppKit shim's stats name the
client's threads `?`, probably because the shims' `dladdr` doesn't know the guest (not checked).
