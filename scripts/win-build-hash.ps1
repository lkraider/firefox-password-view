# Builds the Windows app and records the exe's SHA-256. ci.yml's two Windows
# jobs run this.
#
# Usage:
#   scripts/win-build-hash.ps1 -Zig <zig> -Target x86_64-windows-gnu [-Twice]
#
# -Twice starts a second build beside the first. Each build gets its own cache
# directory and its own install prefix, so the two run in parallel and neither
# reads the other's artifacts. The script waits for both and compares the sums.
# A difference means the compiler writes bytes that depend on something outside
# the source. Measured on macOS: two parallel builds and one earlier sequential
# build of x86_64-windows-gnu all produced the same sum, so a separate
# --cache-dir and -p change nothing in the exe.
#
# The winning exe lands in -Prefix, where scripts/win-launch-check.ps1 reads it.
#
# The target is explicit, because a native build on a Windows host resolves to
# the msvc ABI and scripts/package-release.sh ships the gnu one. build.zig pins
# the cpu to a baseline, so the target string decides the code generation and
# the sum is comparable across build hosts.
#
# Each run appends its sum to the job summary. build-and-test appends the sums
# of the exes it cross-compiles on macos-15, which are the bytes a release
# carries. One run page therefore holds every host's answer for one source
# tree. Nothing compares them across hosts yet, and docs/DESIGN.md's known
# limitations record why.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Zig,
    [Parameter(Mandatory = $true)][string]$Target,
    [switch]$Twice,
    [string]$Prefix = "zig-out"
)

$ErrorActionPreference = "Stop"

function Start-Build($Build) {
    Remove-Item -Recurse -Force $Build.cache, $Build.out -ErrorAction SilentlyContinue
    $arguments = @(
        "build", "win",
        "-Dtarget=$Target", "-Doptimize=ReleaseSafe", "-Doracle=false",
        "--cache-dir", $Build.cache, "-p", $Build.out
    )
    return Start-Process -FilePath $Zig -ArgumentList $arguments -NoNewWindow -PassThru `
        -RedirectStandardOutput $Build.log -RedirectStandardError "$($Build.log).err"
}

function Get-Sum($Build) {
    return (Get-FileHash -Algorithm SHA256 (Join-Path $Build.out "bin" "FirefoxPasswordView.exe")).Hash.ToLower()
}

$builds = @([ordered]@{ name = "build 1"; cache = ".zig-cache-1"; out = "out-1"; log = "build-1.log" })
if ($Twice) {
    $builds += [ordered]@{ name = "build 2"; cache = ".zig-cache-2"; out = "out-2"; log = "build-2.log" }
}

foreach ($b in $builds) { $b.proc = Start-Build $b }
Write-Host "started $($builds.Count) build(s) of $Target"
Wait-Process -Id ($builds | ForEach-Object { $_.proc.Id })

$failed = $false
foreach ($b in $builds) {
    foreach ($log in @($b.log, "$($b.log).err")) {
        if ((Test-Path $log) -and (Get-Item $log).Length -gt 0) { Get-Content $log }
    }
    if ($b.proc.ExitCode -ne 0) {
        Write-Host "FAIL  $($b.name) exited $($b.proc.ExitCode)"
        $failed = $true
    }
}
if ($failed) { exit 1 }

foreach ($b in $builds) {
    $b.sum = Get-Sum $b
    Write-Host "$($b.name): $($b.sum)"
}

$sum = $builds[0].sum
if ($Twice) {
    if ($builds[0].sum -ne $builds[1].sum) {
        Write-Host "FAIL  two builds on this host produced different bytes"
        exit 1
    }
    Write-Host "PASS  two builds on this host produced the same bytes"
}

New-Item -ItemType Directory -Force -Path (Join-Path $Prefix "bin") | Out-Null
Copy-Item -Force (Join-Path $builds[0].out "bin" "FirefoxPasswordView.exe") (Join-Path $Prefix "bin")

$label = "$env:RUNNER_OS $env:RUNNER_ARCH"
Write-Host "sha256 $sum  $Target  built on $label"
if ($env:GITHUB_STEP_SUMMARY) {
    "- ``$Target`` built on ``$label``: ``$sum``" |
        Out-File -Append -Encoding utf8 $env:GITHUB_STEP_SUMMARY
}
