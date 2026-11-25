param([switch] $Offline)

$ErrorActionPreference = 'Stop'
if ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').InstallationType -ne 'Server Core') {
    throw 'Run this script in the disposable Windows Server Core test container.'
}

$location = 'C:\ROS Smoke\humble'
$launcher = Join-Path $location 'ros-humble.cmd'
$cli = 'C:\setup\Ros2HumbleCli.exe'
$shared = @('--container', '--destination', $location, '--desktop')
if ($Offline) { $shared += @('--offline', '--development', '--visualization', '--graphviz', '--opencv') }

function Invoke-Installer {
    param([string[]] $Arguments)
    $output = & $cli @Arguments 2>&1 | ForEach-Object { $_.ToString() }
    $code = $LASTEXITCODE
    $output | Write-Host
    if ($code -ne 0) {
        $log = $output | Where-Object { $_ -like 'Log: *' } | Select-Object -Last 1
        if ($log) { Get-Content -LiteralPath $log.Substring(5) | Write-Host }
        throw "Installer exited $code."
    }
}

function Test-RejectedOfflinePayload {
    $payload = 'C:\setup\payload\pixi-x86_64-pc-windows-msvc.exe'
    $backup = "$payload.verified"
    Move-Item -LiteralPath $payload -Destination $backup
    try {
        foreach ($reason in 'missing','corrupt') {
            if ($reason -eq 'corrupt') { Set-Content -LiteralPath $payload -Value 'test corruption' }
            $ErrorActionPreference = 'Continue'
            $message = (& $cli --headless --accept-plan @shared 2>&1).ToString()
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
    param([Environment+SpecialFolder] $Folder)
    $link = Join-Path ([Environment]::GetFolderPath($Folder)) 'ROS 2 Humble Command Prompt.lnk'
    if (!(Test-Path -LiteralPath $link -PathType Leaf)) { throw "Missing shortcut $link." }
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($link)
    if ($shortcut.TargetPath -ne "$env:SystemRoot\System32\cmd.exe" -or
        $shortcut.Arguments -notlike "*$launcher*") { throw "Unexpected shortcut target $link." }
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

Invoke-Installer (@('--print-plan') + $shared)
if (Test-Path -LiteralPath $location) { throw 'Plan preview created the destination.' }
if ($Offline) { Test-RejectedOfflinePayload }

foreach ($implementation in 'cyclone', 'fast') {
    Invoke-Installer (@('--headless', '--accept-plan', '--dds', $implementation) + $shared)
    foreach ($relative in 'local_setup.bat','Scripts\ros2.exe','bin\ddsc.dll','bin\rmw_cyclonedds_cpp.dll','bin\rmw_fastrtps_cpp.dll','ros-humble.cmd') {
        if (!(Test-Path -LiteralPath (Join-Path $location $relative) -PathType Leaf)) { throw "Missing $relative." }
    }
    $expected = if ($implementation -eq 'cyclone') { 'rmw_cyclonedds_cpp' } else { 'rmw_fastrtps_cpp' }
    if (!(Select-String -LiteralPath $launcher -SimpleMatch "RMW_IMPLEMENTATION=$expected" -Quiet)) {
        throw "Launcher did not select $expected."
    }
    Assert-Shortcut 'DesktopDirectory'
    Assert-Shortcut 'Programs'
    Test-RosMessaging $implementation
}

if ($Offline) {
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

Write-Host 'Windows container smoke tests passed.'
