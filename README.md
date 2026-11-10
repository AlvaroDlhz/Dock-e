# Dock-e

Dock-e is a floating desktop dock for Linux based on
[Plank](https://launchpad.net/plank). It retains Plank's window integration,
rendering engine, and Vala architecture while extending the interface with a
built-in application launcher, a background applications list, and a system
update indicator.

The goal is to provide a compact, visually consistent dock whose core features
do not depend on external launchers or desktop panels.

## Current State

The dock spans nearly the full width of the screen while preserving side and
bottom margins to create a floating appearance. Its contents are divided into
fixed sections:

- **Launcher button:** opens the native application launcher.
- **Applications:** pinned applications and open windows, with a configurable
  hover zoom, launch and attention bounces, window previews, and indicators
  that split when an application has several windows open.
- **Dock actions:** the system update manager and the background applications
  toggle.

## Native Application Launcher

The Dock-e button opens an application launcher built directly into the
project. It includes:

- Fuzzy search across installed applications, next to the user's avatar.
- An alphabetical catalog with section headers.
- Commands, typed with a leading `/`: `/preferences`, `/lock`, `/suspend`,
  `/logout`, `/restart`, and `/poweroff` (Spanish aliases such as `/apagar`
  work as well). They replace the former power button.
- An inline calculator whose result can be copied with Enter.
- Per-application actions: copy the launch, terminate, restart, or uninstall
  command, and uninstall packages installed through dpkg, rpm, Flatpak, or Snap.
- Full mouse and keyboard navigation.

Session commands currently rely on `xflock4` and `xfce4-session-logout`, so
they require an XFCE session.

## Background Applications and Updates

- **Background applications:** a tray replacement that lists applications
  still running without a window (StatusNotifier and XApp status icons, such as
  Discord or Telegram) and highlights the ones that need attention.
- **Update manager:** shows the number of pending system updates and opens the
  system's update application. Update checks currently use `apt`.

The former volume, Bluetooth, Wi-Fi, battery, and clock panels were removed
from the dock, along with their backends.

## Animations

The **Animations** page of the preferences window (`/preferences` in the
launcher) controls how application icons move:

- Zoom on hover, and how much (100–150%).
- Bounce on launch.
- Bounce when an application needs attention, optionally repeating until it is
  focused.
- Animation speed (slow, normal, fast).
- Reduce motion, which disables icon zoom and bounces altogether.

The settings are stored per dock in GSettings
(`net.launchpad.plank.dock.settings`).

## Project Structure

```text
data/
  menu-2.svg                    Launcher button artwork
  plank.gresource.xml           Resources embedded in the binary
  net.launchpad.plank.gschema.xml.in   Dock settings schema
  ui/preferences.ui             Preferences window layout
  themes/                       Dock themes and visual settings

lib/
  DockController.vala           Creates and coordinates the dock and its providers
  DockRenderer.vala             Rendering, visual states, and animations
  PositionManager.vala          Geometry for the dock's sections
  HideManager.vala              Auto-hide behavior
  DockPreferences.vala          Per-dock settings

  Items/
    LauncherItem.vala           Fixed launcher button and fixed item providers
    ApplicationDockItem.vala    Pinned applications and open windows
    TrayToggleItem.vala         Background applications toggle, tray items, and list
    UpdateManagerItem.vala      System update indicator

  Widgets/
    DockWindow.vala             Main window and pointer input handling
    LauncherWindow.vala         Native application launcher and commands
    HoverWindow.vala            Item labels shown on hover
    PreferencesWindow.vala      Preferences window

  Services/
    CommandRunner.vala          Cancellable asynchronous command execution
    UpdateService.vala          Pending update checks
    ApplicationUninstallService.vala   Package owner detection for uninstalls
    CalculatorService.vala      Launcher calculator

docklets/                       Docklets inherited from Plank
scripts/                        Build, test, and run helpers
src/                            Application entry point
tests/                          Test suite and supporting test components
vapi/                           Vala interface definitions
```

## Building

Dock-e uses Autotools, Vala, and GTK 3, and runs on X11. On a system with
Plank's build dependencies installed, the helper scripts build out of tree in
`.build/`:

```bash
scripts/build-dock-e    # configure (first run) and build
scripts/test-dock-e     # build and run the test suite (uses xvfb-run if present)
scripts/run-dock-e      # run the local build without installing it
scripts/clean-dock-e    # remove the build's generated files
```

If `configure` is missing, generate it first with `./autogen.sh` and remove the
in-source configuration it leaves behind with `make distclean`.

## Origin and License

Dock-e is based on Plank and remains licensed under the **GNU General Public
License, version 3 or later**. Existing copyright and attribution notices from
the original codebase are preserved.

Historical documentation and contribution guidelines for the upstream codebase
are available in `HACKING` and through the original Plank project.
