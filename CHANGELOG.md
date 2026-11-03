# Changelog

## 1.0.0 — unreleased

### 1.0.0-beta.3

- Recording: record while streaming, or choose "Record only" on the home screen (no picture, less power), with
  three quality presets (high, standard, small). A timer Live View in the notification bar shows the recording and
  can stop it. Recordings stay in the app until you open them in the system player, save them to the gallery or
  delete them from the Recordings card on the home screen. While recording, the console is asked to keep one
  picture size, so a recording stays in one file.
- Controller: once SFT on the console has "Controls from the viewer" turned on (SFT 0.7.20 or later), a controller
  or keyboard on this device plays the console. A client is one controller on the console; every local controller
  and the keyboard are merged into it. Button layout (by position / by label) and the stick dead zone can be set,
  and holding Start and Select for 1.5 seconds opens the menu.
- Touch controller (phones and tablets): on-screen buttons with a floating left stick, sliding between face
  buttons and D-pad directions, and a light buzz on press. Buttons can be moved, resized and hidden, with optional
  L3 / R3. Landscape, portrait and picture-above-buttons each have a default layout, and you can create, edit,
  rename and delete your own.
- Wide screens (wide foldables, unfolded foldables): portrait while streaming, with the picture above the buttons
  so they do not cover it.
- Player: the bottom toolbar is replaced by a menu button at the top center that opens a side menu (the TV uses
  the same menu); lock and disconnect sit at the top of the menu.
- TV: the remote can now reach the menu; the first stream shows a guide to the remote's keys.
- "Keep connected in the background" is gone (picture-in-picture covers it); the long-running background task is
  only requested while recording.
- Phones stream in landscape by default, and folding or unfolding while streaming re-applies the orientation.
- The AppGallery build now includes the controller and recording.
- Test tools: `tools/mock_sft.py --input` pretends the console takes a controller and logs the controller
  messages it receives; controller unit tests and an end-to-end case.
- README: tip codes for supporting the project.

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
