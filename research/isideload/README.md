# isideload: provisioning without Xcode

Can the [isideload](https://github.com/nab138/isideload) crate (MIT, iloader's) replace Xcode for
Slashplayed's provisioning, so that a Windows or Linux host tool can be built on it? Today the companion
signs in through Xcode's accounts and gets its profiles from a stub `xcodebuild -allowProvisioningUpdates`
(`apps/companion/Sources/Signing.swift`, `apps/client/signing/`). This spike does each of those steps on
the Mac with isideload instead. It then signs a no-image device app with zsign using the results,
installs it, and checks that the on-device JIT helper still starts.

**Answer: yes, on iPhone, with a free team and a paid team.** isideload's sign-in, developer-services calls,
and identity export are enough for the whole chain. One separate problem turned up on the free team: the
device's own signature on a game image was refused there, because the launcher signs images with an
identifier a free team's (local) profile can't match. Signing them with the app's bundle ID makes them
load. The launcher now does that ([The JIT helper](#the-jit-helper-open-question-1)). Its high-level `Sideloader` is not, and the host should
call the lower-level API as this spike does (see [What the host CLI should take](#what-the-host-cli-should-take)).
Two outside facts also shape the host tool:

- Apple has been rejecting anisette from the Android-based servers since mid-October 2026.
- The crate pulls in an LGPL signer.

Run on 2026-11-01 on an iPhone 16 Pro (iOS 27), from macOS with Rust 1.99.0.

## What's here

- `src/`: `spisideload`, the CLI. Every command writes a JSON report (`--report`), so a run the owner does in
  their own Terminal leaves something to read. Reports never contain a token, anisette value, key,
  password, or the size of one. They do contain Apple IDs, team IDs, and UDIDs, so they belong in a scratch
  folder and are never committed.
  - `login --apple-id <id> [--anisette <url>] [--server-client-info]`: the owner's step. It reads the
    password from the terminal with no echo (never argv, the environment, or a file), handles 2FA
    (trusted device or SMS), and keeps the session in the login Keychain. More under
    [Credentials](#credentials).
  - `teams`: lists teams from the stored session.
  - `provision --team <id> [--udid <udid>] --free|--paid [--create-app-ids] [--create-cert]
    [--profiles-only] --out <dir> [--identity <dir>]`: steps 2–8 below. It makes App IDs or a certificate
    only when the flag allows it, and it never revokes. `--profiles-only` skips the certificate step, for
    [the profile-only refresh](#profile-only-refresh-step-4): a team profile lists all of the team's
    certificates, so it works even when the spike's own certificate has been revoked.
  - `sign-quick`: signs a built app with isideload's own signer, apple-codesign-quick, for the
    comparison.
  - `check-session`: the token-lifetime probe (see [Token lifetime](#token-lifetime)).
  - `forget`: deletes the stored login.
- `build.sh`: builds the CLI with the pinned Rust and the committed `Cargo.lock`. It also builds zsign's
  command-line signer from the source `scripts/build-zsign.sh` pinned and patched, linked to that script's
  macOS OpenSSL. It needs `scripts/build-zsign.sh macos` first. With `SP_SIGN_ID` set, it signs the CLI
  with a fixed identifier, which keeps the Keychain item readable across rebuilds.
- `sign-install.sh`: one end-to-end run on a device:
  1. `provision` (which only reuses what exists).
  2. `SP_NO_IMAGES=1 apps/client/build.sh` under the spike bundle ID, signed ad hoc.
  3. zsign (or `SPIKE_SIGNER=quick`) with the downloaded profiles and the fresh identity.
  4. `devicectl` install, then launch to the start screen.
  5. Optionally, push the identity (`SPIKE_PUSH_IDENTITY=1`, through `apps/client/push-identity.sh`).
  6. Optionally, copy an installed Slashplayed's `Library/sppairing.plist` (`SPIKE_PAIRING_FROM`) for the
     helper test.

  The identity and the record pass through a private `mktemp` folder and are deleted with `rm -P`.
- `check-session-agent.sh install <apple-id>... | remove`: a user LaunchAgent that runs `check-session`
  daily.

The app is `<team>.slashplayed.spike`, and its helper is `<team>.slashplayed.spike.helper`. That keeps the
real install's App IDs, profiles, and data container untouched. The record copy only reads the real
install.

## Running it

```sh
scripts/build-zsign.sh macos
research/isideload/build.sh
work/isideload/spisideload login --apple-id <id> --report $SCRATCH/login.json      # the owner, in Terminal
work/isideload/spisideload provision --apple-id <id> --team <team> --udid <udid> --free \
  --create-app-ids --create-cert --out $SCRATCH/profiles --report $SCRATCH/provision.json   # once
SP_DEVICE=<udid> SPIKE_APPLE_ID=<id> SPIKE_TEAM=<team> SPIKE_KIND=free SPIKE_OUT=$SCRATCH/run \
  SPIKE_PUSH_IDENTITY=1 SPIKE_PAIRING_FROM=<installed Slashplayed bundle ID> research/isideload/sign-install.sh
```

Then launch a game for the helper, as `apps/client/run.sh` does, with `SP_BUNDLE_ID` set to the spike's.
That needs a Battle.net sign-in in the spike app, because the helper runs after it.

To clean up:

- `spisideload forget --apple-id <id>` for each Apple ID.
- `check-session-agent.sh remove`.
- Delete the spike app from the device.
- The App IDs (`<team>.slashplayed.spike[.helper]`) and the "Slashplayed spike" certificates stay on the
  teams. On a paid team, delete or revoke them in the developer portal if you want. On a free team they
  lapse by themselves.

## Findings, step by step

| Step | Free team | Paid team |
|---|---|---|
| 1. Sign-in (GSA, SRP, 2FA, remote anisette) | Works (SMS 2FA), after the anisette fix below | Works (trusted-device 2FA) |
| 2. Teams | Works. One team, type `Individual` | Works. Two teams: the account's personal team (`Individual`) and the company team (`Company/Organization`) |
| 3. Register the device (UDID over USB through usbmuxd, name from lockdown before any session) | Registered (the team's first device) | Already registered; nothing done |
| 4. Find or create the App IDs | Both created. `availableQuantity` went 9 → 7 of 10 | Both created (no quantity limit reported) |
| 5. Capabilities | increased-memory-limit, through isideload's `add_increased_memory_limit` | IML and extended-virtual-addressing in one v1 `bundleIds` PATCH (the spike's own call: isideload has no EVA) |
| 6. Development certificate, with a key the harness made | Created. The team then had 2: Xcode's from this Mac, and ours | Created; 6 on the team |
| 7. Profiles (app and helper) | 7 days, `IsFreeProvisioningProfile`. App: IML, no EVA. Helper: no memory entitlements. Both list the device and our certificate | 365 days. App: IML and EVA. Helper: none. Both list the device and our certificate |
| 8. `.p12` for the push path | Written 0600, pushed, imported by the launcher ("listed in the app's profiles"), deleted. The launcher signed a game image with it, but dyld refused that image (below) | Same. The launcher then installed Classic Era on the device, signing the image with this identity, and it loads |
| 9. zsign-signed no-image app installs and launches | Yes, after **Trust** in Settings > General > VPN & Device Management (as for any free-team app) | Yes |
| 9. JIT helper starts (open question 1) | **Yes**: status, then attached 1.66 s after launch. But dyld then refused the game image the device had signed, because of its signing identifier (below; fixed since in the launcher) | **Yes**, under both signers (below) |

Details worth keeping:

- **listTeams has no "free" flag.** A free Personal Team's `type` is `Individual`, the same as a paid
  individual team. Only the profile tells them apart: a 7-day lifetime, `IsFreeProvisioningProfile`, or
  Apple refusing EVA. The harness takes `--free`/`--paid`, and the host CLI should make one stub profile
  first and decide from it, as `Signing.verifyTeam` does.
- **The certificates are "iOS Development: …"**, not "Apple Development". QH65B2's
  `submitDevelopmentCSR` makes the old kind. Their subject is
  `CN=iPhone Developer: <name> (<id>), OU=<team>`, valid one year. The launcher's `spsign.m` and the
  profiles accept them like Xcode's.
- **The profiles carry more entitlements than Slashplayed's templates:** `keychain-access-groups` `<team>.*`,
  plus `com.apple.token` on the paid team. zsign and apple-codesign-quick both sign each bundle with its own
  profile's entitlements, so these end up in the signature. That's harmless, but the host could sign with
  the templates (`apps/client/entitlements.plist`, minus `Signing.freeTeamDropped` on a free team) to
  match the Mac. That needs zsign run per bundle, because zsign's `-e` applies one file to every bundle.
- **The profiles list the platforms iOS, xrOS, and visionOS.** isideload's `DeveloperDeviceType` has no
  visionOS, but its default URL segment is `ios/`, and the profile it gets back already covers the
  headset. Registering a visionOS UDID is still untested (handoff open question 5).
- **The free team allows 10 App IDs a week.** Slashplayed takes 2 of them. A device can hold 3 free-team
  apps, and the helper doesn't count as one of them.
- **No revoke, anywhere.** isideload's `Sideloader` revokes on the certificate limit
  (`MaxCertsBehavior::Revoke`/`Prompt`, result code 7460). The harness calls `submit_development_csr`
  itself and stops with a message at 7460. The key is stored before the request goes out, so a crash
  can't waste a certificate slot.
- **App IDs are reused.** The second and later runs found both App IDs and the certificate (matched by
  public key) and made nothing.

### The JIT helper (open question 1)

On the paid team, with the iPhone's RemotePairing record copied from the real install and LocalDevVPN on,
launching Classic Era in the spike app showed the following for both the apple-codesign-quick build and
the zsign build:

- Status: the tunnel came up through `10.7.0.1:49152` in 0.25 s. TXM, and the disk image was already
  mounted, so no mount was needed.
- Attach: about 1.1 s.
- Prepare: 2,817 pages, 0 failed, read back OK.
- Detach, then the client ran.

So a profile made outside Xcode, an extension signed by zsign or apple-codesign-quick, and an identity from
isideload together give a helper that starts and does its job.

On the **free team** the helper did the same: tunnel, status, and attach 1.66 s after the launch. The
launch then stopped before the prepare. The launcher had installed Classic Era on the device a moment
earlier, signing the image with the free team's identity in 0.2 s, and its own check found the
certificate listed in the app's profiles. dyld still refused the image:
`code signature invalid … (errno=1)`. The launcher deleted it, as it does for any image that won't
load. The paid team's identical chain loads.

So **as the launcher signs it today, a game image signed on the device with a free team's certificate
doesn't load.** That was the untested case in
[Loading and signing images on the device](../../docs/research.md#loading-and-signing-images-on-the-device-2026-10-24).
It isn't isideload's doing, and a small launcher change fixes it.

**Diagnosis.** The iPhone's syslog, relayed with idevice's `syslog_relay` at the repo's pinned commit,
gives AMFI's reason:

```
amfid(libmis): Local Profile '<private>' has non-matching application-identifier.   (once per free profile)
amfid: …/Library/spgames/wow-classic_era not valid: AppleMobileFileIntegrityError -415
       "The best matching profile does not match the entitlements of this file"
```

- A free team's profiles are *local* profiles (`LocalProvision`). For a binary from outside the app
  bundle, amfid only considers a local profile whose application-identifier matches
  `<team>.<the code signature's identifier>`.
- The launcher signs the image with the identifier `wow-<flavor>` (`sppatch.m` passes the file's name
  to `sp_sign_with_identity`), so it matches none of them.
- A paid team's profiles aren't local. amfid picks one by certificate and device ("was picked for
  validation", "profile provisions developer certificate"), with no identifier check. That's why the
  paid team loads the same image.

**The checks, in the free spike app only:**

1. **Trust order.** Reinstalled after the developer was trusted, identity pushed again, image installed
   and signed again: refused the same way. Ruled out.
2. **Entitlements in the image** (an experimental zsign, built only in a scratch folder, giving the
   non-executable an application-identifier):
   - The kernel refused it: "has entitlements but is not a main binary", as `scripts/zsign.patch`'s
     comment says.
   - The local profiles still didn't match.
   - Ruled out.
3. **Signing identifier set to the app's bundle ID**, no entitlements, same experimental zsign through
   an override:
   - "selected profile", "profile provisions developer certificate", "profile validated the code
     signature".
   - **The image loaded** ("loaded the updated (Library/spgames) image"), the same way the paid team's
     does. That was with the isideload-made certificate.
   - So the A/B against Xcode's free-team identity wasn't needed: the certificate was never the problem.

**The fix (made after the spike).** The launcher signs every image it signs on the device as the app's
own bundle ID (`NSBundle.mainBundle.bundleIdentifier`): `sp_sign_with_identity` takes no identifier, so
no caller (`sppatch.m`'s install and update, `launcher.m`'s re-sign and `SP_SIGN_TEST`) can choose
another. Still no entitlements blob, as `zsign.patch` requires. The companion's `DeviceSigningTests`
check that the signer keeps the identifier it's given, and that `<team>.<it>` is the profile's
application-identifier. Checked on the iPhone with both spike apps, rebuilt with it and their image's
stamp emptied so the launcher installed and signed Classic Era again: on the free team amfid "selected
profile" with no "non-matching application-identifier", the image (identifier
`<free team>.slashplayed.spike`) loaded, and the helper prepared it; on the paid team the same.

Both runs later stopped with the client's `Invalid schema WOWSTATIC_5_5_4_67732 for Table StartupFiles`.
That's game data, not signing:

- The spike's container was empty before the run. The no-image install fetched the image and configs, and
  the client streamed the store itself.
- There was no `Documents/.build.info`. The launcher logs "the game data's .build.info has no
  wow_classic_era row".
- The schema named isn't Classic Era's build.

The step 1 test in the handoff reached character select only because the real container already held the
Mac's data. A host that ships no game data starts in exactly this state, so the launcher's no-image
install has to write `.build.info` (or finish the store) before the first start. This is related to
issue #34 but is a separate bug.

## Anisette

The first sign-in failed with GSA `-80045` ("This action cannot be completed at this time") at SRP init,
before the password is checked. The cause wasn't the account:

- Since about 2026-10-12, Apple refuses anisette whose machine doesn't match the `X-Mme-Client-Info` sent
  with it ([anisette-v3-server#61](https://github.com/Dadoum/anisette-v3-server/issues/61); iloader
  #928, #965, #1100; SideStore #1652, #1658).
- The common servers (`ani.sidestore.io`, `ani.stikstore.app`, `ani.jkcoxson.com`) generate it with Apple's
  Android ADI code. `ani.sidestore.io` also reports a different, outdated client identity (macOS 13.1)
  from the Mac-backed servers. iloader has dropped all of the Android servers.
- iloader 2.4.1 uses servers backed by Apple's Mac ADI: `mac-ani.jkcoxson.com` (its default),
  `ani.iloader.app`, `new.ani.sidestore.io`, and `ani3.stikstore.app`.
- iloader 2.4.1 also overrides the client identity with a newer Mac's (`<Mac15,7> <macOS;27.0;26A5378j>`,
  user agent `akd/1.0 CFNetwork/811.5.4`). This works "while waiting for the anisette servers to update",
  and it also fixes SMS 2FA 403s.

The harness now defaults to `mac-ani.jkcoxson.com` with that override. Both accounts then signed in on the
first try. The choice is kept with the login, because later requests must claim the same machine.
`--anisette <url>` takes any v3 server, including a self-hosted one; isideload supports this
(`RemoteV3AnisetteProvider::new`/`set_url`, `set_client_info_override`). One caveat, reported in iloader
#1093: a self-hosted *stock* anisette-v3-server is currently refused whatever identity is sent. "Support a
self-hosted server" therefore means one running Apple's Mac (or Windows) ADI, and nobody has published a
recipe for that yet. Expect this area to keep moving; Apple changed it twice in October.

## Credentials

- **The password** is read from `/dev/tty` with no echo (rpassword). It's held in a `Zeroizing` buffer for
  the one `login` call. isideload takes it as `&str`, and its SRP code keeps copies it doesn't zero; that
  should be fixed upstream.
- **What's kept**, one generic-password item per Apple ID in the login Keychain (service
  `com.strawdynamics.slashplayed.spike.isideload`, `src/store.rs`), as a binary plist:
  - the anisette provisioning state;
  - the four SPD fields that mint app tokens (`adsid`, `GsIdmsToken`, `sk`, `c`);
  - the `xcode.auth` token from login, with its stated expiry;
  - the certificate's RSA key.

  None of it is printed or logged, not even sizes. `forget` deletes it.
- **Why the login keychain:** it's the legacy file keychain, which never syncs to iCloud. The
  data-protection keychain's `…ThisDeviceOnly` classes need an entitlement that an unsigned CLI can't
  have. The item's ACL trusts the CLI's designated requirement: a fixed identifier plus the Apple
  Development certificate, so rebuilding needs no new approval. An ad hoc build would get a prompt
  after every rebuild.
- **The identity files** (`spidentity.p12`/`.pass` for the push, `key.pem`/`cert.pem` for zsign, so no
  password goes on its command line) are created 0600 with `create_new` in a 0700 `mktemp` folder.
  `sign-install.sh` overwrites and deletes them on exit. isideload's p12 writer
  (`CertificateIdentity::as_p12`) produces a file the launcher's `SecPKCS12Import` accepts.
- **The RemotePairing record** is copied device → 0600 file → device, never read, and deleted with
  `rm -P`. Only its size is logged.

## Tracing audit

isideload logs through `tracing`. The harness installs no subscriber, so none of the following reaches any
output. If a host turns logging on, this is what each level would leak:

- **debug:**
  - `anisette/remote_v3`: "Received provisioning message: {text}". These are the provisioning websocket's
    raw messages, which are anisette provisioning data. **Must stay off.**
  - `auth/apple_account`: the trusted phone numbers (Apple masks them except the last two digits), the SRP
    protocol and iteration count, and step markers. No tokens.
- **info:** `censor_email` masks the Apple ID ("Logging in to Apple ID: f***e@…"), unless
  `DEBUG_SENSITIVE` is set, in which case it's printed in full. Otherwise only progress messages.
- **warn/error:**
  - Apple's `userString`/`resultString` on developer errors.
  - 2FA error titles.
  - `cert_identity`'s p12 failure, which logs the certificate subject (the person's name and team) and
    the password's *length*.
  - The trusted-numbers failure, which can include Apple's response body.
- **Errors (rootcause reports)** carry attachments:
  - `SensitivePlistAttachment` hides whole response plists unless `DEBUG_SENSITIVE` is set, and then it
    prints everything, the SPD's tokens included.
  - GrandSlam parse failures attach the raw response text.

  The harness clears `DEBUG_SENSITIVE` before anything runs, and prints errors as their chain of contexts
  only, never attachments (`safe_error`).
- **Debug impls:** `AnisetteData` derives `Debug` over its one-time password and machine ID, and
  `AppToken` derives `Debug` over the token. Formatting either with `{:?}` leaks it. isideload doesn't do
  so itself, but a host must not either.

For the host: no subscriber at debug, filter the crate to `warn`, keep the `DEBUG_SENSITIVE` and
attachment rules, and treat `AnisetteData`/`AppToken` as secrets in its own code.

## Token lifetime

At login, Apple states a `duration` of 31,536,000 s (365 days) for the `com.apple.gs.xcode.auth` token, on
both accounts. That's the claim to measure. `check-session` asks two questions:

1. Does the stored `xcode.auth` token from login still work for `listTeams`?
2. Can the stored GS token still mint a fresh `xcode.auth` token, which then works?

It appends one line per account per run: outcomes and Apple's error codes, never a token. The LaunchAgent
runs it daily at 09:17 into `~/Library/Logs/Slashplayed/spike-check-session.jsonl`. On day 0 both answers
were yes for both accounts, about 15 minutes after login.

About 1.2 hours after login, the second answer turned to no on both Apple IDs (free and paid): minting a
new `xcode.auth` token from the stored GS token fails with GrandSlam -22411, while the token login stored
still works for `listTeams`. So the GS token's own lifetime is short, whatever the 365 days stated for
the `xcode.auth` token it mints. `provision` now falls back to the stored token when the mint fails (its
`session` step says which it used), so the spike can still provision.

A host that holds the login in memory (below) mints within minutes of the login, so this doesn't touch it.
It answers the question below for the GS token: a device can't count on it to refresh its own profile
later. What's left open is the stored `xcode.auth` token, whether it really lasts its stated year.

That decides part of an owner question. A device could refresh its own free-team profile (order step 4)
from a stored session, with no password stored, only on a token that lasts a week: the GS token doesn't, so
that leaves the stored `xcode.auth` token, or the owner's choice between storing the password and asking
again. Read the log after a week or two, record the answer here, and remove the agent
(`check-session-agent.sh remove`).

## Profile-only refresh (step 4)

The question: can a device renew a free-team app by installing a new profile alone, without re-signing or
reinstalling itself? It can. Checked 2026-11-02 on the iPhone 16 Pro (iOS 27.0.1), with the free spike
(`<free team>.slashplayed.spike`, installed by `slashplayed-companion`), from the Mac with idevice's
`misagent` tool (`work/idevice/src/tools`, `idevice-tools misagent list|remove|install`):

1. `provision --free --profiles-only` got new app and helper profiles, about 1.1 days after login. Minting
   from the GS token failed (-22411), and the stored `xcode.auth` token worked.
2. Every installed profile for the spike's app and helper was removed through misagent, including the
   one embedded in the app. The launch then failed: FBSOpenApplicationErrorDomain error 3, "invalid code
   signature, inadequate entitlements or its profile has not been explicitly trusted". iOS showed "Slashplayed
   is no longer available".
3. Only the two new profiles were installed, with UUIDs different from the embedded one's. The app launched.
   After the dialog was dismissed, the JIT helper ran and Classic Era, with its device-signed image,
   reached character select.

So iOS checks an app against the installed profiles, not the one in its bundle. A refresh is: new profiles
from Apple, then misagent install. It doesn't need a new certificate either: the free team's
certificates last a year (each one's notAfter is a year after its notBefore), so the `.p12` already on the
device covers a year of weekly refreshes.

Also seen: every install adds its profiles to the device and none are removed. The iPhone had 11 for the
free spike's app alone, all still valid. A refresh needn't remove old ones, since they expire. Installing
the new one first means the app is never without a valid profile, and the dialog above never shows.

The device can do the install itself: jittest's `h5` had the helper install a fresh profile through
misagent over its own tunnel (`com.apple.misagent.shim.remote` over RSD) in 0.08 s
([research/jittest](../jittest/README.md#results)).

## The idevice pin

`[patch.crates-io] idevice = { git, rev = d32c818 }` works. isideload asks for `idevice ^0.1.61` from
crates.io, and the lock holds a single idevice, 0.1.68 at the repo's pinned commit, shared by isideload and
the harness. The sources Cargo fetched are identical to `work/idevice/src` (`diff -r`), and isideload's
fetched source is identical to the clone that was read.

isideload can't build without idevice. Its `lib.rs` names `idevice::IdeviceError` whatever its features
are, so its `install` feature (idevice with `afc`, `installation_proxy`, `remote_pairing`, `rsd`) has to
stay on. `keyring-storage` is off. `tokio-mt` is needed for the anisette websocket.

## Signers

Both signed the same no-image build with the same profiles and identity. Both builds verify
(`codesign --verify --deep --strict`), install, launch, and let the helper attach. Neither needs a Mac,
and both take a key in memory or as a file.

| | zsign (repo's pin and patch) | apple-codesign-quick 0.1.0 (isideload's) |
|---|---|---|
| Time for this app | under 1 s | 0.04 s |
| Per-bundle profiles and entitlements | Yes (`-m` per profile, matched on application-identifier). `-e` is all-or-nothing | Yes (`entitlements_by_bundle_id`) |
| Rewrites Info.plist | No | Yes, as a binary plist |
| Already on the device | Yes: the launcher signs game images with it (`spsign.m`) | No |
| License | MIT, plus OpenSSL (Apache-2.0) | **LGPL-2.1-or-later** |

zsign is the better choice for the host. It's the code the device already runs, it builds for Windows and
Linux, and it carries no LGPL. isideload depends on apple-codesign-quick unconditionally, though, so a
binary linking isideload links LGPL code even if it never calls the signer. A shipped host must then let
users relink it, for example by distributing objects or using dynamic linking. Alternatively, it can patch
the dependency out: the signer is used only by `sideload::sign`, which a host using the low-level API never
calls. This needs an owner decision before step 3.

## Gaps against plume_core

isideload covered every step. Where it fell short, the spike used its public pieces, so nothing needed
plume_core.

- **Capabilities:** isideload can send only INCREASED_MEMORY_LIMIT. The EVA PATCH is the spike's
  (`enable_capabilities`), built on isideload's `get_headers` and GrandSlam client. plume_core has
  `v1_list_capabilities` and `v1_request_capabilities_for_entitlements`, which map entitlements to
  capabilities generically.
- **The high-level `Sideloader` doesn't fit Slashplayed:**
  - It turns on app groups and assigns one to every App ID.
  - It can revoke certificates.
  - It installs over its own path.

  The host should use the API underneath it (`DevelopmentCertificate`, `AppIdsApi`, `DevicesApi`), as
  this spike does.
- **Free/paid detection:** neither crate has it from listTeams; it comes from the profile.
- **Team-limit errors:** isideload's certificate-request loop retries silently on errors that aren't
  developer errors, up to 4 times. The harness doesn't use that loop.
- **visionOS device type:** missing in isideload. It's untested whether plume_core's works for a headset
  UDID.

## What the host CLI should take

For order step 3:

- isideload's `AppleAccount` (sign-in, 2FA callbacks), `RemoteV3AnisetteProvider` with a
  user-selectable URL and the client-identity override, and `DeveloperSession` with its
  teams/devices/App IDs/certificates/profiles traits, pinned to a commit.
- This spike's rules:
  - Find App IDs, and create them only when missing and within `availableQuantity`.
  - Never revoke.
  - Store the key before the CSR.
  - Match our certificate by public key.
  - Treat free vs paid as a profile question.
  - One v1 PATCH for all capabilities.
- The host holds the login in memory only (owner decision). It mints `xcode.auth` once per run.
- zsign for signing. For the LGPL question, see [Signers](#signers).
- The tracing and error rules from [Tracing audit](#tracing-audit).
- The `.build.info` launcher fix above, before anyone installs into an empty container.

For order step 4, the device refreshing its own profile: the device needs what `store.rs` keeps:

- the anisette state;
- the four SPD fields;
- the certificate's key, which it already has inside the pushed `.p12`.

These would go in the device keychain, this device only, owned by one file, as `splogin.m` does for
Battle.net. Each refresh is then a mint plus `downloadTeamProvisioningProfile` for the two App IDs. Whether
that works for longer than a week is what the token-lifetime log will show.
