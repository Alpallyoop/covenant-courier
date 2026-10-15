param(
  [Parameter(Mandatory=$true)][string]$CovenantGateRoot,
  [Parameter(Mandatory=$true)][string]$EvalInputPath,
  [Parameter(Mandatory=$true)][string]$OutPath
)

# Runs Covenant Gate's sealed evaluator (CG-EvalV1) in this separate process, exactly as
# Covenant Gate's own cg.ps1 does: canonical base policy plus the v1 overlay when present.
# Courier never edits Covenant Gate's files; it only reads them. Output: Covenant Gate's
# canonical eval_output bytes + LF.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$CovenantGateRoot = (Resolve-Path -LiteralPath $CovenantGateRoot).Path
. (Join-Path $CovenantGateRoot "scripts\_lib_covenantgate_eval_v1.ps1")

function Read-Utf8Json([string]$Path){ return ([System.IO.File]::ReadAllText($Path,(New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json -ErrorAction Stop) }

$base = Read-Utf8Json (Join-Path $CovenantGateRoot "policy\canonical.base.v1.json")
$overlay = $null
$overlayPath = Join-Path $CovenantGateRoot "policy\policy.overlay.v1.json"
if(Test-Path -LiteralPath $overlayPath -PathType Leaf){
  $ov = Read-Utf8Json $overlayPath
  if([string]$ov.schema -eq "covenantgate.policy.overlay.v1"){ $overlay = $ov }
}
$evalInput = Read-Utf8Json $EvalInputPath
$out = CG-EvalV1 $base $overlay $evalInput
$j = CG-ToCanonJson $out
$j = ($j -replace "`r`n","`n") -replace "`r","`n"
if(-not $j.EndsWith("`n")){ $j += "`n" }
$dir = Split-Path -Parent $OutPath
if($dir -and -not (Test-Path -LiteralPath $dir)){ [void][System.IO.Directory]::CreateDirectory($dir) }
[System.IO.File]::WriteAllBytes($OutPath,(New-Object System.Text.UTF8Encoding($false)).GetBytes($j))
Write-Host "COURIER_COVENANT_GATE_INVOKE_OK"
