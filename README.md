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

### WalkableOR Point Cloud Receiver

The receiver is selected by default. Setup builds the [pinned WalkableOR fork of ROS-TCP-Endpoint](https://github.com/jufi2112/ROS-TCP-Endpoint/tree/91be0b80cc6c114f48304f4d42491ac3507a5a18) in `pointcloud_receiver` under the selected ROS folder using the private Python environment. Clear the checkbox or pass `--no-walkableor-receiver` to skip the receiver. Building the receiver requires the Python colcon tools and works with the C++ development option cleared.

Choose a local `walkableOR_unity` checkout and setup will copy its current `pointcloud_receiver\configs\walkableOR.yaml` into the installed receiver. If you choose to supply the file later, setup shows the destination `<ROS installation folder>\pointcloud_receiver\configs\walkableOR.yaml`. Select **Replace an existing receiver configuration** if you want setup to overwrite a different installed copy. The CLI equivalents are `--walkableor-project PATH` and `--replace-walkableor-config`.

Once the configuration is in place, open **Start Point Cloud Receiver** on the desktop. The terminal shows the config path, selected DDS backend, and receiver logs. Close the terminal or press **Ctrl+C** to stop the receiver. Configure Unity on this PC for ROS 2 at `127.0.0.1:10000`.

The receiver uses the Windows network for ROS discovery and defaults to domain `0`. To use a different publisher domain, open Command Prompt, set `ROS_DOMAIN_ID` to the publisher's domain, and call `pointcloud_receiver\start-receiver.cmd` from the ROS installation folder.

## Build

Run these commands in PowerShell with the .NET 10 SDK available:

```powershell
.\build.ps1                 # Online wizard and CLI in dist\online
.\build.ps1 -PreviewOnly    # Simulation-only wizard in dist\preview
.\build.ps1 -BuildOffline   # Also creates dist\ros2-humble-offline-win-x64.zip
```

Pass `-Dotnet` with the path to an SDK executable if needed. The online build downloads .NET build dependencies. ROS packages are fetched when the online installer runs.

The opt-in offline build uses an active Windows Docker engine to download the pinned ROS packages and create Microsoft's Visual Studio 2019 C++ Build Tools layout inside a Hyper-V-isolated Server Core container. The resulting ZIP includes the payloads for every menu option and can be several gigabytes. Downloaded files and build output are ignored by Git. Review the upstream redistribution terms for any bundle you publish.

On the disconnected PC, extract the full ZIP and launch setup from the extracted folder. Keep `offline.json` and `payload` beside the executables. The installer verifies the packages for the chosen options against their checksums and uses local package sources. The WalkableOR payload contains the pinned endpoint build inputs. You can select a local checkout or supply the YAML later in offline mode too. The headless CLI can enforce offline mode with `--offline`.

## Verify

- **Wizard on Windows 11.** Run `.\tests\preview.ps1` after building the preview, or open `dist\preview\Ros2HumblePreview.exe` and try the defaults, review, step prompts, abort, and automatic progression. Enter `fail` in the destination field to see the error flow. This executable shares the wizard views and uses an in-memory simulator.
- **Online installation in Docker.** With Windows containers active, run `.\tests\container.ps1`. It uses a disposable Hyper-V-isolated Windows Server Core container with no host mounts. It checks the base ROS demos and the WalkableOR Unity handshake for both DDS backends. It also checks config resolution, shortcut creation, and config preservation on rerun.
- **Offline installation in Docker.** Run `.\tests\container.ps1 -Offline -Artifacts PATH_TO_EXTRACTED_BUNDLE`. It disables external networking, tests missing and corrupt payloads, installs all components, repeats the DDS checks, and builds a small C++ package.
- **Windows 11 desktop integration.** Real UAC interaction, launching created shortcuts in Explorer, and rendering ROS graphical tools require a Windows 11 desktop for end-to-end verification.
- **WalkableOR LAN acceptance.** On an isolated Windows 11 test desktop, copy in a test QoS config and start the receiver from its shortcut. Use a separate LAN ROS 2 publisher on the same domain to send a best-effort `sensor_msgs/msg/PointCloud2` stream. Confirm Unity receives successive clouds, the terminal shows live logs, and closing the terminal releases port `10000`.
