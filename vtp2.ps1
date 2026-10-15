param(
  [Parameter(Position=0,Mandatory=$true)][string]$Command,
  [Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$project = Join-Path $root "src\Vtp2\Vtp2.csproj"
$source = Join-Path $root "src\Vtp2\Program.cs"
$dll = Join-Path $root "src\Vtp2\bin\Release\net10.0\vtp2.dll"

if($null -eq (Get-Command dotnet -ErrorAction SilentlyContinue)){ throw "VTP2_DOTNET_SDK_NOT_FOUND" }

function Build-Vtp2 {
  & dotnet build $project -c Release --nologo | Out-Host
  if($LASTEXITCODE -ne 0){ throw "VTP2_BUILD_FAILED" }
}

if($Command -eq "build"){
  Build-Vtp2
  Write-Host "VTP2_BUILD_OK"
  exit 0
}
if($Command -eq "verify"){
  $hostExe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
  & $hostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $root "scripts\_selftest_vtp2_v1.ps1") -RepoRoot $root
  if($LASTEXITCODE -ne 0){ throw "VTP2_VERIFY_FAILED" }
  exit 0
}
# Never run a binary older than its source.
$stale = (-not (Test-Path -LiteralPath $dll -PathType Leaf)) -or
         ((Get-Item -LiteralPath $source).LastWriteTimeUtc -gt (Get-Item -LiteralPath $dll).LastWriteTimeUtc) -or
         ((Get-Item -LiteralPath $project).LastWriteTimeUtc -gt (Get-Item -LiteralPath $dll).LastWriteTimeUtc)
if($stale){ Build-Vtp2 }
& dotnet $dll $Command @Arguments
exit $LASTEXITCODE
