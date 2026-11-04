param(
  [string]$RepoRoot = ".",
  [Parameter(Mandatory=$true)][string]$Version,          # e.g. v0.2.0-product-core
  [string]$OutDir = "",                                  # default: runtime/release/<version>
  [string[]]$Supersedes = @(),
  [switch]$SkipSmoke
)

# Builds a Covenant Courier release bundle from the files git tracks (nothing under runtime/, proofs/,
# registry/ or build output), writes covenant_courier.release_manifest.v1 and sha256sums.txt, then
# extracts the ZIP into a clean folder and runs the release proofs there:
#   courier.ps1 verify     -> COVENANT_COURIER_VERIFY_OK
#   vtp2.ps1 verify        -> VTP2_SELFTEST_OK (when the .NET 10 SDK is present; otherwise reported as not run)
# Prints COVENANT_COURIER_RELEASE_ZIP_SMOKE_OK and COVENANT_COURIER_RELEASE_BUILD_OK.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_lib_covenant_courier_product_v1.ps1")
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$RepoRoot = (Resolve-Path $RepoRoot).Path
if($Version -cnotmatch '^v[0-9]+\.[0-9]+\.[0-9]+(-[a-z0-9.-]+)?\z'){ throw "COURIER_RELEASE_FAIL:BAD_VERSION" }
$name = "covenant-courier-" + $Version
if([string]::IsNullOrWhiteSpace($OutDir)){ $OutDir = Join-Path $RepoRoot ("runtime\release\" + $Version) }
if(Test-Path -LiteralPath $OutDir){ Remove-Item -LiteralPath $OutDir -Recurse -Force }
CC-EnsureDir $OutDir

# Files: what git tracks at HEAD, minus runtime state. A dirty tree is refused (the bundle must be a commit).
$eapPrev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
$status = & git -C $RepoRoot status --porcelain --untracked-files=no 2>&1; $stCode = $LASTEXITCODE
$head = (& git -C $RepoRoot rev-parse HEAD 2>&1 | Out-String).Trim()
$files = @(& git -C $RepoRoot -c core.quotepath=false ls-files 2>&1)
$ErrorActionPreference = $eapPrev
if($stCode -ne 0 -or $head -cnotmatch '^[0-9a-f]{40}\z'){ throw "COURIER_RELEASE_FAIL:NOT_A_GIT_CHECKOUT" }
if(@($status | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0){ throw "COURIER_RELEASE_FAIL:WORKING_TREE_DIRTY" }
$excluded = @("runtime/","proofs/","registry/","src/Vtp2/bin/","src/Vtp2/obj/",".github/")
$files = @($files | ForEach-Object { [string]$_ } | Where-Object { $f = $_; -not [string]::IsNullOrWhiteSpace($f) -and -not (@($excluded | Where-Object { $f.StartsWith($_,[StringComparison]::Ordinal) }).Count) })
$files = [string[]]$files; [Array]::Sort($files,[StringComparer]::Ordinal)
if($files.Count -lt 50){ throw "COURIER_RELEASE_FAIL:TOO_FEW_FILES" }

# ZIP with fixed entry timestamps and ordinal order, entries as stored in git (no CRLF conversion).
$zipPath = Join-Path $OutDir ($name + ".zip")
$fixed = [DateTimeOffset]::new(2026,1,1,0,0,0,[TimeSpan]::Zero)
$fs = [IO.File]::Open($zipPath,[IO.FileMode]::CreateNew)
try {
  $zip = New-Object System.IO.Compression.ZipArchive($fs,[System.IO.Compression.ZipArchiveMode]::Create)
  try {
    foreach($f in $files){
      $src = Join-Path $RepoRoot ($f -replace '/','\')
      if(-not (Test-Path -LiteralPath $src -PathType Leaf)){ continue }   # deleted in the tree but staged: skip
      $e = $zip.CreateEntry(($name + "/" + $f),[System.IO.Compression.CompressionLevel]::Optimal)
      $e.LastWriteTime = $fixed
      $w = $e.Open(); try { $b = [IO.File]::ReadAllBytes($src); $w.Write($b,0,$b.Length) } finally { $w.Dispose() }
    }
  } finally { $zip.Dispose() }
} finally { $fs.Dispose() }
$zipSha = CC-Sha256File $zipPath

$manifest = [ordered]@{
  schema = "covenant_courier.release_manifest.v1"
  version = $Version
  release_tag = $name
  git_head = $head
  created_utc = (CC-UtcNow)
  proof_command = ".\courier.ps1 verify-all"
  expected_token = "COVENANT_COURIER_VERIFY_ALL_OK"
  zip = [ordered]@{ name = ($name + ".zip"); sha256 = $zipSha; files = $files.Count }
  requires = @("Windows PowerShell 5.1 or PowerShell 7","OpenSSH ssh-keygen","the .NET 10 SDK for VTP v2 payload encryption")
  excluded_runtime_paths = $excluded
  supersedes = @($Supersedes)
}
$manifestPath = Join-Path $OutDir "release_manifest.json"
[void](CC-WriteDocument $manifestPath $manifest)
CC-WriteTextFile (Join-Path $OutDir "sha256sums.txt") (($zipSha + "  " + $name + ".zip") + "`n" + ((CC-Sha256File $manifestPath) + "  release_manifest.json") + "`n")
Write-Host ("COURIER_RELEASE_ZIP: " + $zipPath)
Write-Host ("COURIER_RELEASE_ZIP_SHA256: " + $zipSha)
Write-Host ("COURIER_RELEASE_FILES: " + $files.Count)

if(-not $SkipSmoke){
  $clean = Join-Path $OutDir "clean"
  [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath,$clean)
  $croot = Join-Path $clean $name
  $ps = CC-HostExe
  function Smoke([string]$Script,[string[]]$A,[string]$Token,[string]$Label){
    # Run from inside the extracted folder, as a user would, so nothing resolves against this checkout.
    $eapPrev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    Push-Location -LiteralPath $croot
    try { $o = & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Script @A 2>&1; $c = $LASTEXITCODE } finally { Pop-Location }
    $ErrorActionPreference = $eapPrev
    $t = ($o | Out-String)
    [IO.File]::WriteAllText((Join-Path $OutDir ("smoke-" + $Label + ".log")),$t,(CC-Utf8NoBom))
    if($c -ne 0 -or -not $t.Contains($Token)){ Write-Host $t.Trim(); throw ("COURIER_RELEASE_FAIL:SMOKE:" + $Label) }
    Write-Host ("COURIER_RELEASE_SMOKE_OK: " + $Label + " -> " + $Token)
  }
  Smoke (Join-Path $croot "courier.ps1") @("verify","-RepoRoot",$croot) "COVENANT_COURIER_VERIFY_OK" "courier-verify"
  if($null -ne (Get-Command dotnet -ErrorAction SilentlyContinue)){
    Smoke (Join-Path $croot "vtp2.ps1") @("verify") "VTP2_SELFTEST_OK" "vtp2-verify"
  } else { Write-Host "COURIER_RELEASE_SMOKE_NOT_RUN: vtp2-verify (no .NET 10 SDK)" }
  Write-Host "COVENANT_COURIER_RELEASE_ZIP_SMOKE_OK"
}
Write-Host "COVENANT_COURIER_RELEASE_BUILD_OK"
