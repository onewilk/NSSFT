# NSSFT: a native HarmonyOS receiver for SFT

[简体中文](README.zh-CN.md)

NSSFT receives the stream sent by the console side of [SFT](https://github.com/TomasUribe/switch-frame-tap) (over the network or USB) on HarmonyOS phones, tablets, PCs and TVs, at up to 1080p and 60 fps, with game sound.

> NSSFT is an independent third-party open-source project. It is not affiliated with, endorsed by or sponsored by the console maker or the author of SFT. NSSFT only receives and plays the SFT stream; it does not include or modify any software on the console.

## Features

- **Discovery**: consoles that broadcast on the local network are listed automatically, or enter an address; consoles you have used stay on the home screen and can be renamed.
- **Up to 1080p60**: the hardware decoder is configured from the size the console sends and rebuilt when it switches between 720p and 1080p.
- **USB**: with SFT set to USB - PC viewer, connect a data cable; the console shows up on the home screen.
- **Low-latency playback**: hardware decoding and low-latency OHAudio; frames are presented on VSync as soon as they are decoded, with no extra buffering.
- **Freeze on frame loss**: when the video sequence skips, the last good picture is held and a keyframe is requested at once (`SFTK`), so the picture never smears.
- **Picture enhancement** with the system video processing engine, where supported.
- **Dedicated 5 GHz hotspot** for the console over Wi-Fi Direct.
- **Background keep-alive and picture-in-picture**: keep receiving after leaving the app (with a live view), back to live instantly.
- **Devices**: phones, tablets, PCs/2-in-1s and TVs (remote control). The AppGallery build leaves out TVs; see Build.
- **Three languages** (Simplified Chinese, Traditional Chinese, English) and dark mode.

## Protocol

SFT's stream protocol, SFTR v2 (see `core/sft_protocol.*`):

- The console accepts one receiver on **TCP 9950**; while none is connected it broadcasts `SFTAP1 <ip> 9950 <name>` on **UDP 9951** every second.
- Each packet is a 32-byte little-endian header (magic `SFTR`, version 2, flags, width, height, console-side age, length, crop, sequence) plus the payload: one H.264 Annex-B access unit, 48 kHz stereo 16-bit PCM, or a status packet that says why there is no picture.
- The receiver can write requests on the same connection, such as `SFTK` (send a keyframe now).

## Layout

```
core/                 platform-independent C++ (also built and tested on desktop)
  sft_protocol        header, status packet and broadcast parsing
  sft_net_source      TCP receiving, reconnects, keyframe requests, UDP discovery
  gop_cache           keeps the latest GOP so the picture is live again right after returning to the app
  frame_loss          frame interval estimate and loss causes
harmony/              DevEco project
  entry/src/main/cpp/ session, hardware decoding, enhancement, audio, NAPI
  entry/src/main/ets/ UI: console cards, player, settings, guide, about
tools/
  mock_sft.py         simulates the console (broadcast + TCP stream) for testing without one
  sft_probe.cpp       desktop receiver built from the same core/
  test_host.sh        unit tests + end-to-end tests against the simulated console
  make_test_h264.swift  test stream with macOS VideoToolbox (1080p60 by default)
```

## Building

Needs DevEco Studio or the HarmonyOS command line tools (API 12 or later).

```sh
cd harmony
devecocli build                 # debug build; the repository has no signing configs, so the HAP is unsigned
```

The `default` and `release` products include TVs (for the open-source releases); the AppGallery build uses the `appgallery` product, which declares only phones, tablets and PCs/2-in-1s:

```sh
hvigorw assembleApp -p product=appgallery -p buildMode=release
```

Generate a debug signature in DevEco Studio under **File > Project Structure > Signing Configs** to install it on a device. Keep signing configs local; do not commit them.

## Unsigned builds

Every push is built by GitHub Actions ([`.github/workflows/build.yml`](.github/workflows/build.yml)), and every `v*` tag
publishes an **unsigned** HAP with its SHA-256 to [Releases](../../releases), with that version's section of
[CHANGELOG.md](CHANGELOG.md) as the release notes (the tag fails without one). Tags such as `v1.0.0-beta.1` are published
as pre-releases. These builds include TVs; the AppGallery version leaves them out, and is signed and built separately.

HarmonyOS only installs signed packages, so the unsigned HAP has to be signed with your own certificate first:

- You need a Huawei developer account, plus a debug certificate and a debug profile for your device from AppGallery
  Connect. The signing tool, `hap-sign-tool.jar`, comes with DevEco Studio and the Command Line Tools for HarmonyOS
  (`sdk/default/openharmony/toolchains/lib/`).
- A profile is issued for one bundle name, and `wilk.sft.next` is registered to the publisher's account. If you
  cannot get a profile for it, building from source is the simplest route: change `bundleName` in
  `harmony/AppScope/app.json5` to your own and follow [Building](#building).
- Certificates and profiles expire; sign again with renewed ones when they do.

```sh
java -jar hap-sign-tool.jar sign-app -mode localSign -signAlg SHA256withECDSA \
  -keystoreFile your.p12 -keystorePwd <store password> -keyAlias <alias> -keyPwd <key password> \
  -appCertFile your.cer -profileFile your.p7b \
  -inFile NSSFT-<version>-unsigned.hap -outFile NSSFT-<version>.hap
hdc install NSSFT-<version>.hap
```

The CI build uses [springtwr/harmonyos-clt](https://github.com/springtwr/harmonyos-clt), a community Docker image of
Huawei's Command Line Tools for HarmonyOS (26.0.0.851), pinned by digest.

## Testing

```sh
sh tools/test_host.sh           # unit tests + end-to-end (generates the test stream on macOS)
```

Without a console, the simulated server shows a picture on a real device:

```sh
swift tools/make_test_h264.swift build/test.h264 20
python3 tools/mock_sft.py --h264 build/test.h264 --audio
```

With the device and the computer on the same Wi-Fi, "mock console" appears on the home screen; otherwise enter the computer's IP address.

## License

GPL-2.0, the same as SFT; see [LICENSE](LICENSE).
