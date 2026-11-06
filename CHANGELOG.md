# Changelog

## 1.0.0 — unreleased

### 1.0.0-pre-release.3

The build submitted to AppGallery for the 1.0.0 release (versionCode 1000002).

- The touch controller now depends on whether this device has a touchscreen, not on the device type: PCs and 2-in-1s
  with a built-in or external touchscreen, and devices that switch between tablet and PC modes, can use it. It is
  checked again whenever input devices change; without a touchscreen its settings are greyed out with "This device has
  no touchscreen".

### 1.0.0-pre-release.2

This build mostly reworks the player: a new side menu, picture position, screen orientation with separate landscape
and portrait layouts, and the lock, "Picture above buttons" and "Freeze on frame loss" are gone.

- Player menu: sound, controller and picture position at the top, then a "Streaming options" group with picture
  enhancement, orientation, network optimization, stats overlay and picture-in-picture on leave (the separate Streaming
  options page is gone). On/off items are toggles; picture position, orientation and picture enhancement have an
  arrow, and orientation and enhancement open a list to pick from (no more stepping left and right). The header has two icon buttons, Record and Exit: Record turns into a red capsule
  showing the recording time while recording, and tapping it stops; Exit uses an exit arrow. The manual picture-in-picture
  button is gone (leaving the app moves into it on its own). A gap and a thin line keep the first item away from the
  header buttons. The Controller page is grouped into status, the main switch, controller and keyboard, and touch
  controller, with the long descriptions left to Settings and the guide; unavailable items show a one-line reason,
  and picture enhancement is now listed and greyed out on devices without it instead of hidden.
  Phones in landscape keep compact spacing, tablets and unfolded foldables get more room. The "1080p · 60 fps" tag on
  the picture is gone (the menu header shows it).
- Menu button: it shows in full for a few seconds (when streaming starts, after the menu closes, after back or a tap
  on the picture), then morphs into a faint short line at the top center that opens the menu when tapped. It always
  stays there, and touch controller buttons cannot be dragged onto it.
- No accidental exits (replacing the lock): while streaming neither the back gesture nor the back key stops the
  stream; it shows "To exit, tap the menu button at the top center" (at most once every 10 seconds) and brings up the button.
  Stop from Exit in the menu. Back still steps out of the menu, the "press back twice" rule for the touch controller
  is gone, and TVs are unchanged.
- Leaving while recording (Exit in the menu, or back on a TV) asks: stop recording and leave, keep recording, or
  cancel. Keep recording moves on to Record only: the picture and local sound stop, the controller is let go and full
  screen ends, while the recording goes on. Record only no longer asks for 60 Hz.
- Picture position: when there is empty space above and below the picture (a tablet held upright, an unfolded
  foldable, a tri-fold), tap Picture position in the menu and drag the picture up or down; it snaps to the top, center
  and bottom, and Save keeps it for that screen shape (folded, unfolded, rotated). The picture and the touch
  controller are separate layers. The item is greyed out with the reason when the picture already fills the height.
- Orientation and layouts: on tablets, unfolded foldables, wide foldables and other wide screens the player follows
  the system rotation (and the rotation lock), or you can fix it to landscape or portrait in Settings or the menu;
  phones, outer screens and TVs stay landscape. Only the player is affected, and other pages return to their earlier
  orientation. This replaces "Portrait while streaming" (on becomes Portrait). "Picture above buttons" is gone:
  landscape and portrait keep separate layouts (say, buttons over the picture in landscape and below it in portrait);
  the default portrait layout fills the space below the picture (shoulder buttons right under it, left stick over
  the D-pad and ABXY over the right stick, spaced out to fit, minus/capture/HOME/plus in the middle) with the picture
  at the top, and your own "Picture
  above buttons" layouts become portrait layouts.
- The touch controller is marked experimental, with a new "Touch controller: known issues" guide entry: late or lost
  presses on a shaky network, games that only listen to player 1 need it moved first in Change Grip/Order, and it is
  not yet tested enough in real games.
- Picture enhancement only runs when the picture needs real upscaling (under 1.3x it plays directly), so 1080p no
  longer pays about 20 ms for nothing; a 720p picture shown landscape is still enhanced.
- The "Freeze on frame loss" toggle is gone: SFT's network and USB links never lose frames and it never fired in
  tests; it stays on behind the scenes. The FAQ "The picture pauses briefly" now explains network stalls and what
  helps.
- Settings are regrouped: Picture and sound (game sound, picture enhancement, 60 Hz), Streaming (orientation,
  network optimization, picture-in-picture on leave, stats overlay), Controller, Touch controller (enable, size,
  opacity, vibration, auto-hide, Manage layouts), Recording, Appearance and Help. The Beta and Experimental tags of the
  Controller and Touch controller groups now sit at the right of the group titles,
  and "Touch controller layouts" is now "Manage layouts".
- Home, settings, guide, recordings, layouts and about now scroll under the bottom gesture bar instead of stopping
  above a solid band.
- Enter address manually: full IP addresses can be typed again (the number pad allowed only one dot, so the last two
  were lost), and a host name works too (resolved by the system's DNS).
- The extra gap above the title on the Record only page is gone (the status bar height was added twice).

### 1.0.0-pre-release.1

The build submitted to the AppGallery public test.

- Touch controller: on 16:9 landscape screens (640 vp wide) the − ◎ HOME + row at the bottom center overlapped the
  D-pad and the right stick; when the screen is too narrow the row now sits above them, and R3 moves to the upper
  right of the right stick.
- Layouts page: the "In use" tag could overlap the Edit button, and the layout in use still said "Tap to use". On
  phones in portrait the buttons squeezed the name and description, so on narrow screens they now sit below the
  description.
- Wording: the About page, the guide and the app description say "client" instead of "receiver" (it can control
  the console now).

### 1.0.0-beta.3

- Recording: record while streaming, or choose "Record only" on the home screen (no picture, less power), with three
  quality presets (high, standard, small). While recording, a Live View in the notification bar shows how long and how
  much has been recorded. Recordings stay in the app until you open them in the system player, save them to the
  gallery or delete them from the Recordings card on the home screen. While recording, the console is asked to keep
  one picture size, so a recording stays in one file.
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
