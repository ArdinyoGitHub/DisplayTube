# DisplayTube for Linux

Turns an Android phone into an extended second screen over a USB cable (adb). It works with any desktop (GNOME, KDE, wlroots, X11) and any graphics card (AMD and Intel via VAAPI, NVIDIA via NVENC, software x264 as a fallback).

## Installation

```
tar xf DisplayTube-v0.3-linux.tar.gz
cd DisplayTube-v0.3-linux
./install.sh
```

The installer downloads and installs what DisplayTube needs:
- the EVDI virtual display driver
- adb and the phone USB rules
- the FFmpeg libraries and a VAAPI driver for your graphics card
- build tools and kernel headers

It then builds DisplayTube and installs it under `/usr/local`. Supported distributions: Arch and derivatives, Debian/Ubuntu, Fedora, openSUSE. On other distributions it lists the missing components.

If a step fails (no internet, a package missing from the repositories, EVDI not building for the kernel), the installer does not stop. At the end it lists what is missing and how to fix it, and shows a desktop notification. The full log is at `~/.cache/displaytube/install.log`. When you run it again, components that are already installed are skipped.

Options: `--yes` (no questions), `--autostart` / `--no-autostart`, `--dry-run` (show what would be done without changing anything), `--uninstall`.

## Usage

1. Turn on USB debugging on the phone and connect the cable.
2. Start DisplayTube from the application menu, or run `systemctl --user start displaytube`.
3. On the first connection, DisplayTube installs the receiver app on the phone and opens it. The virtual display appears as a new monitor in your display settings.

Check: `displaytube --check`. Logs: `journalctl --user -u displaytube -f`.

## Touch and sound (receiver app 0.4+)

- **Mouse mode (default):** the phone works like a touchpad on top of the picture: tap = left click,
  touch and hold = right click, drag = drag, two-finger swipe = scroll (also sideways), two-finger tap = right click.
  DisplayTube creates a virtual absolute mouse (`DTB DisplayTube Mouse`) through `/dev/uinput` and finds where the
  DisplayTube monitor is with the standard `xdg-output` Wayland protocol, so no desktop setting is needed.
  Mouse mode needs a Wayland session; use touch mode on X11.
- **Touch mode (`--input touch`):** native multi-touch instead of mouse clicks (long press does what the desktop decides,
  e.g. KDE's edit mode). DisplayTube creates a virtual multi-touch screen
  (`DTB DisplayTube Touchscreen`) through `/dev/uinput`. The installer adds a udev rule
  (`/etc/udev/rules.d/70-displaytube.rules`) that lets the logged-in user use `/dev/uinput` and maps the
  touchscreen to the DisplayTube monitor (`WL_OUTPUT`, used by KWin, Weston and other libinput-based compositors).
  KDE Plasma 6 ignores `WL_OUTPUT`: map it once in System Settings → Touchscreen (choose the DisplayTube monitor);
  KDE remembers it. On other desktops, if touches land on the wrong monitor, map the touchscreen to the
  DisplayTube monitor in the desktop's touchscreen settings. Turn input off with `--input off`.
- **Sound:** while the phone is connected, a new sound output named **DisplayTube** appears (like the speakers of an
  HDMI monitor). Choose it in your sound settings to play sound on the phone. Works with PipeWire and PulseAudio.
  `--audio mirror` plays the PC's current output on the phone as well; `--audio off` turns sound off.

## Notes

- **Performance:** the compositor copies every frame of the virtual monitor from the graphics card to EVDI.
  At the phone's full resolution this copy can make the whole desktop stutter (measured on KDE Plasma 6.8 / RX 6700 XT:
  the virtual monitor got 6 FPS on average and the mouse lagged). DisplayTube therefore uses 67% of the phone's
  resolution by default (`--scale 67`); the phone upscales in hardware and text stays sharp. `--scale 100` gives full
  resolution, `--scale 50` the lightest load.
- If Secure Boot is enabled, the EVDI module must be signed. The installer explains how when this is the problem.
- On Fedora, H.264 hardware encoding requires RPM Fusion.
