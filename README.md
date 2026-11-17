# SideDock

A customisable dock for macOS, plus **SideDrop**, its iPhone companion. Hold the phone next to the Mac and files fly between the two screens, and the phone becomes a remote ("Deck") for the Mac: Spotify/Music control with synced lyrics, volume and brightness, app launching, window management, Claude Code/Codex status, and tools for Photoshop, Illustrator, After Effects, Premiere Pro and Blender.

| App | Platform | Folder |
|---|---|---|
| **SideDock** | macOS 26+ | `Mac/` |
| **SideDrop** + Share extension | iOS 18+ (iPhone and iPad, every orientation) | `iOS/` |

---

## SideDock (Mac)

### Dock modes
- **Replace macOS Dock:** hides the macOS Dock and draws SideDock in its place.
  - On the **left, bottom or right** edge.
  - On **one screen or all screens at once** (the macOS Dock can't be on several screens).
- **Hidden Dock:** keeps the macOS Dock. When the pointer reaches the end of the macOS Dock, a small extra dock slides out of it.
  - Drag apps onto it from Finder or the App Launcher.
  - It finds the Dock's position with Accessibility. **Recalibrate** reads it again if the Dock moves.
- **Turn Dock Off/On** without quitting. The macOS Dock comes back, and corners, edges and the iPhone features keep working.
- Quitting, `Ctrl-C` or killing SideDock always restores the macOS Dock.

### Dock contents
- Pinned apps, then open apps that aren't kept (below a divider), then folders and the Trash.
- **First launch:** imports your apps and folders from the macOS Dock. **Re-import from macOS Dock** does it again any time.
- **Adding and arranging:**
  - Drag apps or folders from Finder onto the dock to add them.
  - Drag icons to reorder them.
- **Removing:**
  - Drop an icon on the Trash to remove it from the dock.
  - Drop a Finder file on the Trash to move it to the Trash.
- **Folders & Downloads:** a click opens a stack menu of the newest files, plus *Open in Finder*.
- **Trash:**
  - Shows empty or full.
  - Click to open it, or right-click → **Empty Trash…** (asks first).
- **App Launcher:** sits next to Finder.
  - On recent macOS it opens the real macOS *Apps* view (search, categories, recents).
  - On older systems it opens SideDock's own grid of every app, next to the dock.
- **Right-click an app:** Show in Finder, Keep in Dock / Remove from Dock, Hide, Quit.
- **Right-click the dock:** Turn Hiding On/Off, Position on Screen (Left / Bottom / Right), Dock Settings…

### Dock behaviour (like the macOS Dock)
- **Magnification:** icons near the pointer grow and rise out of the bar.
- **Launch bounce:** an app that isn't open yet bounces until it launches (up to 5 s).
- **Open-app indicators:** dots under running apps.
- **Auto-hide:** the dock appears when the pointer touches the edge.
  - At an edge shared with another screen, it needs a short pause there, so the pointer can still cross to the next screen.
- **Keep windows clear of the dock:** moves windows off the dock (needs Accessibility).
- **Full dock:** when there are too many icons, it adds columns or shrinks the icons (your choice).
- **Open at login.**

### Dock appearance
- **Icon size:** S / M / L / XL, or any size from 24 to 128 pt.
- **Magnification:** Off / Small / Medium / Large, or any zoom level.
- **Icon spacing**, and **distance from the screen edge**.
- **Background:** Liquid, Frosted, Color (swatches or any colour) or None.
- **Opacity** and **corner radius**.

### Corner Dials
- A quarter of a dial peeks out of each screen corner. Push the pointer into the corner, then **scroll** (trackpad or mouse wheel) or **press and turn** it into a full dial.
- **What each corner can control:**
  - **Volume**
  - **Display brightness:** built-in and Apple displays, plus other monitors over **DDC/CI** (Apple Silicon)
  - **Keyboard backlight**
  - **Audio output device:** speakers, headphones, AirPlay…
- The value shows in the middle of the dial while you turn it.
- Top corners sit just below the menu bar.

### Edge Sliders
- Touch the upper part of the left or right screen edge, and a dark tab with a tall slider slides out. Scroll or drag it.
- **What each edge can control:** volume, brightness, keyboard backlight, or **light/dark mode**.
- At an edge shared with another screen, the pointer is held back once to open the control. Push again to cross to the next screen.
- Controls act on the screen the pointer is on.

### App Profiles
- Give any app its own corner and edge controls. They switch in automatically while that app is in front.
- In a profile, each corner or edge can stay "Same as all apps".
- Remove a profile with one click.

### Menu-bar control panel
The dock icon in the menu bar opens a panel with seven tabs:

| Tab | What's in it |
|---|---|
| Dock | Size, magnification, spacing, full-dock behaviour, dock mode, Recalibrate |
| Position | Edge, which screen(s), distance from the edge |
| Appearance | Background style, colour, opacity, corner radius |
| Items | Open-app dots, open apps, folders, Trash, App Launcher, re-import |
| Controls | Corner dials, edge sliders, App Profiles |
| iPhone | SideDrop settings (see below) |
| Behavior | Auto-hide, keep windows clear, open at login, reset all settings |

It also has **Turn Dock Off/On** and **Quit**.

---

## SideDrop: files between iPhone and Mac

### Connecting
- The Mac sends out a Bluetooth LE beacon. Hold the iPhone **next to the Mac** and they connect over MultipeerConnectivity, which is encrypted and peer-to-peer over Wi-Fi/Bluetooth. No internet is needed.
- **First time:** a new iPhone must be approved with a click on the Mac. After that it gets a pairing secret and reconnects on its own.
- **Closeness:** a slider on the iPhone sets how close the phone must be (in dBm). A radar shows how close you are.
- **Forget paired iPhones** on the Mac, or **Forget paired Macs** on the iPhone, resets pairing.
- **Several macOS users:** only the user who is on screen is visible to the iPhone.

### iPhone → Mac
- **Recent grid:** your newest 90 photos and videos.
  - Tap one, or select several and press **Send N**.
  - The photo opens full screen. Drag it toward the Mac.
- **Live hand-off:**
  - Both screens light up along the shared edge as the photo gets close.
  - The part of the photo past the phone's edge appears on the Mac at the same height, so one photo spans both screens.
  - Let go and it flies over, shows big in the middle of the Mac (you can grab and drag it like a file), then shrinks onto the Desktop.
- **Light effects:** a white flash at the edge spreads across the screen as a circular wave with a rainbow front.
- **What gets sent:**
  - The original file with its name (HEIC, MOV…), or the edited version if there is one.
  - iCloud photos are downloaded first.
  - A small preview goes first, so the Mac shows the picture before you let go.
- **Other ways to send:** **All Photos**, **Files**, or drag files in from another app (Files, Photos…) anywhere in SideDrop.
- **Share extension:** send from any app's share sheet straight to the paired Mac, without opening SideDrop.

### Mac → iPhone
- Drag a file to the **glowing edge** of the Mac screen. Both edges light up, and you can drop on either.
- The part of the file past the Mac's edge appears on the phone at the same height. After the drop it grows to the middle, then drops into **From your Mac**.
- Tap the arriving photo to grab it straight away.
- **From your Mac** list: **Send back to Mac** or **Delete**.

### On the Mac
- **Save received files to** the Desktop or `~/Downloads/SideDrop`. Files are never overwritten.
- **File shelf:** a floating panel with received files and a drop zone for sending.
  - It can open by itself when files arrive.
  - Drag it anywhere.
  - Clear its list.
- **Use AirDrop too:**
  - Edge drops go over AirDrop when SideDrop isn't open on the phone.
  - Regular AirDrop arrivals get the same glow, wave and fly-in.
- **Calibration** (iPhone tab):
  - Which side the iPhone sits on. This is also learned from how you swipe.
  - Which screen glows, with **Preview glow** to check.
  - **Photo size on the Mac** and **iPhone height along the edge**, so a photo continues seamlessly from one screen to the other.

---

## Deck: the iPhone as a remote for the Mac

Open **Deck** in SideDrop and swipe between five pages. It refreshes every second, and while it isn't connected it shows "Hold your iPhone next to your Mac".

### 1. Control
- Each of the four corners of the phone controls one setting on the Mac. Drag up or down in that corner:

  | Corner | Controls |
  |---|---|
  | Top left | Brightness |
  | Top right | Light / Dark mode |
  | Bottom left | Volume |
  | Bottom right | Keyboard backlight |

- Tick marks run around each corner and light up to the current value.
- A big number shows while you drag, with haptic ticks.

### 2. Launch
- Your Mac's dock apps as a grid.
- **Tap or flick an app up** to throw it onto the Mac's screen, where it opens.

### 3. Windows
- **Apps view:** one card for each open app on the Mac (including minimised ones and ones on other Spaces), with:
  - **Bring to front**
  - **Minimise** all its windows
  - **Maximise** to fill a screen; with several screens, you pick which one
- **Split 50/50 view:**
  - Each Mac screen is a card split in two. Pick an app for the left half and one for the right, then press **Split**.
  - Pick just one app and **Fill** gives it the whole screen.
  - It handles apps that resist resizing (full-screen windows, Chrome/Electron).
- A toast shows what happened.

### 4. Shelf (widgets)
- **Now Playing:** controls **Spotify** or **Apple Music** on the Mac.
  - SideDrop talks to whichever one is running (Spotify first) and never launches either.
  - The widget shows the title, artist and album cover, with green equaliser bars that dance while music plays.
  - **Play/Pause, Next, Previous.**
  - Tap the cover or the title for the **full-screen player**:
    - Big cover over a blurred background.
    - Progress bar with elapsed and remaining time.
    - Play/Pause, Next, Previous.
    - **Synced lyrics** from [LRCLIB](https://lrclib.net). The current line is highlighted and scrolls with the song. Plain lyrics show when no synced version exists. Only the title and artist are sent to LRCLIB.
  - Works upright and sideways.
- **Timer:** drag along the ticks to set 1–60 minutes, then Play/Pause or Reset. A haptic plays when it finishes.
- **Claude Code / Codex:** one card per agent showing:
  - Whether it's **Working…**, **Waiting for you** or **Idle**
  - The project
  - The last thing it said
  
  Tap a card to bring its terminal or editor to the front on the Mac.
- **Long-press** the background to switch the widgets between dark and light.
- **Layout:** stacked when the phone is upright; square cards in a row, two per screen, when it's sideways.

### 5. Creative Pro
Bring a supported app to the front on the Mac, and its tools appear on the phone:

| App | Tool buttons | Jog wheels | Extras |
|---|---|---|---|
| **Photoshop** | Move, Brush, Eraser, Lasso, Crop, Swap colours, Undo, Redo | Brush size, Zoom | Exact **opacity** slider (1–100 %), **foreground colour** (picker + swatches) |
| **Illustrator** | Select, Direct select, Pen, Type, Rectangle, Ellipse, Undo, Redo | Zoom, Nudge | **Fill colour** of the selection |
| **After Effects** | Select, Hand, Pen, Text, Play, Split layer, Undo, Redo | Frame step, Timeline zoom | |
| **Premiere Pro** | Select, Razor, Ripple, Hand, Play, Add edit, Undo, Redo | Frame step, Timeline zoom | |
| **Blender** | Grab, Rotate, Scale, Extrude, Edit mode, Render, Undo, Redo | Frame step | |

**Jog wheels** are rulers you drag sideways. Every notch sends one step, with a haptic tick.

---

## Build

```sh
./build.sh            # build the Mac app into build/
./build.sh install    # build, install to /Applications and launch
./build.sh release    # Developer ID signed + Apple-notarized build/release/SideDock.dmg
```

For the iPhone app, open `iOS/SideDrop.xcodeproj` in Xcode and run it on a device. It includes the SideDropShare extension.

## Permissions

| Permission | Used for |
|---|---|
| Accessibility | Hidden Dock calibration, keeping windows clear, Deck window management, Creative Pro keystrokes |
| Automation | Spotify/Music control, light/dark mode, Photoshop/Illustrator colours, emptying the Trash |
| Bluetooth + Local Network | Finding and connecting to the iPhone |
| Photos (iPhone) | Recent grid and sending photos/videos |
| Full Disk Access (optional) | Showing whether the Trash is full |

## Diagnostics

```sh
log show --last 10m --info --predicate 'subsystem == "local.sidedock"'
```
