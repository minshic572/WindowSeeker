# WindowSeeker

A tiny macOS utility that lists **every window** — including minimized ones and
windows parked on another Space — and lets you bring any of them back with one click.

The app's display name is 窗口总览 ("Window Overview").

## Why

On macOS it is surprisingly easy to lose a window. A video player keeps playing
audio with no visible window; a window gets minimized into a list you can't open;
a window is sitting on a Space you're not looking at. The Dock menu and `Cmd+Tab`
don't help — they only show *applications*, not *windows*.

WindowSeeker reads the real state of every window and gives you one flat list.

## Features

- Lists all windows of all running apps, grouped by application
- Labels windows that are **minimized** or **on another Space**
- Shows each window's pixel size and lets you search by title or app name
- Three inline buttons on every row:
  - **Bring to front** — un-minimize, activate the app, raise the window
  - **Minimize**
  - **Close** — presses the window's own close button, so applications can still
    show their "save changes?" prompt (it does not kill the process)

## Requirements

- macOS 13 Ventura or later
- **Apple Silicon** (arm64). Intel support exists but is untested — see below.
- Accessibility permission (see below)

## Building

No Xcode project — a plain `swiftc` build:

```bash
./build.sh          # compile, ad-hoc sign, install to /Applications/WindowSeeker.app, launch
```

The script targets `arm64` by default. To build for Intel explicitly:

```bash
TARGET_ARCH=x86_64 ./build.sh
```

For a universal binary, compile both architectures and merge them with
`lipo -create`.

### Icon

The icon is generated programmatically, so there is no binary asset to edit:

```bash
./make_icon.sh      # re-draws from draw_icon.swift and installs the .icns
```

## Accessibility permission

WindowSeeker uses the Accessibility API to inspect and control windows, so macOS
will ask you to grant it under
**System Settings → Privacy & Security → Accessibility**.

Without the permission the list stays empty. Grant it once and the app refreshes
itself automatically.

> **Re-signing note.** The app is signed ad-hoc (`codesign --sign -`), so its
> identity *is* the binary hash. If you rebuild the binary, macOS treats it as a
> different app and you have to grant Accessibility again:
>
> ```bash
> tccutil reset Accessibility local.tools.windowseeker
> ```

## How it works

- **CoreGraphics** — `CGWindowListCopyWindowInfo` provides ground truth about
  which windows are actually on screen, their layer, and their bounds.
- **Accessibility API** — used to un-minimize, raise, minimize and close windows.
- To map an accessibility element to its `CGWindowID`, the app dynamically loads
  the private symbol `_AXUIElementGetWindow`. If that symbol is unavailable it
  degrades gracefully to the AX-reported size.

## Known limitations

- Uses a **private Apple symbol** (`_AXUIElementGetWindow`). This is why the app
  cannot ship on the Mac App Store, and why a future macOS release could break the
  window↔element mapping. The fallback path keeps the list working regardless.
- Floating or utility windows that have no close button cannot be closed through
  this app.
- Only architecture-tested on Apple Silicon. Intel builds should work (nothing in
  the code is architecture-specific) but have not been verified on real hardware —
  PRs welcome.

## License

MIT — see [LICENSE](LICENSE).

Code and icon are original work. The icon is drawn programmatically by
`draw_icon.swift`; it is not a third-party asset.
