# Third-party notices

DisplayTube includes or uses the following third-party components. Each is the property of its respective authors and is used under its own license.

| Component | Use | License | Source |
|---|---|---|---|
| Virtual Display Driver (MttVDD) | Bundled in `driver/` and installed with the user's consent | MIT | https://github.com/VirtualDrivers/Virtual-Display-Driver |
| Vortice.Windows (Vortice.Direct3D11, Vortice.DXGI, Vortice.MediaFoundation, Vortice.DirectX, Vortice.Mathematics) | Compiled into `DisplayTube.exe` | MIT | https://github.com/amerkoleci/Vortice.Windows |
| SharpGen.Runtime, SharpGen.Runtime.COM | Compiled into `DisplayTube.exe` | MIT | https://github.com/SharpGenTools/SharpGenTools |
| .NET runtime (self-contained) | Compiled into `DisplayTube.exe` | MIT | https://github.com/dotnet/runtime |
| Android SDK Platform-Tools (adb) | **Not bundled.** Downloaded by the user's choice from Google (`dl.google.com`) on first run, or an existing installation is used | Android Software Development Kit License Agreement | https://developer.android.com/tools/releases/platform-tools |

The full license texts are available at the source links above. The Virtual Display Driver's signing certificate (`driver/Virtual_Display_Driver.cer`) is added to the Windows trusted certificate stores during driver installation, after the user confirms. This is the installation method the driver's authors provide.

## Linux

The Linux package contains only DisplayTube's own source code and the Android receiver. Everything below is **not bundled**: the installer (`install.sh`) downloads it from the distribution's package repositories, or from the upstream project where noted.

| Component | Use | License | Source |
|---|---|---|---|
| EVDI (kernel module and libevdi) | Virtual display. Arch: AUR package `evdi-dkms`. Other distributions: upstream source release, checked against a pinned SHA-256 and built with DKMS | Module GPL-2.0, library LGPL-2.1 (linked dynamically) | https://github.com/DisplayLink/evdi |
| FFmpeg (libavcodec, libavfilter, libavutil, libswscale) | H.264 encoding (VAAPI / NVENC / x264). Linked dynamically from the distribution | LGPL-2.1+ or GPL-2.0+, depending on the distribution's build | https://ffmpeg.org |
| adb (android-tools) | Phone connection over USB | Apache-2.0 | https://android.googlesource.com/platform/packages/modules/adb |
