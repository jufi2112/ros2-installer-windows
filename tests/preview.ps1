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
    $details = (Find-Control $window 'Detail').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    if ($details.Current.Value -notlike '*Create desktop shortcut*') {
        throw 'The desktop shortcut selection was missing from the plan.'
    }
    Invoke-Button 'NextButton'
    Wait-Status 'Step 1 of *'
    Assert-ButtonLabel 'NextButton' 'Confirm'
    Invoke-Button 'NextButton'
    Wait-Status 'Step 2 of *'
    Invoke-Button 'AbortButton'
    Wait-Status 'Installation aborted'
}

Invoke-Scenario {
    $toggle = (Find-Control $window 'Transparency').GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    $toggle.Toggle()
    Invoke-Button 'NextButton'
    Wait-Status 'Review installation'
    Invoke-Button 'NextButton'
    Wait-Status 'ROS 2 Humble is ready'
}

Invoke-Scenario {
    (Find-Control $window 'Destination').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue('fail')
    (Find-Control $window 'Transparency').GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle()
    Invoke-Button 'NextButton'
    Wait-Status 'Review installation'
    Invoke-Button 'NextButton'
    Wait-Status 'Installation stopped'
}

Write-Output 'Preview defaults, shortcut selection, confirmation, abort, automatic progression, and failure tests passed.'
