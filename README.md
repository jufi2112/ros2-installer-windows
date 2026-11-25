# ROS 2 Humble installer for Windows 11

This project installs the native x64 Windows binaries from [Humble Patch Release 14](https://github.com/ros2/ros2/releases/tag/release-humble-20260220). Setup uses the Python 3.10 and native dependencies pinned by the Pixi lock included in that release. Upstream Humble targeted Windows 10. See the test commands below for Windows 11 and Windows Server Core coverage.

## Install ROS 2

Open `Ros2HumbleSetup.exe`. Choose the installation folder, DDS backend, optional components, and shortcuts, then review the installation plan. Cyclone DDS is selected by default. Fast DDS is available in the same menu.

**Transparency Mode** is on by default. Confirm each step after reading what it will do, or abort to stop before the next step. If a vendor installer is already running, setup waits for it to exit. Completed changes are listed at the end. Running setup again checks the installation and reuses compatible prerequisites. Existing folders that belong to another installation are protected.

The default folder is `C:\dev\ros2_humble`. Choose a folder your account can write to. Windows may prompt for elevation to install the Visual C++ runtime or optional Visual Studio Build Tools. The ROS command prompt sets the Python and DDS environment for that shell. Open it from a shortcut, or run this from Command Prompt:

```cmd
call "C:\dev\ros2_humble\ros-humble.cmd"
```

Run `Ros2HumbleCli.exe --help` for headless options. Both interfaces share the same installation engine. Use `--print-plan` to review or use `--headless --accept-plan` to run unattended. If Windows requests a restart, reboot manually and rerun setup.

## Build

Run these commands in PowerShell with the .NET 10 SDK available:

```powershell
.\build.ps1                 # Online wizard and CLI in dist\online
.\build.ps1 -PreviewOnly    # Simulation-only wizard in dist\preview
.\build.ps1 -BuildOffline   # Also creates dist\ros2-humble-offline-win-x64.zip
```

Pass `-Dotnet` with the path to an SDK executable if needed. The online build downloads .NET build dependencies. ROS packages are fetched when the online installer runs.

The opt-in offline build uses an active Windows Docker engine to download the pinned ROS packages and create Microsoft's Visual Studio 2019 C++ Build Tools layout inside a Hyper-V-isolated Server Core container. The resulting ZIP includes the payloads for every menu option and can be several gigabytes. Downloaded files and build output are ignored by Git. Review the upstream redistribution terms for any bundle you publish.

On the disconnected PC, extract the full ZIP and launch setup from the extracted folder. Keep `offline.json` and `payload` beside the executables. The installer verifies the packages for the chosen options against their checksums and uses local package sources. The headless CLI can enforce offline mode with `--offline`.

## Verify

- **Wizard on Windows 11.** Run `.\tests\preview.ps1` after building the preview, or open `dist\preview\Ros2HumblePreview.exe` and try the defaults, review, step prompts, abort, and automatic progression. Enter `fail` in the destination field to see the error flow. This executable shares the wizard views and uses an in-memory simulator.
- **Online installation in Docker.** With Windows containers active, run `.\tests\container.ps1`. It uses a disposable Hyper-V-isolated Windows Server Core container with no host mounts. It checks launcher and shortcut contents and requires a C++ talker and Python listener to exchange messages with each DDS backend.
- **Offline installation in Docker.** Run `.\tests\container.ps1 -Offline -Artifacts PATH_TO_EXTRACTED_BUNDLE`. It disables external networking, tests missing and corrupt payloads, installs all components, repeats the DDS checks, and builds a small C++ package.
- **Windows 11 desktop integration.** Real UAC interaction, launching created shortcuts in Explorer, and rendering ROS graphical tools require a Windows 11 desktop for end-to-end verification.
