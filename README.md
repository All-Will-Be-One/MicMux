# MicMux

**Many microphones. One clean input.**

MicMux is a standalone Mac and iPhone microphone multiplexer. The Mac opens several
Core Audio inputs at once while the iPhone can contribute its active microphone route
(including AirPods Pro or Bluetooth smart glasses) over an authenticated iroh link.
MicMux displays an independent rolling waveform and quality estimate for each source,
then forwards a selected or blended stream to a stable output such as BlackHole.
Receiving applications never need to switch microphones.

MicMux has no Jarvis or BtrVoice dependency. It records and saves no audio.

## Current prototype

- Simultaneous input-only AUHAL capture from unrelated Mac hardware devices
- Per-source waveform, level, SNR, voice activity, and quality score
- Automatic selection with a sustained-quality margin to prevent rapid flapping
- Manual pinning and immediate failover when a device stops delivering audio
- Quality-weighted **Blend** mode with clock normalization and soft limiting
- MicMux Phone for iPhone, AirPods, wired/USB headsets, and Bluetooth HFP glasses
- Authenticated iroh transport with direct LAN paths and relay fallback
- Optional adaptive speaker-echo subtraction from a separate loopback reference
- Opt-in monitoring of the processed signal through a separate physical output
- A menu-bar control for Start/Stop, selection mode, monitoring, and reopening the window
- A cross-copy process lock and single-window scene so only one MicMux instance runs
- App-specific Core Audio output selection, with BlackHole selected by default
- Virtual inputs disabled by default and source-to-sink cycles refused

Automatic mode favors the microphone with the strongest combination of voice level and
signal-to-noise ratio. Its visible metrics make wrong decisions diagnosable before more
advanced ranking is introduced.

## Build

Requires macOS 15 or newer and Swift 6 / Xcode 16 or newer. The iPhone app targets iOS
17.5 or newer.

```bash
./build.sh
open build/MicMux.app
```

Use `./build.sh --debug` for a debug Mac app, or `./build.sh --run` to build and open it.
Run all policy, DSP, wire-format, and local iroh integration tests with:

```bash
swift test
```

Build the iPhone companion for the simulator with:

```bash
./build-ios.sh --simulator
```

When a phone is connected and trusted, list it with `xcrun devicectl list devices`, then
build and install with `./build-ios.sh --install DEVICE_ID`. The Xcode project uses the
local Apple Development team in `iOS/project.yml`; change `DEVELOPMENT_TEAM` when another
developer builds the project.

The first capture asks for microphone access. Ad-hoc Mac builds may be treated as a new
application after substantial changes. Set `MICMUX_SIGNING_IDENTITY` to a stable
Developer ID or local signing identity when needed.

## BlackHole routing

1. Install BlackHole 2ch.
2. Choose **BlackHole 2ch** under MicMux Output.
3. Start MicMux and confirm one source is marked **ACTIVE**.
4. In Zoom, Discord, a dictation application, or another receiver, choose
   **BlackHole 2ch** as its microphone.

MicMux writes only its selected or blended mono voice stream to BlackHole. It never
changes system defaults. BlackHole is disabled as a regular MicMux input when it is the
selected sink, preventing a feedback loop.

## iPhone, AirPods, and smart glasses

1. Open MicMux on the Mac and wait for the pairing QR code.
2. Open MicMux Phone, scan the QR code (or copy/paste it with Universal Clipboard), and
   tap **Find iPhone, AirPods & glasses**.
3. Pair the headset in iOS first, choose its microphone route, and tap **Start streaming**.
4. The route appears under **iPhone & wearables** on the Mac and participates in Auto,
   Pinned, or Blend mode like a local microphone.

iOS exposes only one active input route to an application. The companion can switch
between the iPhone, AirPods, Meta Ray-Bans, and other HFP headsets, but it cannot record
all of those phone routes simultaneously. Selecting a Bluetooth HFP microphone also
makes that headset the iOS output route. On iOS 26, MicMux offers full-bandwidth AirPods
recording as an option; Apple documents that mode as higher latency, so it is off by
default.

Meta's public iOS CameraAccess sample uses this same AVAudioSession HFP route rather than
a proprietary raw microphone-array stream. MicMux therefore does not require the Meta
Device Access Toolkit, a Meta account, or camera permissions merely to use the glasses
as a microphone.

The pairing QR contains the Mac's iroh endpoint ticket and a 256-bit secret. Iroh
authenticates the Mac endpoint key; MicMux then authenticates the phone on a reliable
control stream before accepting audio datagrams. The Mac identity is stored with `0600`
permissions and the phone invitation is stored in the iOS Keychain.

## Blend and speaker echo removal

**Blend** is safer than a raw sum. MicMux resamples each clock to 48 kHz, buffers each
source, gives clearer voiced microphones more weight, normalizes the weights, and
soft-limits the result. Widely spaced microphones still have different acoustic arrival
times, so Blend may sound roomier than Auto; Auto remains the best default for dictation.

For speaker echo removal, feed Mac system playback into a virtual loopback source and
choose it under **Processing › Mac speaker reference**. A typical Audio MIDI Setup graph
uses a Multi-Output Device containing MacBook Speakers plus one BlackHole device. Use a
different BlackHole device as MicMux's final output—the same virtual device cannot safely
be both reference and sink. Adjust the reference delay until subtraction is strongest;
the adaptive normalized-LMS filter then learns the loudspeaker path. This is useful but
not equivalent to Apple's hardware-integrated VoiceProcessingIO, especially when the
reference clock or acoustic delay moves.

For cancellation checks, choose a physical device under **Monitor (test)**. Monitoring
receives the same post-selection, post-blend, post-cancellation signal sent to the stable
sink, using an independent bounded sample pipe so neither output consumes the other's
audio. Keep monitoring off by default and prefer headphones; playing a live microphone
back through open speakers can create an acoustic feedback loop.

## Architecture

```text
Mac Core Audio ─▶ per-source AUHAL ─┐
                                    ├─▶ 48 kHz queues ─▶ Auto / Pin / Blend ─▶ echo filter ─▶ stable sink
iPhone route ─▶ PCM16 ─▶ iroh QUIC ─┘                                      ▲                 └─▶ BlackHole
                                                                            │
system playback ─▶ separate loopback reference ─────────────────────────────┘
```
