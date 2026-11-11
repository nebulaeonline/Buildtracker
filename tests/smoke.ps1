param([Parameter(Mandatory)][string]$Executable)
$ErrorActionPreference = 'Stop'
$Executable = (Resolve-Path -LiteralPath $Executable).Path
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('bt-tests-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $testRoot | Out-Null
function Check([string]$Expected, [string[]]$Arguments) {
    $actual = & $Executable --root $testRoot @Arguments
    if ($LASTEXITCODE -ne 0 -or "$actual" -cne $Expected) {
        throw "Expected '$Expected', got '$actual' (exit $LASTEXITCODE): $Arguments"
    }
}
function Reject([string[]]$Arguments) {
    $actual = & $Executable --root $testRoot @Arguments 2>$null
    if ($LASTEXITCODE -ne 1 -or $null -ne $actual) { throw "Expected failure with empty stdout: $Arguments" }
}
try {
    Reject @('--noinc')
    Reject @('--reset')
    Reject @('--print-tags')
    Check '1.0.4' @('--version')
    $helpText = (& $Executable --root $testRoot --help) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw 'Help failed' }
    foreach ($option in @('--init', '--reset', '--noinc', '--nolocktimeout', '--print-tags', '--version', '--tag', '--root', '--help', '1.0.4')) {
        if (!$helpText.Contains($option)) { throw "Help missing $option" }
    }
    if (Test-Path (Join-Path $testRoot '.buildtracker')) { throw 'Read created storage' }
    Check '0' @('--init')
    Check '' @('--print-tags')
    Reject @('--print-tags', '--tag', 'api')
    Reject @('--print-tags', '--init')
    Reject @('--print-tags', '--reset')
    Reject @('--print-tags', '--noinc')
    Check '1' @()
    Check '1' @('--noinc')
    Check '1' @('--noinc', '--nolocktimeout')
    Reject @('--nolocktimeout', '--nolocktimeout')
    Reject @('--nolockout')
    Check '50' @('--reset', '50')
    Check '50' @('--noinc')
    Check '51' @()
    Check '0' @('--reset')
    Check '1' @()
    Check '100' @('--tag', 'api', '--init', '100')
    Check '101' @('--tag', 'api')
    Check '200' @('--tag', 'api', '--reset', '200')
    Check '200' @('--tag', 'api', '--noinc')
    Check '201' @('--tag', 'api')
    Check '0' @('--reset', '--tag', 'api')
    Check '1' @('--tag', 'api')
    Reject @('--tag', 'missing', '--reset', '10')
    Reject @('--reset', '-1')
    Reject @('--reset', '9223372036854775808')
    Reject @('--reset', '--noinc')
    Reject @('--reset', '--init')
    Reject @('--reset', '--reset')
    Check '1' @('--noinc')
    Reject @('--tag', 'API', '--noinc')
    Check '0' @('--tag', "spaces and 'quotes'", '--init')
    Check '1' @('--tag', "spaces and 'quotes'")
    Reject @('--init', '-1')
    Reject @('--init', '1', '--noinc')
    Reject @('--tag')
    Reject @('--unknown')
    Check '9223372036854775807' @('--tag', 'max', '--init', '9223372036854775807')
    Reject @('--tag', 'max')
    Check '9223372036854775807' @('--tag', 'max', '--noinc')
    Check '0' @('--init')
    $processes = 1..24 | ForEach-Object {
        $start = [Diagnostics.ProcessStartInfo]::new($Executable)
        $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.ArgumentList.Add('--root')
        $start.ArgumentList.Add($testRoot)
        [Diagnostics.Process]::Start($start)
    }
    $failed = $false
    $numbers = foreach ($process in $processes) {
        $output = $process.StandardOutput.ReadToEnd()
        $errorOutput = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            $failed = $true
            [Console]::Error.WriteLine("Concurrent increment failed: $errorOutput")
        } else { [long]::Parse($output.Trim()) }
        $process.Dispose()
    }
    if ($failed) { throw 'Concurrent increment failed' }
    if ((($numbers | Sort-Object) -join ',') -ne ((1..24) -join ',')) { throw 'Concurrent increments were not unique and consecutive' }
    Check '24' @('--noinc')
    Check '5' @('--tag', 'Zulu', '--init', '5')
    Check '7' @('--tag', 'Alpha', '--init', '7')
    Check '9' @('--tag', 'alpha', '--init', '9')
    $expectedTags = @("Alpha`t7", "alpha`t9", "api`t1", "max`t9223372036854775807", "spaces and 'quotes'`t1", "Zulu`t5")
    foreach ($arguments in @(@('--print-tags'), @('--print-tags', '--nolocktimeout'))) {
        $actualTags = & $Executable --root $testRoot @arguments
        if ($LASTEXITCODE -ne 0 -or ($actualTags -join "`n") -cne ($expectedTags -join "`n")) { throw 'Tag listing failed' }
    }
    Check '24' @('--noinc')
    $child = New-Item -ItemType Directory -Path (Join-Path $testRoot 'component')
    Push-Location $child.FullName
    try {
        $value = & $Executable --root .. --noinc
        if ($LASTEXITCODE -ne 0 -or "$value" -ne '24') { throw 'Relative root failed' }
        $value = & $Executable --init 5
        if ($LASTEXITCODE -ne 0 -or "$value" -ne '5') { throw 'Default root failed' }
    } finally { Pop-Location }
    Check '24' @('--noinc')
    Write-Host 'All integration checks passed.'
} finally {
    # Only remove the exact temporary directory created by this invocation.
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved).StartsWith('bt-tests-')) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
