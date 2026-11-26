param([switch] $Offline)

$ErrorActionPreference = 'Stop'
if ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').InstallationType -ne 'Server Core') {
    throw 'Run this script in the disposable Windows Server Core test container.'
}

$location = 'C:\ROS Smoke\humble'
$launcher = Join-Path $location 'ros-humble.cmd'
$receiverRoot = Join-Path $location 'pointcloud_receiver'
$receiverLauncher = Join-Path $receiverRoot 'start-receiver.cmd'
$receiverConfig = Join-Path $receiverRoot 'configs\walkableOR.yaml'
$receiverRev = '91be0b80cc6c114f48304f4d42491ac3507a5a18'
$cli = 'C:\setup\Ros2HumbleCli.exe'
$shared = @('--container', '--destination', $location)
if ($Offline) { $shared += '--offline' }

function Invoke-Installer {
    param([string[]] $Arguments)
    $ErrorActionPreference = 'Continue'
    $output = & $cli @Arguments 2>&1 | ForEach-Object { $_.ToString() }
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    $output | Write-Host
    if ($code -ne 0) {
        $log = $output | Where-Object { $_ -like 'Log: *' } | Select-Object -Last 1
        if ($log) { Get-Content -LiteralPath $log.Substring(5) | Write-Host }
        throw "Installer exited $code."
    }
    return $output
}

function Test-RejectedOfflinePayload {
    param([string] $Name)
    $payload = Join-Path 'C:\setup\payload' $Name
    $backup = "$payload.verified"
    Move-Item -LiteralPath $payload -Destination $backup
    try {
        foreach ($reason in 'missing','corrupt') {
            if ($reason -eq 'corrupt') { Set-Content -LiteralPath $payload -Value 'test corruption' }
            $ErrorActionPreference = 'Continue'
            $message = & $cli --headless --accept-plan @shared 2>&1 | Out-String
            $code = $LASTEXITCODE
            $ErrorActionPreference = 'Stop'
            if ($code -eq 0 -or (Test-Path -LiteralPath $location)) {
                throw "The installer made installation changes with a $reason payload: $message"
            }
        }
    }
    finally { Move-Item -LiteralPath $backup -Destination $payload -Force }
}

function Assert-Shortcut {
    param(
        [Environment+SpecialFolder] $Folder,
        [string] $Name = 'ROS 2 Humble Command Prompt',
        [string] $Target = $launcher
    )
    $link = Join-Path ([Environment]::GetFolderPath($Folder)) "$Name.lnk"
    if (!(Test-Path -LiteralPath $link -PathType Leaf)) { throw "Missing shortcut $link." }
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($link)
    if ($shortcut.TargetPath -ne "$env:SystemRoot\System32\cmd.exe" -or
        $shortcut.Arguments -notlike "*$Target*") { throw "Unexpected shortcut target $link." }
}

function Test-RosMessaging {
    param([string] $Backend)
    $env:ROS_LOCALHOST_ONLY = '1'
    $env:ROS_DOMAIN_ID = '77'
    $env:PYTHONUNBUFFERED = '1'
    $testRoot = Join-Path $env:TEMP "ros-test-$Backend"
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    $talkerLog = Join-Path $testRoot 'talker.log'
    $listenerLog = Join-Path $testRoot 'listener.log'
    $talker = $null
    $listener = $null
    try {
        $talker = Start-Process -FilePath $env:ComSpec -ArgumentList "/d /v:off /s /c `"call `"$launcher`" && ros2 run demo_nodes_cpp talker`"" -PassThru -WindowStyle Hidden -RedirectStandardOutput $talkerLog -RedirectStandardError "$talkerLog.err"
        $listener = Start-Process -FilePath $env:ComSpec -ArgumentList "/d /v:off /s /c `"call `"$launcher`" && ros2 run demo_nodes_py listener`"" -PassThru -WindowStyle Hidden -RedirectStandardOutput $listenerLog -RedirectStandardError "$listenerLog.err"
        $deadline = [DateTime]::UtcNow.AddSeconds(45)
        while ([DateTime]::UtcNow -lt $deadline -and !$talker.HasExited -and !$listener.HasExited) {
            if (Select-String -LiteralPath $listenerLog -Pattern 'I heard.*Hello World' -Quiet) { return }
            Start-Sleep -Milliseconds 500
        }
        Get-Content -LiteralPath $talkerLog, "$talkerLog.err", $listenerLog, "$listenerLog.err" | Write-Host
        throw "ROS talker/listener did not exchange a message using $Backend."
    }
    finally {
        foreach ($child in $talker, $listener) {
            if ($child -and !$child.HasExited) { & taskkill.exe /t /f /pid $child.Id | Out-Null }
        }
    }
}

function Test-ReceiverHandshake {
    param([string] $Rmw)
    $stdout = Join-Path $env:TEMP "receiver-$Rmw.log"
    $stderr = "$stdout.err"
    $process = Start-Process -FilePath $env:ComSpec -ArgumentList "/d /v:off /s /c `"call `"$receiverLauncher`"`"" -WorkingDirectory 'C:\' -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $client = $null
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(45)
        while (!$process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
            $client = [Net.Sockets.TcpClient]::new()
            try {
                $attempt = $client.ConnectAsync('127.0.0.1', 10000)
                if ($attempt.Wait(1000) -and $client.Connected) { break }
            }
            catch { }
            $client.Dispose()
            $client = $null
            Start-Sleep -Milliseconds 300
        }
        if (!$client -or !$client.Connected) { throw 'The receiver did not open TCP port 10000.' }
        if (!(netstat.exe -an -p tcp | Select-String -Quiet '^\s*TCP\s+0\.0\.0\.0:10000\s+0\.0\.0\.0:0\s')) {
            throw 'The receiver should listen on all IPv4 interfaces on port 10000.'
        }

        $client.ReceiveTimeout = 5000
        $reader = [IO.BinaryReader]::new($client.GetStream())
        try {
            $length = $reader.ReadInt32()
            if ($length -lt 1 -or $length -gt 64) { throw 'Invalid Unity handshake topic length.' }
            $topic = [Text.Encoding]::UTF8.GetString($reader.ReadBytes($length)).TrimEnd([char]0)
            if ($topic -ne '__handshake') { throw "Unexpected Unity handshake topic $topic." }
            $length = $reader.ReadInt32()
            if ($length -lt 1 -or $length -gt 4096) { throw 'Invalid Unity handshake payload length.' }
            $handshake = [Text.Encoding]::UTF8.GetString($reader.ReadBytes($length)).TrimEnd([char]0) | ConvertFrom-Json
            if (($handshake.metadata | ConvertFrom-Json).protocol -ne 'ROS2') { throw 'Expected a ROS 2 Unity handshake.' }
        }
        finally { $reader.Dispose() }
        if (!(Select-String -LiteralPath $stdout -SimpleMatch "DDS $Rmw" -Quiet)) {
            throw "The receiver launcher did not inherit $Rmw."
        }
        . (Join-Path $location 'ros-shells.ps1')
        if (@(Get-RosProcesses $location) -notcontains "WalkableOR receiver terminal (PID $($process.Id))") {
            throw 'The running receiver terminal was missing from the uninstall check.'
        }
    }
    catch {
        Get-Content -LiteralPath $stdout, $stderr | Write-Host
        throw
    }
    finally {
        if ($client) { $client.Dispose() }
        if (!$process.HasExited) { & taskkill.exe /t /f /pid $process.Id | Out-Null }
        $process.Dispose()
    }
}

$plan = (Invoke-Installer (@('--print-plan') + $shared)) -join "`n"
if ($plan -notmatch 'Build the WalkableOR receiver' -or $plan -match 'Install Visual Studio 2019') {
    throw 'The default receiver plan should build the overlay without Visual Studio.'
}
$optOut = (Invoke-Installer (@('--print-plan', '--no-walkableor-receiver') + $shared)) -join "`n"
if ($optOut -match 'WalkableOR') { throw 'The opt-out plan should omit the receiver.' }
if (Test-Path -LiteralPath $location) { throw 'Plan preview created the destination.' }
if ($Offline) {
    Test-RejectedOfflinePayload 'pixi-x86_64-pc-windows-msvc.exe'
    Test-RejectedOfflinePayload "walkableor-endpoint-$receiverRev.zip"
}

foreach ($implementation in 'cyclone', 'fast') {
    $arguments = @('--headless', '--accept-plan', '--dds', $implementation) + $shared
    if ($implementation -eq 'fast') { $arguments += '--desktop' }
    $result = Invoke-Installer $arguments
    foreach ($relative in 'local_setup.bat','Scripts\ros2.exe','bin\ddsc.dll','bin\rmw_cyclonedds_cpp.dll','bin\rmw_fastrtps_cpp.dll','ros-humble.cmd') {
        if (!(Test-Path -LiteralPath (Join-Path $location $relative) -PathType Leaf)) { throw "Missing $relative." }
    }
    $expected = if ($implementation -eq 'cyclone') { 'rmw_cyclonedds_cpp' } else { 'rmw_fastrtps_cpp' }
    if (!(Select-String -LiteralPath $launcher -SimpleMatch "RMW_IMPLEMENTATION=$expected" -Quiet)) {
        throw "Launcher did not select $expected."
    }
    if ($implementation -eq 'fast') { Assert-Shortcut 'DesktopDirectory' }
    Assert-Shortcut 'Programs'
    Assert-Shortcut 'DesktopDirectory' 'Start Point Cloud Receiver' $receiverLauncher
    if ((Get-Content -Raw -LiteralPath (Join-Path $receiverRoot '.walkableor-revision')) -ne $receiverRev) {
        throw 'The receiver did not record the expected source revision.'
    }
    if ($implementation -eq 'cyclone') {
        if (Get-ChildItem -LiteralPath $receiverRoot -Recurse -Filter 'walkableOR.yaml') {
            throw 'Setup installed a walkableOR.yaml file.'
        }
        if (!($result | Where-Object { $_ -eq $receiverConfig })) { throw 'Setup omitted the expected configuration path.' }
        $start = [Diagnostics.ProcessStartInfo]::new($env:ComSpec)
        $start.Arguments = "/d /v:off /s /c `"call `"$receiverLauncher`"`""
        $start.WorkingDirectory = 'C:\'
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($start)
        try {
            if (!$process.WaitForExit(5000)) {
                $process.Kill()
                throw 'The launcher hung when the receiver config was missing.'
            }
            $missingConfig = $process.StandardError.ReadToEnd()
            $code = $process.ExitCode
        }
        finally { $process.Dispose() }
        if ($code -ne 2 -or !$missingConfig.Contains($receiverConfig)) {
            throw "Expected a missing-config diagnostic containing $receiverConfig. Got $missingConfig."
        }
        Set-Content -LiteralPath $receiverConfig -Value 'topics: {}' -Encoding Ascii
        $configHash = (Get-FileHash -LiteralPath $receiverConfig).Hash
    }
    elseif ((Get-FileHash -LiteralPath $receiverConfig).Hash -ne $configHash -or
        ($result -join "`n") -notmatch 'Reuse: WalkableOR endpoint build') {
        throw 'Rerunning setup should preserve the user config and reuse the verified overlay.'
    }
    Test-RosMessaging $implementation
    Test-ReceiverHandshake $expected
}

$project = 'C:\Test Projects\walkableOR_unity'
$projectConfig = Join-Path $project 'pointcloud_receiver\configs\walkableOR.yaml'
New-Item -ItemType Directory -Path (Split-Path -Parent $projectConfig) | Out-Null
Set-Content -LiteralPath $projectConfig -Value "# test project config`ntopics: {}" -Encoding Ascii
$sourceHash = (Get-FileHash -LiteralPath $projectConfig).Hash
$ErrorActionPreference = 'Continue'
$conflict = & $cli --print-plan --walkableor-project $project @shared 2>&1 | Out-String
$code = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
if ($code -eq 0 -or $conflict -notlike '*different receiver configuration already exists*' -or
    (Get-FileHash -LiteralPath $receiverConfig).Hash -ne $configHash) {
    throw 'An existing configuration should require explicit replacement.'
}
$result = (Invoke-Installer (@('--headless', '--accept-plan', '--walkableor-project', $project,
            '--replace-walkableor-config') + $shared)) -join "`n"
if ($result -notlike '*WalkableOR configuration is ready*' -or
    (Get-FileHash -LiteralPath $receiverConfig).Hash -ne $sourceHash -or
    (Get-FileHash -LiteralPath $projectConfig).Hash -ne $sourceHash) {
    throw 'The installer should copy the project config and report that it is ready.'
}
Move-Item -LiteralPath $receiverConfig -Destination "$receiverConfig.backup"
$null = Invoke-Installer (@('--headless', '--accept-plan', '--walkableor-project', $project) + $shared)
if ((Get-FileHash -LiteralPath $receiverConfig).Hash -ne $sourceHash) {
    throw 'A project configuration should copy automatically into an empty destination.'
}

if ($Offline) {
    $null = Invoke-Installer (@('--headless', '--accept-plan', '--development', '--visualization', '--graphviz', '--opencv') + $shared)
    $workspace = 'C:\cpp-smoke'
    $source = Join-Path $workspace 'src\humble_smoke'
    New-Item -ItemType Directory -Path $source | Out-Null
    @'
<package format="3">
  <name>humble_smoke</name><version>0.0.1</version><description>Installer smoke test</description>
  <maintainer email="test@example.invalid">Smoke test</maintainer><license>Apache-2.0</license>
  <buildtool_depend>ament_cmake</buildtool_depend><depend>rclcpp</depend>
  <export><build_type>ament_cmake</build_type></export>
</package>
'@ | Set-Content -LiteralPath (Join-Path $source 'package.xml') -Encoding Ascii
    @'
cmake_minimum_required(VERSION 3.16)
project(humble_smoke)
find_package(ament_cmake REQUIRED)
find_package(rclcpp REQUIRED)
add_executable(humble_smoke main.cpp)
ament_target_dependencies(humble_smoke rclcpp)
ament_package()
'@ | Set-Content -LiteralPath (Join-Path $source 'CMakeLists.txt') -Encoding Ascii
    @'
#include "rclcpp/rclcpp.hpp"
int main(int argc, char **argv) {
    rclcpp::init(argc, argv);
    rclcpp::shutdown();
    return 0;
}
'@ | Set-Content -LiteralPath (Join-Path $source 'main.cpp') -Encoding Ascii
    Push-Location -LiteralPath $workspace
    try {
        $command = "call `"$launcher`" && colcon build --merge-install --cmake-args -DCMAKE_BUILD_TYPE=Release"
        & $env:ComSpec /d /v:off /c $command
        if ($LASTEXITCODE -ne 0) { throw 'The C++ test workspace did not build.' }
        $command = "call `"$launcher`" && dot -V && python -c `"import cv2; from PyQt5 import QtWidgets; print(cv2.__version__)`""
        & $env:ComSpec /d /v:off /c $command
        if ($LASTEXITCODE -ne 0) { throw 'Optional runtime checks failed.' }
    }
    finally { Pop-Location }
}

$uninstaller = Join-Path $location 'Uninstall ROS 2 Humble.cmd'
if (!(Test-Path -LiteralPath $uninstaller -PathType Leaf)) { throw 'The clickable uninstaller is missing.' }
. (Join-Path $location 'uninstall-ros-humble.ps1')
if ((Invoke-RosUninstall $location {
        param($root)
        if ($root -ne $location) { throw 'The confirmation should display the installation path.' }
        return $false
    }) -or
    !(Test-Path -LiteralPath $receiverConfig -PathType Leaf)) { throw 'Cancelling should preserve the installation.' }

# A pre-existing cmd.exe has no ROS launcher path on its original command line.
# It must still block uninstall after calling the installed ROS launcher.
$start = [Diagnostics.ProcessStartInfo]::new($env:ComSpec)
$start.Arguments = '/d /q'
$start.WorkingDirectory = 'C:\'
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardInput = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$prompt = [Diagnostics.Process]::Start($start)
try {
    $out = $prompt.StandardOutput.ReadToEndAsync()
    $err = $prompt.StandardError.ReadToEndAsync()
    $prompt.StandardInput.WriteLine("call `"$launcher`"")
    $record = Join-Path $location ".ros2-shells\$($prompt.Id).txt"
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while (!(Test-Path -LiteralPath $record) -and !$prompt.HasExited -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 200
    }
    if (!(Test-Path -LiteralPath $record)) { throw 'A CMD session calling ros-humble.cmd did not register.' }
    $blocked = Invoke-RosUninstall $location { return $true } {
        param($root, $active)
        if ($root -ne $location -or $active -notcontains "ROS command prompt (PID $($prompt.Id))") {
            throw 'The waiting dialog should receive the open ROS command prompt.'
        }
        return $false
    }
    if ($blocked -or !(Test-Path -LiteralPath $receiverConfig -PathType Leaf)) {
        throw 'Cancelling while waiting for a ROS prompt should preserve the installation.'
    }
    $prompt.StandardInput.WriteLine('exit')
    if (!$prompt.WaitForExit(10000)) { throw 'The test ROS command prompt did not close.' }
}
finally {
    if (!$prompt.HasExited) { $prompt.Kill(); $prompt.WaitForExit() }
    $prompt.Dispose()
}
. (Join-Path $location 'ros-shells.ps1')
if (@(Get-RosProcesses $location).Count -ne 0) { throw 'Closed ROS processes should no longer block uninstall.' }

$desktop = [Environment]::GetFolderPath('DesktopDirectory')
$userShortcut = Join-Path $desktop 'ROS 2 Humble Command Prompt.lnk'
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut($userShortcut)
$link.Arguments = '/k echo User-owned shortcut'
$link.Save()
$shortcutHash = (Get-FileHash -LiteralPath $userShortcut).Hash
$outside = 'C:\uninstall-smoke-outside'
New-Item -ItemType Directory -Path $outside | Out-Null
$outsideFile = Join-Path $outside 'keep.txt'
Set-Content -LiteralPath $outsideFile -Value 'preserve this file'
New-Item -ItemType Junction -Path (Join-Path $location 'outside-junction') -Target $outside | Out-Null

$runtime = Join-Path ([Environment]::SystemDirectory) 'vcruntime140_1.dll'
$runtimeHash = (Get-FileHash -LiteralPath $runtime).Hash
if (!(Invoke-RosUninstall $location { return $true }) -or (Test-Path -LiteralPath $location)) {
    throw 'Confirmed uninstall should remove the installation folder.'
}
$startMenu = [Environment]::GetFolderPath('Programs')
if ((Test-Path -LiteralPath (Join-Path $startMenu 'ROS 2 Humble Command Prompt.lnk')) -or
    (Test-Path -LiteralPath (Join-Path $desktop 'Start Point Cloud Receiver.lnk'))) {
    throw 'Confirmed uninstall should remove the installation shortcuts.'
}
if ((Get-FileHash -LiteralPath $userShortcut).Hash -ne $shortcutHash -or
    !(Test-Path -LiteralPath $outsideFile -PathType Leaf) -or
    (Get-FileHash -LiteralPath $runtime).Hash -ne $runtimeHash) {
    throw 'Uninstall should preserve the unrelated shortcut, junction target, and shared Visual C++ runtime.'
}

Write-Host 'Windows container smoke tests passed.'
