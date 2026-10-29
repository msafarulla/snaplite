# SnapNow

*Formerly SnapLite.*

**A free, source-available screenshot, markup and screen-recording app for the Mac menu bar.**
Capture an area, a window or the whole screen, mark it up with arrows, callouts and numbered steps,
blur what's private, and copy or save it, without leaving your keyboard.

![The SnapNow editor: tapered arrow, callout with pointer, numbered steps, highlight and box on a dashboard capture](docs/screenshots/editor.png)

> **Platforms:** SnapNow is fully functional on **macOS** today. It's built with Flutter, and early previews
> for Windows and Linux are in every release. Once I have Windows and Linux machines to develop and test on,
> the same features (capture, recording, Copy Text and the rest) will come to those platforms too.

## Why SnapNow

- **One shortcut, done.** Press your capture shortcut (⌃⇧C by default, any combination you like), drag an area,
  and the capture opens in the editor, already saved to `~/Pictures/SnapNow`.
- **Annotations that look good by default.** Arrows taper and curve, callouts point at things, steps number
  themselves, and everything has a soft shadow. Pick a ready-made style with one click.
- **Every capture in one place.** The Library keeps all your captures and recordings; drag any of them into
  the image you are editing to build a before/after or a step-by-step in seconds.
- **Copy text from anything.** Select an area of the screen and its text is on your clipboard, with table
  columns as tabs, so it pastes into a spreadsheet as cells. Fully on-device (Apple Vision).
- **Animated GIFs and WhatsApp stickers from your markup.** One shortcut turns a marked-up capture into a GIF
  where each arrow and box draws itself in, or into an animated WhatsApp sticker. See
  [GIFs and stickers](#gifs-and-stickers).
- **Record the screen** into a `.mov`, then turn it into a GIF from the Library.
- **Yours.** No account, no cloud, no telemetry. Free for personal and work use.

## Capture

Click the menu bar icon for the capture panel, or right-click it for the full menu.

<p>
  <img src="docs/screenshots/capture-panel.png" alt="Capture panel: Area, Window, Screen, Video and Text modes, a shutter button and options" width="430">
  &nbsp;
  <img src="docs/screenshots/menu.png" alt="Menu bar menu with every capture mode and its shortcut" width="260">
</p>

| | Default shortcut |
|---|---|
| Capture an area (press Space to pick a window) | ⌃⇧C |
| Capture a window | ⌃⇧W |
| Capture the full screen | ⌃⇧F |
| Copy text from an area | ⌃⇧T |
| Record the screen (press again to stop) | ⌃⇧R |
| Open the Library | ⌃⇧O |

All of them can be changed in **Settings › Shortcuts**. The capture panel adds a time delay, effects
(border, shadow), sharing (copy to Desktop, show in Finder, open in Preview) and saved presets.

## Mark it up

| Tool | Key | |
|---|---|---|
| Select | V | Click anything to edit it; drag to move, handles to resize. ⌘A selects the whole image. |
| Arrow | A | Drag; pull the round middle handle to curve it. |
| Text / Callout | T / K | Callout: drag from what you want to point at to where the bubble goes. |
| Shape / Line / Pen | R or O / L / P | Shape draws a rectangle, square, ellipse or circle (pick in the panel; Shift keeps sides equal). |
| Step | N | Click to drop numbered markers: 1, 2, 3… |
| Highlight | H | |
| Blur | B | Hide emails, names, keys. |
| Spotlight | S | Dims everything except what matters. |
| Crop | C | |
| Copy Text | G | Copies all text in the image. |

<img align="right" src="docs/screenshots/arrow-options.png" alt="Arrow options: ten head types, head size, line patterns, tapered, outline, shadow" width="250">

The panel on the right edits the selection, or the defaults for the tool you're using:

- **Styles:** Starter, Bold, Muted and Tokyo Night sets, plus your own saved styles
- **Colour and size:** swatches, any colour from the macOS picker, S / M / L
- **Arrowheads:** ten head types for each end, head size, swap ends
- **Lines:** solid, dashed, dotted, dash-dot and long dash; tapered, outline, shadow; straighten a curve

Right-click the canvas to flip, trim, crop to the canvas, resize it, change the canvas colour or flatten
everything into the image. Drag the image's square handles to add space around it.

**⌘C** copies the finished image (marching ants show it worked), **⌘S** saves it back to the capture.
**⇧⌘S** (Save As…) exports PNG, JPEG, HEIC, TIFF, PDF, GIF or BMP, keeping Retina resolution.
**Share** (toolbar) opens the macOS share menu (Messages, Mail, AirDrop, Notes, WhatsApp…) with the finished
image. **Pin** (⌥⌘T) keeps the editor above other windows. **Esc** saves your changes and closes the window
(⌘W asks first).

**Changed your mind later?** ⌘S keeps your markup inside the saved PNG. Any app shows the finished picture, but
when you reopen it in SnapNow the original capture and every annotation come back, still editable and in the
order you added them, so you can fix an arrow or make the animated GIF days afterwards. If another app edits the
picture, it simply opens flat.

**Zoom:** pinch, ⌘-scroll, or ⌘= / ⌘- / ⌘0 (fit) / ⌘1 (100%); scroll or hold Space and drag to pan.

<br clear="right">

## GIFs and stickers

Mark up a capture, then turn it into something that moves. Everything is made on your Mac, from the markup
itself (no screen recording needed).

![An animated GIF made by SnapNow: curved arrows draw themselves onto a dashboard capture, one after another](docs/screenshots/build-up.gif)

| | How | What you get |
|---|---|---|
| Animated GIF to the clipboard | **⇧⌘C** (More › Copy as Animated GIF) | Paste into Messages, Slack, Mail, WhatsApp, Jira… |
| Animated GIF file | More › Save as Animated GIF… | A `.gif` wherever you choose |
| Animated WhatsApp sticker | **⌃⌘C** (More › Animated WhatsApp Sticker) | Added to a "SnapNow" sticker pack in WhatsApp |
| Still WhatsApp sticker | More › Copy as Still Sticker (or ⌃⌘C with no markup) | Pastes straight into a chat as a sticker |
| Moving marching ants | Pattern › Marching Ants on any line or box, then **⌘C** | A looping GIF where only the dashes move |

### The build-up GIF

1. Capture something and add your markup (arrows, boxes, steps, callouts, highlights…) in the order you want it
   to appear.
2. Press **⇧⌘C** and paste, or use **More › Save as Animated GIF…** for a file.

The GIF starts with the original capture, then each annotation appears in the order you added it: lines and
boxes draw themselves on, arrows grow with the head riding the tip, highlights wipe across, steps and callouts
pop in, text and blur fade in, and a spotlight dims the rest. The finished picture holds for a moment, then it
loops. Retina captures come out at 1.5× their on-screen size: sharp, without being huge. Good for showing a
step-by-step in a chat or a ticket.

Because ⌘S keeps your markup inside the saved PNG, you can reopen any capture days later and make the GIF then.

### WhatsApp stickers

1. Mark up a capture (or don't, for a still sticker).
2. Press **⌃⌘C**. WhatsApp for Mac opens and asks to add or update the **SnapNow** sticker pack; accept.
3. In any chat, open the sticker tray, pick the SnapNow tab and send your sticker. It plays the same build-up
   animation as the GIF.

WhatsApp only animates stickers that come from an installed pack (pasted stickers stay still), which is why
SnapNow keeps its own pack with your newest 30 stickers. WhatsApp needs at least 3 stickers in a pack, so
while you have fewer, it's filled with copies of the newest. The clipboard is used for the hand-off to WhatsApp
and put back a minute later. Stickers are fitted into 512 × 512, as WhatsApp requires. Needs WhatsApp for
Mac.

## The Library

![The Library: a grid of every capture with search](docs/screenshots/library.png)

Search, multi-select, right-click to copy, copy text, show in Finder, export a recording as a GIF, or move
to the Trash (or hover a thumbnail and click its ✕). Double-click a capture to edit it with a filmstrip of
all your captures below.

## Install

Download the latest build for your system from **[Releases](https://github.com/msafarulla/snapnow/releases/latest)**.
Every build is made and tested by [GitHub Actions](https://github.com/msafarulla/snapnow/actions) from this
repository's source.

| | File | Status |
|---|---|---|
| macOS 14 or later (Apple silicon) | `SnapNow-macOS.zip` | Full app |
| Windows 10 / 11 (x64) | `SnapNow-Windows.zip` | Early preview: the editor |
| Linux x64 | `SnapNow-Linux-x64.tar.gz` | Early preview: the editor |

### macOS

1. Unzip `SnapNow-macOS.zip` and drag **SnapNow.app** into **Applications**.
2. Open it. SnapNow isn't notarized by Apple yet (that needs a paid Apple Developer ID), so the first time
   macOS says it can't check the app. Click **Done**, then go to **System Settings › Privacy & Security**,
   scroll down to *"SnapNow" was blocked* and click **Open Anyway**. You only do this once per version.
3. On your first capture macOS asks for **Screen Recording** permission (System Settings › Privacy & Security ›
   Screen & System Audio Recording). Downloaded builds are signed ad hoc, so macOS may ask again after an update.

<details>
<summary>Advanced: skip the Gatekeeper prompt from Terminal</summary>

`xattr -dr com.apple.quarantine /Applications/SnapNow.app` removes the "downloaded from the internet" flag,
so macOS doesn't check the app at all. Only do this for a build you downloaded from this repository's Releases.
</details>

### Windows (preview)

1. Unzip `SnapNow-Windows.zip` into a folder of your choice, for example `C:\Program Files\SnapNow`, keeping
   all the files together.
2. Run **snaplite_flutter.exe**. The build isn't code-signed yet, so Windows SmartScreen may say
   *"Windows protected your PC"*: click **More info**, then **Run anyway**.
3. SnapNow starts in the system tray (the ^ area next to the clock): use it to open the Library or an image.
4. If Windows reports a missing `VCRUNTIME140.dll` or `MSVCP140.dll`, install Microsoft's
   [Visual C++ Redistributable (x64)](https://aka.ms/vs/17/release/vc_redist.x64.exe).

### Linux (preview)

Built on Ubuntu 24.04, so it needs a similarly recent distribution (glibc 2.39 or later: Ubuntu 24.04+,
Debian 13, Fedora 40+).

```sh
# Ubuntu / Debian: the libraries SnapNow uses (tray icon, global shortcuts, file dialogs)
sudo apt install libgtk-3-0 libayatana-appindicator3-1 libkeybinder-3.0-0 zenity

tar -xzf SnapNow-Linux-x64.tar.gz
./SnapNow/snaplite_flutter
```

On GNOME the tray icon needs the *AppIndicator and KStatusNotifierItem Support* extension (Ubuntu has it built
in).

**About the previews:** they build and start on every release (checked automatically), but haven't been tried
by hand yet. The editor (open an image, mark it up, save) is the part meant to work. Screen capture, recording,
Copy Text (OCR), notifications and Library thumbnails are macOS-only for now; they'll follow once I have
Windows and Linux machines to build and test them on. Bug reports are welcome in
[Issues](https://github.com/msafarulla/snapnow/issues).

### Build from source (macOS)

**Requirements:** macOS 14 or later, Xcode, [Flutter](https://docs.flutter.dev/get-started/install/macos) 3.32
or later, CocoaPods, and libwebp (`brew install webp`; linked into the app, so users don't need it).

```sh
git clone https://github.com/msafarulla/snapnow.git
cd snapnow
tools/install.sh        # builds, signs, installs to /Applications and launches
```

Without a stable signing identity the app is signed ad hoc, and macOS asks for Screen Recording again after each
rebuild; see the top of [`tools/install.sh`](tools/install.sh) for using your own identity. On Windows or Linux,
install Flutter and run `flutter build windows` or `flutter build linux`.

## How it's built

- **Editor and Library:** Flutter (Dart), so they can come to Windows and Linux.
- **macOS shell:** native Swift in [`macos/Runner/Shell`](macos/Runner/Shell): the menu bar item, capture
  panel, global hotkeys (Carbon, no Accessibility permission needed), `screencapture`-based capture and
  recording, Vision OCR and Quick Look thumbnails, talking to Flutter over one method channel
  ([`SnapLiteNative.swift`](macos/Runner/SnapLiteNative.swift) ↔ [`native.dart`](lib/platform/native.dart)).
- Settings live in the app's UserDefaults (`defaults read com.mm.SnapLite`).

## Builds and releases

[GitHub Actions](.github/workflows/build.yml) checks every push and pull request:

- **Tests:** `flutter analyze` and the full `flutter test` suite on macOS.
- **Builds:** macOS, Windows and Linux. The Windows and Linux builds are also launched for 15 seconds to make sure
  they start.

Each run's builds can be downloaded from its page under [Actions](https://github.com/msafarulla/snapnow/actions).

**Publishing a release** takes a version tag. Bump `version:` in `pubspec.yaml`, commit, then:

```sh
git tag -a v1.13.0 -m "SnapNow 1.13.0"
git push origin v1.13.0
```

The same workflow builds all three platforms and, only if every job passes, publishes them as a
[GitHub Release](https://github.com/msafarulla/snapnow/releases) with notes generated from the commits.

## Roadmap

- Signed, notarized releases
- Windows and Linux with the full feature set (capture, recording, Copy Text, notifications), once I have
  machines of each to develop and test on
- Scrolling capture, auto-redact, search captures by their text

## License

Free to use, personally or at work, and to read, change and share for free. Selling SnapNow, or a product
or service built substantially on it, needs the author's written permission. Patent rights are reserved.
See [LICENSE](LICENSE) (MIT with the Commons Clause). Versions up to v1.12.0 were plain MIT.
The macOS app includes Google's libwebp (BSD licence); see [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES).
