$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$repo = Split-Path -Parent $PSScriptRoot
$env:DOTNET_BUNDLE_EXTRACT_BASE_DIR = Join-Path $repo 'build/preview-runtime'
$preview = Join-Path $repo 'dist/preview/Ros2HumblePreview.exe'

function Find-Control {
    param($Window, [string] $Id)
    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $Id)
    $control = $Window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
    if (!$control) { throw "Control $Id not found." }
    return $control
}

function Invoke-Button {
    param([string] $Id)
    $control = Find-Control $window $Id
    $control.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}

function Wait-Status {
    param([string] $Expected)
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $status = Find-Control $window 'Status'
            if ($status.Current.Name -like $Expected) { return }
        } catch [System.Management.Automation.RuntimeException] { }
        Start-Sleep -Milliseconds 100
    }
    throw "Expected status $Expected."
}

function Assert-ButtonLabel {
    param([string] $Id, [string] $Expected)
    $control = Find-Control $window $Id
    if ($control.Current.Name -ne $Expected) { throw "Expected $Id to show $Expected." }
}

function Get-Details {
    $details = (Find-Control $window 'Detail').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    return $details.Current.Value
}

function Get-ProgressBar {
    param([string] $Id)
    $control = Find-Control $window $Id
    return $control.GetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern).Current
}

function Select-Choice {
    param([string] $Id)
    (Find-Control $window $Id).GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
}

function Invoke-Scenario {
    param([scriptblock] $Scenario)
    $process = Start-Process -FilePath $preview -PassThru -WindowStyle Hidden
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        do {
            Start-Sleep -Milliseconds 100
            $process.Refresh()
            if ($process.HasExited) { throw "The preview exited with code $($process.ExitCode)." }
        } while ($process.MainWindowHandle -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $deadline)
        if ($process.MainWindowHandle -eq [IntPtr]::Zero) { throw 'The preview window did not open.' }
        $window = [System.Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
        & $Scenario
        Invoke-Button 'NextButton'
        if (!$process.WaitForExit(5000)) { throw 'The wizard did not close.' }
    }
    finally {
        if (!$process.HasExited) { $process.Kill(); $process.WaitForExit() }
    }
}

Invoke-Scenario {
    $receiver = (Find-Control $window 'WalkableOrReceiver').GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    if ($receiver.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::On) {
        throw 'The WalkableOR receiver should be selected by default.'
    }
    Select-Choice 'DeferReceiverConfig'
    $dds = (Find-Control $window 'Dds').GetCurrentPattern([System.Windows.Automation.SelectionPattern]::Pattern)
    if ($dds.Current.GetSelection()[0].Current.Name -notlike 'Cyclone DDS*rmw_cyclonedds_cpp') {
        throw 'Cyclone DDS should be selected by default.'
    }
    $desktopShortcut = (Find-Control $window 'Desktop').GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    if ($desktopShortcut.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::Off) {
        throw 'The desktop shortcut should be optional.'
    }
    $desktopShortcut.Toggle()
    $toggle = (Find-Control $window 'Transparency').GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    if ($toggle.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::On) {
        throw 'Transparency Mode should start enabled.'
    }
    Invoke-Button 'NextButton'
    Wait-Status 'Review installation'
    $details = Get-Details
    if ($details -notlike '*Create desktop shortcut*') {
        throw 'The desktop shortcut selection was missing from the plan.'
    }
    if ($details -notmatch '(?s)Verify ROS 2 command prompt.*Prepare WalkableOR endpoint source.*Build the WalkableOR receiver.*Verify the WalkableOR receiver.*Create Start Point Cloud Receiver shortcut') {
        throw 'The WalkableOR build and shortcut should follow ROS verification.'
    }
    Invoke-Button 'NextButton'
    Wait-Status 'Step 1 of *'
    Assert-ButtonLabel 'NextButton' 'Confirm'
    Invoke-Button 'NextButton'
    Wait-Status 'Download and verify ROS 2 Humble'
    $deadline = [DateTime]::UtcNow.AddSeconds(4)
    do {
        Start-Sleep -Milliseconds 100
        $transfer = (Find-Control $window 'CurrentStepStatus').Current.Name
    } while ($transfer -notlike '*MiB*remaining*' -and [DateTime]::UtcNow -lt $deadline)
    if ($transfer -notlike '*MiB*remaining*' -or
        (Get-ProgressBar 'CurrentStepProgress').Value -le 0 -or
        (Get-ProgressBar 'OverallProgress').Value -le 0) {
        throw 'Both progress bars should advance during a download and show a remaining-time estimate.'
    }
    Wait-Status 'Step 2 of *'
    if ((Get-ProgressBar 'OverallProgress').Value -ne 1) {
        throw 'Overall progress should show one completed step while waiting for confirmation.'
    }
    Invoke-Button 'AbortButton'
    Wait-Status 'Installation aborted'
}

Invoke-Scenario {
    Select-Choice 'DeferReceiverConfig'
    $toggle = (Find-Control $window 'Transparency').GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    $toggle.Toggle()
    Invoke-Button 'NextButton'
    Wait-Status 'Review installation'
    Invoke-Button 'NextButton'
    Wait-Status 'ROS 2 Humble is ready'
    $overall = Get-ProgressBar 'OverallProgress'
    if ($overall.Value -ne $overall.Maximum) { throw 'Overall progress should reach the end after setup succeeds.' }
    if ((Get-Details) -notmatch 'pointcloud_receiver\\configs\\walkableOR\.yaml') {
        throw 'The receiver completion reminder should include the configuration path.'
    }
    if ((Get-Details) -notlike '*Uninstall ROS 2 Humble.cmd*') {
        throw 'The completion screen should show the uninstaller path.'
    }
}

Invoke-Scenario {
    (Find-Control $window 'WalkableOrReceiver').GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle()
    (Find-Control $window 'Transparency').GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle()
    Invoke-Button 'NextButton'
    Wait-Status 'Review installation'
    if ((Get-Details) -like '*WalkableOR*') { throw 'The plan should omit a deselected receiver.' }
    Invoke-Button 'NextButton'
    Wait-Status 'ROS 2 Humble is ready'
    if ((Get-Details) -like '*walkableOR.yaml*') { throw 'The opt-out flow should omit the configuration reminder.' }
}

Invoke-Scenario {
    Select-Choice 'UseLocalProject'
    Invoke-Button 'NextButton'
    $errorText = (Find-Control $window 'SettingsError').Current.Name
    if ($errorText -notlike '*Choose the walkableOR_unity project folder*') {
        throw 'The local option should ask for a folder.'
    }
    $project = 'C:\Example Projects\walkableOR_unity'
    (Find-Control $window 'WalkableOrProject').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($project)
    (Find-Control $window 'Transparency').GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle()
    Invoke-Button 'NextButton'
    Wait-Status 'Review installation'
    $details = Get-Details
    if (!$details.Contains("$project\pointcloud_receiver\configs\walkableOR.yaml") -or
        $details -notmatch '(?s)Verify the WalkableOR receiver.*Copy the WalkableOR configuration.*Create Start Point Cloud Receiver shortcut') {
        throw 'The copy step should show the located source and follow receiver verification.'
    }
    Invoke-Button 'NextButton'
    Wait-Status 'ROS 2 Humble is ready'
    $details = Get-Details
    if ($details -notlike '*WalkableOR configuration is ready*' -or $details -like '*Copy your walkableOR.yaml*') {
        throw 'The completion screen should confirm the config is ready.'
    }
}

Invoke-Scenario {
    Select-Choice 'DeferReceiverConfig'
    (Find-Control $window 'Destination').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue('fail')
    (Find-Control $window 'Transparency').GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle()
    Invoke-Button 'NextButton'
    Wait-Status 'Review installation'
    Invoke-Button 'NextButton'
    Wait-Status 'Installation stopped'
}

Write-Output 'Preview defaults, progress, local config, deferred config, opt-out, shortcuts, confirmation, abort, and failure tests passed.'
