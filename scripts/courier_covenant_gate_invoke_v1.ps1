param(
  [Parameter(Mandatory=$true)][string]$CovenantGateRoot,
  [Parameter(Mandatory=$true)][string]$EvalInputPath,
  [Parameter(Mandatory=$true)][string]$OutPath,
  # The pinned hashes (proofs/trust/covenant_gate_pin.json): each file is read once, checked, and the
  # checked bytes are what runs (exit 3 when any differs).
  [Parameter(Mandatory=$true)][string]$EvaluatorSha256,
  [Parameter(Mandatory=$true)][string]$BasePolicySha256,
  [Parameter(Mandatory=$true)][string]$OverlaySha256
)

# Runs Covenant Gate's sealed evaluator (CG-EvalV1) in this separate process, exactly as
# Covenant Gate's own cg.ps1 does: canonical base policy plus the v1 overlay when present.
# Courier never edits Covenant Gate's files; it only reads them. Output: Covenant Gate's
# canonical eval_output bytes + LF.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$CovenantGateRoot = (Resolve-Path -LiteralPath $CovenantGateRoot).Path
$Utf8 = New-Object System.Text.UTF8Encoding($false)
function Sha([byte[]]$B){ $h = [Security.Cryptography.SHA256]::Create(); try { return (($h.ComputeHash($B) | ForEach-Object { $_.ToString("x2") }) -join "") } finally { $h.Dispose() } }
function Pinned([string]$Path,[string]$Expected){
  $b = [System.IO.File]::ReadAllBytes($Path)
  if((Sha $b) -cne $Expected){ Write-Host ("COURIER_COVENANT_GATE_INVOKE_PIN_MISMATCH: " + (Split-Path -Leaf $Path)); exit 3 }
  return $b
}
function Read-Utf8Json([string]$Path){ return ([System.IO.File]::ReadAllText($Path,$Utf8) | ConvertFrom-Json -ErrorAction Stop) }
$libBytes = Pinned (Join-Path $CovenantGateRoot "scripts\_lib_covenantgate_eval_v1.ps1") $EvaluatorSha256
$baseBytes = Pinned (Join-Path $CovenantGateRoot "policy\canonical.base.v1.json") $BasePolicySha256
$overlayPath = Join-Path $CovenantGateRoot "policy\policy.overlay.v1.json"
$overlay = $null
if(Test-Path -LiteralPath $overlayPath -PathType Leaf){
  $ovBytes = Pinned $overlayPath $OverlaySha256
  $ov = ($Utf8.GetString($ovBytes) | ConvertFrom-Json -ErrorAction Stop)
  if([string]$ov.schema -eq "covenantgate.policy.overlay.v1"){ $overlay = $ov }
} elseif($OverlaySha256 -cne "none"){ Write-Host "COURIER_COVENANT_GATE_INVOKE_PIN_MISMATCH: policy.overlay.v1.json"; exit 3 }
$libText = $Utf8.GetString($libBytes)
if($libText.Length -gt 0 -and $libText[0] -eq [char]0xFEFF){ $libText = $libText.Substring(1) }
. ([scriptblock]::Create($libText))
$base = ($Utf8.GetString($baseBytes).TrimStart([char]0xFEFF) | ConvertFrom-Json -ErrorAction Stop)
$evalInput = Read-Utf8Json $EvalInputPath
$out = CG-EvalV1 $base $overlay $evalInput
$j = CG-ToCanonJson $out
$j = ($j -replace "`r`n","`n") -replace "`r","`n"
if(-not $j.EndsWith("`n")){ $j += "`n" }
$dir = Split-Path -Parent $OutPath
if($dir -and -not (Test-Path -LiteralPath $dir)){ [void][System.IO.Directory]::CreateDirectory($dir) }
[System.IO.File]::WriteAllBytes($OutPath,(New-Object System.Text.UTF8Encoding($false)).GetBytes($j))
Write-Host "COURIER_COVENANT_GATE_INVOKE_OK"
