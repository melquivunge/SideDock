# SideDock

A customisable macOS dock for the left or right edge of any screen (or all of them), plus **SideDrop**, an iPhone companion that sends files between phone and Mac by holding the phone next to the screen and works as a remote "Deck" for the Mac.

- **SideDock** (Mac): macOS 26+, in `Mac/`
- **SideDrop** (iPhone + Share extension): iOS 18+, in `iOS/`

---

## SideDock (Mac)

### The dock
- **Two modes:**
  - **Replace:** hides the macOS Dock and draws SideDock on the left/right edge of one screen or of every screen.
  - **Beside macOS Dock:** keeps the real Dock, and a small *Hidden Dock* slides out of its end when the pointer reaches it.
- **First launch:** copies your apps and folders from the macOS Dock. You can re-import them later from Settings.
- **Contents:** pinned apps, running apps, folders and the Trash, with dividers between the groups. You set the order and the pins.
- **Behaves like the macOS Dock:**
  - Icons magnify near the pointer.
  - An app you click bounces until it has launched.
  - Folders open as stacks, newest first.
  - Right-click menus: Open, Show in Finder, Hide, Quit, Remove from Dock, Empty Trash.
- **Drag and drop:**
  - Drag apps in from Finder or the App Launcher.
  - Drag a dock icon onto the Trash to remove it from the dock.
  - Drag a Finder file onto the Trash to move it to the Trash.
- **App Launcher:** the macOS *Apps* view, or SideDock's own grid of every app on older systems. It opens next to the dock.
- **Auto-hide:** at an edge shared with another screen, the dock appears only after a short pause there, so the pointer can still pass through to the next screen.
- **Keep windows clear (Accessibility):** moves windows out from under the dock.
- **Turn Dock Off/On** without quitting. While it's off the macOS Dock comes back, and corners, edges and the iPhone features keep working.
- Quitting or killing SideDock always restores the macOS Dock.

### Corner Dials and Edge Sliders
- **Corner Dials:** a quarter-dial peeks out of each screen corner. Press and turn it, or scroll with the trackpad or mouse wheel.
- **Edge Sliders:** a tall slider slides out of the left/right screen edge.
- **What they control:** volume, display brightness, keyboard backlight, audio output device, or light/dark mode.
  - Brightness works on built-in and Apple displays, and on other monitors over DDC/CI (Apple Silicon).
- **App Profiles:** corners and edges can do something different while a particular app is in front.
- Controls act on the screen the pointer is on.

### Menu-bar control panel
- Settings for the dock, the controls, App Profiles, the iPhone, and the received-files folder.
- Actions: Recalibrate, Preview glow, Forget paired iPhones, Show file shelf.

### SideDrop (Mac side)
- **Pairing:** the Mac advertises a Bluetooth LE beacon. Hold a paired iPhone next to the screen and the two connect over MultipeerConnectivity (encrypted, peer-to-peer Wi-Fi/Bluetooth).
  - New iPhones need one approval click on the Mac. After that they reconnect on their own.
- **Phone → Mac:** a glowing strip lights up on the screen edge next to the phone. A photo flicked off the phone crosses onto the Mac live, split across both screens, then lands on the Desktop (or in `~/Downloads/SideDrop`).
- **Mac → phone:** drag a file to the glowing edge and it slides onto the phone.
- **Light effects:** a white flash at the edge spreads across the screen as a wave with a rainbow front. Regular AirDrop arrivals get the same effect.
- **File shelf:** a floating panel listing received files, with a drop zone for sending.
- **Several macOS users:** only the user on screen is visible to the iPhone.

### iPhone Deck (Mac side)
The Mac answers the phone's Deck:
- System controls
- Now playing from Spotify or Music, with the album cover and the track position
- App launching
- Window management
- Claude Code / Codex status
- Creative Pro tools

---

## SideDrop (iPhone)

### Sending and receiving
- **Connecting:** hold the iPhone next to the Mac. The Closeness slider sets how near the phone must be (a calibration in dBm).
- **Sending:**
  - From the Recent grid: tap a photo, then drag it toward the Mac.
  - Or pick from All Photos or Files.
  - Originals are sent with their names (HEIC, MOV, and edited versions).
- **Receiving:** files you drag to the Mac's glowing edge appear under **From your Mac**. Tap one to send it back.
- **Share extension:** send from any app's share sheet straight to the paired Mac, without opening SideDrop.

### Deck (the iPhone as a remote for the Mac)
- **Control:**
  - Four corners hold four controls. Drag up or down in a corner to change its value.
  - The Shelf has widgets for Now Playing and a 1–60 min timer.
  - Long-press the background to switch the widget style.
- **Now Playing:**
  - Full-screen cover with synced lyrics from [LRCLIB](https://lrclib.net). Only the song title and artist are sent.
  - Play/pause, next and previous.
- **Launch:** tap or flick an app from your Mac's dock to open it on the Mac.
- **Windows:**
  - Per app: bring to front, minimise, or maximise on a chosen screen.
  - Split 50/50: put two apps side by side on a screen.
- **Claude Code / Codex:** shows whether each agent is working, waiting for you, or idle, plus its last message. Tap to bring its terminal to the front.
- **Creative Pro:** tools for the creative app in front on the Mac (Photoshop, Illustrator, After Effects, Premiere Pro, Blender):
  - Shortcut buttons
  - Jog wheels
  - Precise sliders, such as Photoshop opacity
  - Colour picking: sets the foreground colour in Photoshop or the selection fill in Illustrator

---

## Build

```sh
./build.sh            # build the Mac app into build/
./build.sh install    # build, install to /Applications and launch
./build.sh release    # Developer ID signed + notarized build/release/SideDock.dmg
```

For the iPhone app, open `iOS/SideDrop.xcodeproj` in Xcode and run it on a device.

## Permissions

| Permission | Used for |
|---|---|
| Accessibility | Reading the macOS Dock's position, moving windows, Creative Pro keystrokes |
| Automation | Light/dark mode, Spotify/Music now playing, Photoshop/Illustrator colours |
| Bluetooth + Local Network | Finding and connecting to the iPhone |
| Photos (iPhone) | Sending photos and videos |
| Full Disk Access (optional) | Showing whether the Trash is full |
