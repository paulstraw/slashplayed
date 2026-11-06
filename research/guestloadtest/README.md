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
  (`_objc_map_images`, `_objc_load_image`), runs initializers, and calls `main`. The guest's `dladdr`, `dlsym`,
  `_NSGetExecutablePath`, and `_dyld_*` answer for the guest; with `prepare_text` set, `__TEXT` stays `r-x` and
  is written only through the alias that callback returns, and the guest's `dlsym("mprotect")` and
  `dlsym("memcpy")` work through it, as `shims/system/spsystem.c` does for the client.
- `toy.mm`: the guest. 21 checks (24 with `SP_GUEST_REFS`), logged ok or FAIL: constructor order, `+load`, a subclass, protocol and
  category, C++ exceptions and NSExceptions across guest frames, thread-locals (template, per thread,
  destructors), a missing weak import, lazy binds, the guest's self-queries, `backtrace`, rewriting its own
  code through `dlsym`'d `mprotect`/`memcpy`, and both ends of a 44 MB `__TEXT` filler (Classic Era's size).
  With `SP_GUEST_REFS=<game>` (build.sh's default, `retail`; `none` skips it) it also imports every symbol
  that game's client does, from the same library (`../loadertest/gen_refs.py`, symbol names only, from the
  local recon and thinned client into the ignored `out/`), subclasses AppKit's `NSView`, and checks that
  libspSystem's `sp_client_text` is the guest.
- `host.c`: the Mac host. A `vm_remap` alias stands in for the device's prepared region.
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

With `SP_GUEST_REFS=retail`, the shims in the bind path, 2026-11-06: 23 of 23 on the Mac (real frameworks),
24 of 24 on the iPhone and the Vision Pro. All 1,084 of Retail's imports bind through the shims (none absent;
the two weak ones are present); the link takes 0.033 s on the Mac, 0.082 s on the iPhone, 0.111 s on the
headset, and `main` is reached 1.96 s (iPhone) and 1.97 s (headset) after launch.
