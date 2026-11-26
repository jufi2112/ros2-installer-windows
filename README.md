# ROS 2 Humble installer for Windows 11

This project installs the native x64 Windows binaries from [Humble Patch Release 14](https://github.com/ros2/ros2/releases/tag/release-humble-20260220). Setup uses the Python 3.10 and native dependencies pinned by the Pixi lock included in that release. Upstream Humble targeted Windows 10. See the test commands below for Windows 11 and Windows Server Core coverage.

## Install ROS 2

Open `Ros2HumbleSetup.exe`. Choose the installation folder, DDS backend, optional components, and shortcuts, then review the installation plan. Cyclone DDS is selected by default. Fast DDS is available in the same menu.

**Transparency Mode** is on by default. Confirm each step after reading what it will do, or abort to stop before the next step. If a vendor installer is already running, setup waits for it to exit. The wizard shows current and overall progress. Downloads show transferred data and an estimated time remaining when their total size is known. Overall progress counts the steps in the selected plan. Completed changes are listed at the end. Running setup again checks the installation and reuses compatible prerequisites. Existing folders that belong to another installation are protected.

The default folder is `C:\dev\ros2_humble`. Choose a folder your account can write to. Windows may prompt for elevation to install the Visual C++ runtime or optional Visual Studio Build Tools. The ROS command prompt sets the Python and DDS environment for that shell. Open it from a shortcut, or run this from Command Prompt:

```cmd
call "C:\dev\ros2_humble\ros-humble.cmd"
```

Run `Ros2HumbleCli.exe --help` for headless options. Both interfaces share the same installation engine. Use `--print-plan` to review or use `--headless --accept-plan` to run unattended. If Windows requests a restart, reboot manually and rerun setup.

### WalkableOR Point Cloud Receiver

The receiver is selected by default. Setup builds the [pinned WalkableOR fork of ROS-TCP-Endpoint](https://github.com/jufi2112/ROS-TCP-Endpoint/tree/91be0b80cc6c114f48304f4d42491ac3507a5a18) in `pointcloud_receiver` under the selected ROS folder using the private Python environment. Clear the checkbox or pass `--no-walkableor-receiver` to skip the receiver. Building the receiver requires the Python colcon tools and works with the C++ development option cleared.

Choose a local `walkableOR_unity` checkout and setup will copy its current `pointcloud_receiver\configs\walkableOR.yaml` into the installed receiver. If you choose to supply the file later, setup shows the destination `<ROS installation folder>\pointcloud_receiver\configs\walkableOR.yaml`. Select **Replace an existing receiver configuration** if you want setup to overwrite a different installed copy. The CLI equivalents are `--walkableor-project PATH` and `--replace-walkableor-config`.

Once the configuration is in place, open **Start Point Cloud Receiver** on the desktop. The terminal shows the config path, selected DDS backend, and receiver logs. Close the terminal or press **Ctrl+C** to stop the receiver. The receiver listens on all IPv4 interfaces on port `10000`. Configure Unity for ROS 2 at `127.0.0.1:10000` on the receiver PC, or use the receiver PC's LAN address from another machine.

The receiver uses the Windows network for ROS discovery and defaults to domain `0`. To use a different publisher domain, open Command Prompt, set `ROS_DOMAIN_ID` to the publisher's domain, and call `pointcloud_receiver\start-receiver.cmd` from the ROS installation folder.

## Uninstall

Open **Uninstall ROS 2 Humble.cmd** in the ROS installation folder. The confirmation dialog shows the exact folder. Click **Yes** to remove it and its contents, including the installed WalkableOR YAML and any files you added. If the receiver or ROS command prompts from that installation are still running, setup lists them and resumes automatically when they close. You can cancel while it waits.

Setup removes the Start menu and desktop shortcuts that still point to that installation. A completion dialog appears once removal succeeds. The shared Visual C++ Redistributable, Visual Studio Build Tools, and Windows SDK stay installed. The uninstaller uses Windows PowerShell and honors script restrictions enforced by Group Policy.

## Build

From the root of a fresh Windows x64 checkout, run:

```powershell
.\prepare.ps1
.\build.ps1
```

`prepare.ps1` downloads Microsoft's pinned .NET SDK 10.0.404 ZIP, verifies its SHA-512 checksum, and extracts it to `build\sdk`. It restores the Windows x64 NuGet dependencies for the installer, CLI, and preview into `build\nuget`. You can rerun it to reuse the SDK and restore missing packages. The first preparation needs access to Microsoft's download service and NuGet. The SDK is local to the checkout and needs no administrator access or PATH changes.

The build also supports these modes:

```powershell
.\build.ps1                 # Online wizard and CLI in dist\online
.\build.ps1 -PreviewOnly    # Simulation-only wizard in dist\preview
.\build.ps1 -BuildOffline   # Also creates dist\ros2-humble-offline-win-x64.zip
```

The build looks for a compatible SDK at `build\sdk\dotnet.exe` first, then checks `dotnet.exe` on `PATH`. If you already have .NET 10 or newer, you can build directly and let the build restore its NuGet dependencies. Pass `-Dotnet` to use a specific SDK executable.

The online installer downloads ROS, the WalkableOR endpoint, and the selected runtime dependencies when it runs. The opt-in offline build downloads those payloads and creates Microsoft's Visual Studio 2019 C++ Build Tools layout inside a Hyper-V-isolated Server Core container. For that mode, have a Windows Docker engine running and run `.\build.ps1 -BuildOffline` with internet access. The resulting ZIP includes the payloads for every menu option and can be several gigabytes. Downloaded files and build output are ignored by Git. Review the upstream redistribution terms for any bundle you publish.

On the disconnected PC, extract the full ZIP and launch setup from the extracted folder. Keep `offline.json` and `payload` beside the executables. The installer verifies the packages for the chosen options against their checksums and uses local package sources. The WalkableOR payload contains the pinned endpoint build inputs. You can select a local checkout or supply the YAML later in offline mode too. The headless CLI can enforce offline mode with `--offline`.

## Installation Paths
The following is an overview about what gets put where on the filesystem during installation, `<ROS>` is the selected installation location:
| Installer option | What it installs or configures | Filesystem location |
|---|---|---|
| **ROS 2 Humble** · always installed | Humble Patch Release 14 x64, including the ROS CLI, libraries, Python packages, setup scripts, and both DDS backends | `<ROS>` directly. The CLI is at `<ROS>\Scripts\ros2.exe`, and native DLLs are under `<ROS>\bin`. |
| **Private Python and ROS dependencies** · always installed | Python **3.10.6**, pip, setuptools, OpenSSL, NumPy, PyYAML, and the other runtime dependencies from the release lockfile | `<Pixi>`. Python is at `<Pixi>\python.exe`, Python packages are under `<Pixi>\Lib\site-packages`, and native runtime DLLs are under `<Pixi>\Library\bin`. |
| **Microsoft Visual C++ x64 Redistributable** · installed if needed | Shared Windows runtime DLLs, including `msvcp140.dll` and `vcruntime140_1.dll` | `%SystemRoot%\System32`, normally `C:\Windows\System32`. Microsoft’s installer manages the files. |
| **DDS backend** · Cyclone DDS by default | Sets `RMW_IMPLEMENTATION` to `rmw_cyclonedds_cpp` or `rmw_fastrtps_cpp`. Both are shipped in the base ROS archive. | The selection is written to `<ROS>\ros-humble.cmd`. The WalkableOR launcher inherits it. |
| **C++ development tools** | CMake 3.22.2, colcon extensions, Eigen, benchmark, CUnit, Cppcheck, Git, vcstool, and pybind11. If needed, also installs Visual Studio 2019 Build Tools with MSVC v142 and Windows SDK 10.0.19041. | Conda tools go into `<Pixi>`. Microsoft’s typical locations are `%ProgramFiles(x86)%\Microsoft Visual Studio\2019\BuildTools` and `%ProgramFiles(x86)%\Windows Kits\10`. A compatible existing toolchain is reused at its current location. |
| **Qt visualization tools** | Qt 5.12.9, PyQt 5.12.3, Assimp, and Bullet. The base ROS archive already provides the RViz executable. | Dependencies go into `<Pixi>`, with Qt platform plugins under `<Pixi>\Library\plugins\platforms`. RViz is at `<ROS>\bin\rviz2.exe`. |
| **Graphviz for `rqt_graph`** | Graphviz 2.46.1, `pydot`, and `pygraphviz`, plus the Qt visualization dependencies | `<Pixi>`. The Graphviz `dot.exe` is at `<Pixi>\Library\bin\dot.exe`. |
| **OpenCV examples** | OpenCV 4.5.5 native libraries and Python bindings | `<Pixi>`, with native libraries under `Library\bin` and Python bindings under `Lib\site-packages`. |
| **WalkableOR Point Cloud Receiver** · on by default | Pinned ROS TCP Endpoint source, a built ROS overlay, a receiver launcher, and a desktop shortcut. Adds the Python colcon tools even when C++ development tools are off. | Source at `<ROS>\pointcloud_receiver\src\ROS-TCP-Endpoint`, built overlay under `pointcloud_receiver\install`, and launcher at `pointcloud_receiver\start-receiver.cmd`. Colcon goes into `<Pixi>`. The shortcut is `Start Point Cloud Receiver.lnk` on the current user’s desktop. |
| **Use a local WalkableOR project** | Copies the checkout’s `pointcloud_receiver\configs\walkableOR.yaml`. A different installed copy requires explicit replacement approval. | `<ROS>\pointcloud_receiver\configs\walkableOR.yaml` |
| **Supply the WalkableOR config later** | Prepares the config folder and shows the destination in the completion message. | `<ROS>\pointcloud_receiver\configs\` |
| **ROS Command Prompt in Start menu** · on by default | A shortcut to `<ROS>\ros-humble.cmd` | `%APPDATA%\Microsoft\Windows\Start Menu\Programs\ROS 2 Humble Command Prompt.lnk`, using the current user’s Windows Programs folder. |
| **ROS Command Prompt on desktop** · off by default | A shortcut to `<ROS>\ros-humble.cmd` | `ROS 2 Humble Command Prompt.lnk` in the current user’s Windows desktop folder, which may be redirected to OneDrive or another location. |
| **Transparency Mode** · on by default | Prompts before each installation step | Uses the same destinations listed above. |
