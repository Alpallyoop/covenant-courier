# No param block on purpose: VTP v2 options are "--name value" pairs, and a declared PowerShell
# parameter set (with its common parameters such as -OutVariable) would capture "--out".
if($args.Count -lt 1){ throw "VTP2_USAGE: vtp2.ps1 <command> [--name value ...]" }
$Command = [string]$args[0]
$Arguments = @($args | Select-Object -Skip 1 | ForEach-Object { [string]$_ })

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
