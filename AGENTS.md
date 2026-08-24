# Notes for agents working on MicMux

## Commands

```bash
xcrun swift-format lint --strict --recursive Sources Tests Package.swift
swift test -Xswiftc -warnings-as-errors
./build.sh
plutil -lint build/MicMux.app/Contents/Info.plist
codesign --verify --deep --strict build/MicMux.app
./build-ios.sh --simulator
```

Do not start microphone capture during automated checks. Launching the app in its stopped
state is safe; live hardware verification requires the person at the Mac to press Start.
Do not start phone capture during automated checks either; route and lock-screen tests
require the person to tap Start streaming on the physical iPhone.

## Product boundaries

**MicMux is standalone.** It must not import, launch, or depend on Jarvis or BtrVoice.
Future integrations are ordinary Core Audio or documented source-provider boundaries.

**Never change system audio defaults.** All input and output selection is app-specific.
The user chooses MicMux's sink and separately chooses that virtual device in the receiving
application.

**A sink cannot be a source.** Refuse graph cycles, especially when a duplex virtual
device such as BlackHole appears in both lists. Virtual inputs remain disabled by default.

**Audio is ephemeral.** Raw samples live only in bounded memory buffers. Do not record,
log, upload, or persist audio unless a future feature makes that behavior explicit and
opt-in.

**The output device must remain stable while sources change.** Source selection happens
behind the sample pipe. A downstream conferencing or dictation application must never
need to reopen its microphone because MicMux selected a different source.

**Monitoring is opt-in and physically separate.** Never enable live monitoring by
default. Refuse virtual, sink, reference, and enabled-input devices as monitor targets,
fan out after processing so outputs do not consume one another, and warn that open
speakers can create acoustic feedback. Headphones are the safe comparison path.

**MicMux is one process and one window.** The project build and an installed copy share
the same per-user process lock. A second launch activates the primary instance and exits
before constructing the audio model. Keep menu-bar actions on that shared model; they
must not create another capture graph or start listening automatically.

**Audio callbacks stay bounded.** Do not perform file or network I/O, UI publication,
unbounded allocation, or expensive inference in Core Audio callbacks. Copy or render the
minimum data and move analysis onto the processing queue.

**Selection must not flap.** Automatic changes require a sustained quality advantage;
an unavailable active source fails over immediately. Keep manual pinning available and
make quality decisions observable in the interface.

**Remote audio is authenticated before ingestion.** The iroh endpoint identity secures
the connection and the private QR/paste secret gates the MicMux protocol. Never create a
datagram path that bypasses the reliable control handshake, and keep network work outside
Core Audio callbacks.

**One iOS audio session means one phone route.** AirPods, Meta glasses, USB, and the
iPhone microphones can be selected, but iOS exposes only one active route to an app at a
time. Do not imply that the phone can capture several Bluetooth microphones concurrently.
