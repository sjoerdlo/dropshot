# DropShot

A lightweight macOS screenshot tool that replaces the native screenshot utility with scrolling capture support.

## Features

**Quick Capture** (`⌘⇧4`) — Draw a rectangle on screen and instantly capture it. A draggable thumbnail appears in the corner, ready to drop into any app or paste with `⌘V`.

**Scroll Capture** (`⌘⇧3`) — Select a region, then scroll through content. DropShot stitches consecutive frames together using Apple's Vision framework to produce a single tall screenshot of the entire scrollable area.

Both modes show a live pixel-size indicator while selecting, and produce a floating thumbnail preview that can be dragged directly into Finder, Slack, Mail, or any other app.

## Requirements

- macOS 14.0+
- Xcode 15+
- Screen Recording permission (prompted on first launch)

## Building

Open `DropShot.xcodeproj` in Xcode and run (⌘R). DropShot lives in the menu bar — look for the **DropShot** status item.

## Usage

1. Disable the native macOS screenshot shortcuts in **System Settings → Keyboard → Keyboard Shortcuts → Screenshots** to avoid conflicts.
2. Press `⌘⇧4` for a quick screenshot or `⌘⇧3` for a scrolling capture.
3. Draw a selection rectangle on screen.
4. For scroll capture: scroll through the content, then press **Done** in the control panel. For quick capture: the screenshot is taken immediately on mouse release.
5. A thumbnail appears in the bottom-right corner. Drag it into any app, click it to open the full result, or just `⌘V` to paste — the image is already on your clipboard.

## How Scroll Capture Works

DropShot uses ScreenCaptureKit to grab frames of the selected region while you scroll. Each frame is compared to the previous one using `VNTranslationalImageRegistrationRequest` to detect exactly how many pixels the content moved. The unique strips are then stitched together into a single composite image using a CGContext pipeline with matched BGRA pixel format for zero-conversion blitting.

## License

MIT
