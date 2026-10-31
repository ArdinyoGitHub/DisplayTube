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

## Notes

- If Secure Boot is enabled, the EVDI module must be signed. The installer explains how when this is the problem.
- On Fedora, H.264 hardware encoding requires RPM Fusion.
