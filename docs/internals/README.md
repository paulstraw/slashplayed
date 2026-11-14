# Slashplayed internals

How each part of Slashplayed works, in detail: for contributors, maintainers, and agents changing the
code. [How Slashplayed works](../architecture.md) is the short overview, and [research.md](../research.md)
has the experiments behind each technique.

| Page | What it covers | Code |
|---|---|---|
| [The Mac companion](companion.md) | The pipeline from build to launch, entitlements and free teams, third-party licenses, and the game data the companion sends or copies | `apps/companion` |
| [The device app](device-app.md) | The launcher and each launch's steps, the start screen and Settings, build stamps and whether the Mac or the device is ahead, renewing the app's profiles, and updating and installing games, their region, and the addons on the device | `apps/client` |
| [Running the client](loading.md) | Executable memory under TXM, the on-device JIT helper and its pairing, and spguest, the loader | `apps/client/spguest*`, `spjit.m`, `helper/` |
| [The host tool](host-tool.md) | Setting up an iPad or iPhone from Windows, Linux, or a Mac without Xcode | `apps/companion-rs` |
| [The shims](shims.md) | The generated and hand-written shims, sandbox redirects, the event loop coroutine, window, input, audio, Metal, iPad and iPhone, heat, and logs | `shims/` |

A change that crosses pages, such as a new step in a launch or a new file in the app's container, goes
on the page that owns the flow, with a link from the others: a launch's steps are on the device app's
page, and what the helper and spguest do inside one on Running the client.
