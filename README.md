# Dock-e

Dock-e is a floating desktop dock for Linux based on
[Plank](https://launchpad.net/plank). It retains Plank's window integration,
rendering engine, and Vala architecture while extending the interface with a
built-in application launcher and native system controls.

The goal is to provide a compact, visually consistent dock whose core features
do not depend on external launchers or desktop panels.

## Current State

The dock spans nearly the full width of the screen while preserving side and
bottom margins to create a floating appearance. Its contents are divided into
three sections:

- **Left:** the Dock-e button and native application launcher.
- **Center:** pinned applications and open windows, with animated magnification,
  solid indicators for active applications, and interaction areas that extend
  all the way to the bottom edge.
- **Right:** volume, Bluetooth, Wi-Fi, battery, and clock indicators.

## Native Application Launcher

The Dock-e button opens an application launcher built directly into the
project. It includes:

- Fuzzy search across installed applications.
- **Frequently used** and **All** tabs.
- Persistent application usage tracking.
- An alphabetical catalog with section dividers.
- Full mouse and keyboard navigation.
- Session controls for locking, suspending, logging out, restarting, and
  powering off the system.
- Stable dimensions and positioning above the dock.

The button artwork is stored in `data/dock-menu.jpg` and embedded in the binary
through GLib resources.

## Native System Panels

The indicators on the right use a shared native window instead of relying on
the visual appearance of standard GTK menus. Its contents change according to
the selected indicator:

- **Volume:** output device selection, output volume and mute controls,
  microphone input controls, per-application volume, and access to advanced
  sound settings.
- **Bluetooth:** power control and paired devices.
- **Wi-Fi:** power control and detected networks.
- **Battery:** charge percentage and charging state.
- **Clock:** current date and calendar.

These panels keep the dock visible while they are in use and share the same
background, borders, spacing, and positioning.

## Project Structure

```text
data/
  dock-menu.jpg                 Main button artwork
  plank.gresource.xml           Resources embedded in the binary
  themes/                       Dock themes and visual settings

lib/
  DockController.vala           Creates and coordinates the dock and panels
  DockRenderer.vala             Rendering, visual states, and animations
  PositionManager.vala          Geometry for the dock's three sections
  HideManager.vala              Auto-hide behavior and panel inhibition

  Items/
    LauncherItem.vala           Fixed Dock-e launcher button
    StatusIndicatorItem.vala    Volume, network, battery, and clock indicators
    ApplicationDockItem.vala    Pinned applications and open windows

  Widgets/
    DockWindow.vala             Main window and pointer input handling
    LauncherWindow.vala         Native application launcher
    StatusPanelWindow.vala      Shared panel for native system controls

docklets/                       Docklets inherited from Plank
src/                            Application entry point
tests/                          Test suite and supporting test components
vapi/                           Vala interface definitions
```

The main execution flow is:

1. `DockController` creates the dock window and registers its fixed providers.
2. `PositionManager` separates the launcher button, applications, and system
   indicators.
3. `DockRenderer` draws each section and animates its visual states.
4. `DockWindow` routes input to either `LauncherWindow` or
   `StatusPanelWindow`.
5. The native panels interact with desktop services through PipeWire and
   WirePlumber, PulseAudio, NetworkManager, BlueZ, and XFCE Power Manager.

## Building

Dock-e uses Autotools, Vala, and GTK 3. On a system with Plank's build
dependencies installed, run:

```bash
./autogen.sh
make -j$(nproc)
```

To run the local build without installing it:

```bash
LD_LIBRARY_PATH="$PWD/lib/.libs" "$PWD/src/.libs/plank" -n dev -d
```

## Origin and License

Dock-e is based on Plank and remains licensed under the **GNU General Public
License, version 3 or later**. Existing copyright and attribution notices from
the original codebase are preserved.

Historical documentation and contribution guidelines for the upstream codebase
are available in `HACKING` and through the original Plank project.
