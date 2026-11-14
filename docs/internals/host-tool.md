# The host tool (no Mac)

The Slashplayed Companion for Windows and Linux (`apps/companion-rs`, Rust: the window,
`slashplayed-companion`, and the command line, `slashplayed-cli`, on one library) sets up an iPad or
iPhone from Windows, Linux, or a Mac without Xcode. It does what the companion does with Xcode and
devicectl, and nothing the device does for itself: the device installs and updates games, picks their
region, and writes `.build.info`, `Config.wtf`, and the addons. **Vision Pro stays Mac-only:** there's no
public visionOS developer disk image besides Xcode's, and pairing a headset without a Mac is unproven.
The tool refuses a headset.

One run, of the window or of `slashplayed-cli [install]`, which also signs the app again whenever the
device can't renew its own profiles:

1. **The device kit** (`src/kit.rs`): the device app, unsigned and, like every build of it, with no game
   in it, one per platform, which `scripts/release/device-kit.sh` assembles at release from what
   `bundle-resources.sh` stages, as `ClientAssembly.assemble` does. Only the bundle ID is left to fill in
   (`@BUNDLE_ID@` in the two Info.plists), plus the entitlements templates. A release build has the kit's
   SHA-256 compiled in (`build.rs`, `SP_KIT_SHA256`) and downloads it from its own GitHub Release;
   `--kit` names a local one. The kit comes first, so a bad download doesn't cost a sign-in.
2. **The device** (`src/device.rs`), over USB through usbmuxd: Apple's driver on Windows (Apple Devices or
   iTunes), the `usbmuxd` service on Linux, macOS's own on a Mac. If this computer isn't trusted, the tool
   pairs (lockdown `Pair`; the person taps Trust) and saves the record with usbmuxd, as Finder or iTunes
   would. If Developer Mode is off, the tool reveals it in Settings (amfi); the window then waits through
   the device's restart and Turn On, while `slashplayed-cli` stops and is run again.
3. **The Apple ID** (`src/account.rs`), through the vendored isideload: GSA over SRP, 2FA, anisette from
   `mac-ani.jkcoxson.com` by default (`--anisette` for another). The password is typed, used for the one
   login, and zeroed. The whole login lives in memory and ends with the process, so each run asks again.
   No tracing subscriber is installed, and `DEBUG_SENSITIVE` is cleared at start.
4. **Provisioning** (`src/provision.rs`), isideload's low-level developer-services API, not its
   `Sideloader`:
   - The device is registered.
   - The App IDs `<bundle id>` and `<bundle id>.helper` are found, or made only when missing and the
     team has room.
   - Capabilities are set in one v1 PATCH: increased-memory-limit, plus extended-virtual-addressing,
     which Apple refuses a free team: a free team gets 403, a paid one a 2xx. Any other status stops the
     run, rather than signing a paid team's app as a free one's.
   - The certificate is one whose public key is this computer's.
   - Both profiles are downloaded and checked: application-identifier, the device, our certificate, and
     the entitlements.
   - Free or paid is the profile's call (`IsFreeProvisioningProfile`, or a 7-day life): listTeams has no
     flag for it.
5. **Signing** (`src/sign.rs`, `zsign/`): zsign, compiled in by the spzsign crate (`zsign/build.rs`) from
   the source `scripts/build-zsign.sh source` patches, with OpenSSL 3.5 from openssl-src. It's a crate of
   its own, at a fixed version, so a release's version bump doesn't rebuild OpenSSL.
   - Each bundle is signed with its own profile and the entitlements the Mac signs it with: the kit's
     templates, less `Signing.freeTeamDropped` on a free team. A profile's own entitlements carry more
     (keychain-access-groups).
   - The key, certificate, and profiles go to zsign in memory (`zsign.patch`'s `InitData`).
6. **Install** over USB: an IPA built from the signed folder, with the Unix modes set by the tool so a
   Windows build is the same, through installation_proxy. That updates in place and keeps the container.
7. **Into the container** (house_arrest, AFC):
   - The RemotePairing record (`Library/sppairing.plist`, as `Pairing.send`), when the app has none or
     with `--pair-again`.
   - The developer disk image (below).
   - The Apple token as `Library/spappletoken.json`, every run: the `xcode.auth` app token from this
     sign-in, its adsid, and the anisette server and machine identity it was made on
     (`account::device_token`). The launcher imports it into its keychain (`spapple.m`) and gets the app's
     renewed profiles from Apple with it. Not with `--server-client-info`, whose client identity the
     device doesn't claim.

   Nothing else: the device installs and updates games with no credential on it. The token is only for
   the app's own profiles.

**The signing key** stays between runs in the OS credential store, never a file: the macOS Keychain,
Windows Credential Manager, or the Secret Service on Linux (`src/keystore.rs`). There's one item per
Apple ID, and it's stored before Apple sees a request for it. With no store (a Linux box with no Secret
Service), each run makes a new key and certificate. At the team's certificate limit, the tool revokes the
oldest certificate a Slashplayed tool made (machine name "Slashplayed companion", the earlier
"Slashplayed setup", or the spike's "Slashplayed spike"), and never anyone else's. Xcode's Manage
Certificates lists only Apple Development certificates, not the "iOS Development" kind these are, so this
is the only way such a slot comes back without a paid team's developer site.
- With no store, the tool can't find its certificate again next run, so it would reach the limit every
  run and keep revoking, possibly another computer's certificate (that computer's device then won't open
  Slashplayed until it runs again). So without a store it asks first: the window shows the certificates
  with Revoke and Cancel, and `slashplayed-cli` stops at the limit and revokes only with
  `--revoke-oldest`. With a store it revokes without asking, at most once per computer.

**The developer disk image** (`src/ddi.rs`). With no Xcode on the host, the
iOS cryptex comes from the `doronz88/DeveloperDiskImage` mirror at run time, from a pinned commit, each
file checked against a pinned SHA-256. Slashplayed never hosts it. The files go to `Library/spddi/` as
`DeveloperDiskImage.swift` puts Xcode's, with `version.txt` last.
- The pin is the mirror's image as published: Xcode 27 beta's build 27A5228h.
- On a device the Mac companion set up, `version.txt` names Xcode's image, so the tool replaces that copy
  with the mirror's, which may be older (27A5228h in place of a local Xcode's 27B52). That's fine: the
  helper mounts only when no image is installed, and the mirror's mounts on every iOS version that Xcode
  27 supports. The next Play from the Mac copies Xcode's back.
- The device still trusts only Apple's signature. The helper has the image personalized by Apple's TSS
  for the device before mounting it.
- On iOS 27 the image is a cryptex that stays installed across restarts: a device needs one once, not
  after every reboot. Testing this on a Mac needs care, because CoreDevice installs Xcode's own image
  whenever devicectl starts a developer service (`apps/client/run.sh` does). Remove the installed one
  with idevice's `cryptexd uninstall com.apple.MobileAsset.DDI`, then launch from the device, unplugged.

**Credentials** follow the companion's rules:
- The pairing record goes from idevice's memory straight to the device over AFC, so it never touches the
  host's disk.
- Logs give sizes only. The scratch folder (private, deleted at exit) holds only the kit, the app, and
  the IPA.

**isideload is vendored** (`apps/companion-rs/vendor/isideload`, `VENDORED.md`, `isideload.patch`).
- Upstream links its LGPL-2.1 signer, apple-codesign-quick, unconditionally. A static binary would then
  carry the LGPL's relinking terms, so the vendored copy puts the signer behind an off-by-default feature.
- `scripts/check-tree.sh` checks that the signer stays optional and that the idevice pin and version
  agree with the rest of the repo.
- `scripts/crate-notices.py --deny-copyleft` fails a release build that links any GPL-family crate.

**Releases.**
- **Every `v*` release, labeled experimental**: `release.yml` attaches the kit to the release, then
  builds the tool against it for Linux x86_64 and aarch64 and Windows x86_64 (`companion-rs-build.yml`).
  The Windows `.exe` is unsigned, so each archive gets SHA256SUMS lines and a build-provenance
  attestation.
- `apps/companion-rs/package.sh` packs each archive with its notices: the crates, the Rust standard
  library, zsign, OpenSSL, and zlib/minizip.
- CI's `companion-rs` job tests and builds it on Linux and Windows.
