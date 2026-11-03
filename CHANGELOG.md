# Changelog

## 1.0.0 — unreleased

### 1.0.0-beta.2

- Player: the toolbar, the picture badge and the lock button hide after 3 seconds without input. Tapping a
  toolbar button restarts the timer, and it pauses while the options panel is open.
- The sound button switches between sound and mute as soon as it is tapped (before, it only updated after the
  toolbar was hidden and shown again).
- While locked, going back (or Esc) shows the lock button and "Go back again to disconnect"; going back again
  within 1 second disconnects and leaves the player.
- The options panel is now titled "Streaming options".
- AppGallery build: the unfinished gamepad and record entries are hidden. Builds from this repository keep them.
- Test tools: `tools/mock_sft.py --pcm` plays a 48 kHz stereo PCM file as game sound instead of a tone.

### 1.0.0-beta.1

- First version: a native HarmonyOS receiver for SFT streaming over the network (TCP 9950, with console
  discovery) or USB, up to 1080p at 60 fps, game sound, freeze on frame loss, picture enhancement, a dedicated
  5 GHz hotspot, background keep-alive and picture-in-picture; phones, tablets, PCs/2-in-1s and TVs.
