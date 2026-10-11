# Basketball Shot Tracker for iPhone

A phone on a tripod watches someone shoot and calls every shot **MADE** or **MISSED**, live, on the phone.
Native Swift (SwiftUI, AVFoundation, Core ML), built and installed from Windows with
[xtool](https://github.com/xtool-org/xtool). The detector, tracker and shot rules come from the research repo,
[Basketball-Shot-Tracker](https://github.com/NathanielRecto/Basketball-Shot-Tracker), where they are trained and
evaluated (85.6% end-to-end on a first-look test in an unseen gym, offline).

**Status:** runs live on an iPhone 11. Live accuracy on the phone is **not measured yet**; that needs new test
footage recorded through the app.

## What it does

- 0.5x ultra-wide camera at 1080p / 60 fps, in landscape (sideline tripod, like the research footage).
- Detector v2 (YOLOv8s) in Core ML at about **28 frames per second** on an iPhone 11 (model 35 ms; the next
  frame is letterboxed while the Neural Engine runs the current one).
- Finds the hoop by itself: the biggest rim the detector sees (the nearest hoop) plus its net, over the last
  ~1.6 s; it follows the rim between shots if the phone moves.
- The ported tracker and shot judge turn every detector frame into MADE / MISSED, with the reason ("through the
  hoop", "off the rim", "fell past the rim", ...) and a running count.
- **Boxes** button: show or hide the detector boxes, hoop, tracked ball and the speed readout.

## Checked against the research code

| | How | Result |
|---|---|---|
| Detector | `Check` button: the app's detector on 24 dev frames vs PyTorch's detections on the same PNGs | fp32: identical (IoU 1.000, 0.0 px); fp16 (used live): all 60 boxes matched, IoU mean 0.988, conf within 0.013, corners within 0.7 px |
| Tracker + shot judge | `swift test`: golden cases exported by the Python repo (`scripts/export_app_fixtures.py`, commit `c2ded21`), compared exactly as doubles | Identical on 4 cases: 33,386 frames, 123 shot calls and every decision-log line, incl. one replayed at the phone's frame rate |
| Settings | `swift test`: Python's `params.json` vs the Swift defaults | Same values, same keys |

The research repo's [RESULTS §13](https://github.com/NathanielRecto/Basketball-Shot-Tracker/blob/main/docs/RESULTS.md#13-on-the-iphone-frame-rate-detector-match-and-the-swift-port-october-2026)
has the details, including how the phone's lower frame rate (every 2nd-3rd camera frame) was measured and fixed
on dev footage.

## Layout

```
Packages/ShotCore/          pure Swift, no Apple frameworks: `swift test` runs on Linux / WSL
  Sources/ShotCore/         letterbox, YOLO decode + per-class NMS, exact 2x2 resize, parity matching,
                            and the port: Flight (arc fit), Tracking, ShotLogic, Pipeline, HoopFinder, Config
  Tests/ShotCoreTests/      unit tests + GoldenTests (Fixtures/: detections only, no images)
Sources/ShotTracker/        the app: CameraController, Detector (Core ML, two stages), ShotSession,
                            LiveView, ParityCheck
Resources/                  local only (gitignored): the Core ML model and, optionally, parity frames
scripts/sync_model.sh       copies them in from ../Python_Raw/exports
```

## Build and run (Windows)

One-time setup, following xtool's
[Linux / WSL guide](https://github.com/xtool-org/xtool/blob/main/Documentation/xtool.docc/Installation-Linux.md):

1. WSL with Ubuntu; in it, Swift 6.4 ([swiftly](https://swift.org/install/linux)), its packages, `usbmuxd`,
   `libimobiledevice-utils`, and the xtool AppImage on the PATH.
2. `xtool setup`: sign in with an Apple ID (free accounts work; xtool suggests a separate Apple ID), and give it
   the path to `Xcode.xip` so it builds the iOS SDK.
3. iPhone connection: usbipd's USB pass-through broke large transfers here (installs timed out), so the phone
   connects through Windows instead. Install **Apple Devices** from the Microsoft Store; allow TCP 27015 inbound on
   the `vEthernet (WSL)` adapter; forward it with
   `netsh interface portproxy set v4tov4 listenport=27015 listenaddress=<WSL gateway IP> connectport=27015 connectaddress=127.0.0.1`
   (admin); and in Ubuntu
   `export USBMUXD_SOCKET_ADDRESS="$(ip route list default | awk '{print $3}'):27015"`
   (in `~/.profile`). Re-run the `netsh` line if `xtool devices` comes up empty after a reboot.
4. On the iPhone: Developer Mode on, then trust the developer certificate (Settings > General > VPN & Device
   Management).

The model (not in git, like the research repo's weights):

```bash
cd ../Python_Raw && ~/coreml-env/bin/python scripts/export_coreml.py                       # WSL: coremltools has no Windows wheels
~/coreml-env/bin/python scripts/export_coreml.py --quantize 32 --name DetectorV2_fp32     # optional, for the parity check
python scripts/export_parity_frames.py                                                     # optional, dev frames only
cd ../iOS && scripts/sync_model.sh
```

Then, in Ubuntu from this folder:

```bash
xtool dev run -c release     # build, sign, install on the phone
cd Packages/ShotCore && swift test
```

The phone compiles the model once on first launch (no Mac to compile it at build time) and caches it.

## Limits

- Free Apple ID signing: the app stops opening after 7 days; reinstall with `xtool dev run -c release`.
- Tripod use is what the research measured. Following the rim helps a hand-held phone but lags it by ~1.5 s
  and has not been evaluated offline (every research result uses one fixed hoop per video).
- At ~20-28 fps, dev accuracy is 90-94% against 94.7% at 60 fps; the first gym (low camera, close to the hoop)
  loses the most.
