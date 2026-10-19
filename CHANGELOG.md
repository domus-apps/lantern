# Changelog

All notable changes to Lantern are documented here. The release workflow publishes each version's section as the GitHub release notes and embeds it in the Sparkle appcast, so the in-app update dialog shows the same notes. A release fails early if its version has no section here.

Keep each bullet on a single line: release notes render line breaks literally (both on GitHub and in the update dialog), so wrapped lines would break mid-sentence.

## 2.0.0

Lantern now turns videos into GIFs.

### Added

- You can drop a video on Lantern's window or its Dock icon to make a GIF.
- You can also copy a video in Finder and paste it into Lantern with ⌘V.
- You can open a new window for the next video with File › New Window (⌘N), even while other videos are open.
- You can also open a video with File › Open Video (⌘O), Open With in Finder, or Services › Make GIF with Lantern.
- A quality slider lets you choose between a smaller file and more detail. Sliding toward Smaller File can bring a GIF under a chat app's upload limit.
- You can choose whether the GIF loops, plays once, or bounces back and forth. A Bounce of a switch turning on also shows it turning back off.
- You can remove the thin line that macOS screen recordings leave around their edges, so the GIF has clean edges.
- You can crop the GIF to the part of the video you need, such as one window in a full-screen recording.
- The editor shows the exact size of the finished GIF each time you change its size, frame rate, playback, quality, trim, or crop. Changing the frame rate from 30 to 15 fps shows how much smaller the GIF gets.
- Copy puts the GIF on the clipboard so you can paste it straight into a chat or a GitHub issue.

### Changed

- A 45-second screen recording at half size makes a GIF of around 2.6 MB.
- Lantern opens to a window like a regular app, with no menu bar icon.
- Lantern stays in the Dock after you close its windows, so you can keep dropping videos on its icon.
- GIFs are saved next to their video, and Settings can switch this to the Desktop, another folder, or asking each time.

### Removed

- Screen capture, the capture bar, and its shortcut are gone. You can record the screen with the Screenshot app (⌘⇧5) and drop the recording on Lantern.
- MP4 and PNG export are gone.
- Launch at login is gone.

### Fixed

- Resized GIFs no longer have faint see-through edges.
- A custom width of four digits or more no longer makes a tiny GIF.

## 1.0.5

### Fixed

- The Settings window could no longer be dragged after a switch in it was flipped.

## 1.0.4

### Changed

- The capture bar and the overlay now fade in and out instead of zooming from the center of the screen.
- Tooltips on the capture bar's buttons appear sooner.

## 1.0.3

### Fixed

- The app icon's background looked flat in the Dock and Finder. It now shows its gradient.

## 1.0.2

### Fixed

- Moving a selected area no longer makes it slightly larger with every move.

## 1.0.1

### Fixed

- Opening the capture bar no longer asks for the Device Control and Data Access permission. Screen Recording is the only permission Lantern needs.

## 1.0.0

The first release.

- Press ⌥⌘S for a capture bar like the system's: an image or a recording of the whole screen, one window, or an area you drag.
- Every capture opens in an editor first, where you choose the size, the frame rate, and PNG, MP4, or GIF, and trim recordings.
- GIFs loop forever and are encoded by macOS itself, at up to 30 frames per second.
- Save writes to the Desktop or a folder of your choice and copies images to the clipboard as well.
- While recording, the menu bar shows a stop button with the elapsed time.
