# Text input harness

The real AppKit shim in a UIKit simulator app, with an `NSTextInputClient` fixture of our own.
It uses no game code, account, signing key, pairing record, or network. Requires an Apple Silicon
Mac, Xcode, XcodeGen, and a bootable iOS simulator.

```sh
research/textinput/test.sh <simulator-UDID>
```

The replay checks pinch zoom direction and phases, parallel-pan arbitration, first-finger drag
anchoring, frozen-cursor camera deltas, double-tap dragging, gesture cancellation, and four-finger
priority over undecided pairs. It also checks native virtual-gamepad connection, simultaneous
floating sticks, dead zones,
long-press right-drag without a stray left click, Hold/Tap/Toggle button behavior, shared modifiers,
physical input ownership, saved custom buttons, and the native editor. It also checks mouse chords,
the four-finger gesture's cancellation and movement limits in both touch modes, held-key
release, native editor focus, Unicode and multiline commits, Return ordering, draft dismissal, and
the unchanged game viewport. It also checks that committed text never enters the input log. Results
and logs go to `build/textinput/`. The composer stays open for visual review after the checks pass.
CI runs the same replay on a fresh iPhone simulator after the companion tests.

The harness runs UIKit's normal event loop instead of starting the client coroutine. It feeds test
doubles through `SPInputView`'s actual touch handlers and drains the actual AppKit event queue into
the fixture. It does not prove that a particular game field accepts text; check that on a device.
Physical-controller coexistence and the game's choice of controller also need a device check.
Launch with `--touch-preview` to see two active sticks, or `--controls` to review the native editor.
