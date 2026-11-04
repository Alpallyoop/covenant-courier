param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$CovenantGateRoot
)

# Pins the Covenant Gate checkout that invoke mode may run: its root and the SHA-256 of the evaluator
# (scripts/_lib_covenantgate_eval_v1.ps1), the canonical base policy and the overlay (when present).
# Invoke mode runs nothing from a Covenant Gate root that is not pinned (an environment variable or a
# -CovenantGateRoot argument alone is not trust), and refuses a pinned root whose files changed.
# Re-run after updating Covenant Gate, once its change is reviewed.
#
# Writes proofs/trust/covenant_gate_pin.json (local, never committed).
# Tokens: COURIER_COVENANT_GATE_PIN_OK / COURIER_COVENANT_GATE_PIN_FAIL:<reason>.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_lib_covenant_courier_product_v1.ps1")

$RepoRoot = (Resolve-Path $RepoRoot).Path
if(-not (Test-Path -LiteralPath $CovenantGateRoot -PathType Container)){ throw "COURIER_COVENANT_GATE_PIN_FAIL:ROOT_MISSING" }
$root = (Resolve-Path -LiteralPath $CovenantGateRoot).Path
$lib = Join-Path $root "scripts\_lib_covenantgate_eval_v1.ps1"
$base = Join-Path $root "policy\canonical.base.v1.json"
$overlay = Join-Path $root "policy\policy.overlay.v1.json"
foreach($f in @($lib,$base)){ if(-not (Test-Path -LiteralPath $f -PathType Leaf)){ throw ("COURIER_COVENANT_GATE_PIN_FAIL:MISSING:" + (Split-Path -Leaf $f)) } }
foreach($f in @($root,$lib,$base,$overlay)){
  if((Test-Path -LiteralPath $f) -and ((Get-Item -LiteralPath $f -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){ throw "COURIER_COVENANT_GATE_PIN_FAIL:LINK_NOT_ALLOWED" }
}
$pin = [ordered]@{
  schema = "covenant_courier.covenant_gate_pin.v1"
  root = $root
  evaluator_sha256 = (CC-Sha256File $lib)
  base_policy_sha256 = (CC-Sha256File $base)
  overlay_sha256 = $(if(Test-Path -LiteralPath $overlay -PathType Leaf){ CC-Sha256File $overlay } else { $null })
  pinned_utc = (CC-UtcNow)
}
$path = Join-Path $RepoRoot "proofs\trust\covenant_gate_pin.json"
CC-EnsureDir (Split-Path -Parent $path)
[void](CC-WriteDocument $path $pin)
Write-Host ("COURIER_COVENANT_GATE_PIN_ROOT: " + $root)
Write-Host ("COURIER_COVENANT_GATE_PIN_EVALUATOR_SHA256: " + $pin.evaluator_sha256)
Write-Host ("COURIER_COVENANT_GATE_PIN_BASE_POLICY_SHA256: " + $pin.base_policy_sha256)
Write-Host ("COURIER_COVENANT_GATE_PIN_PATH: " + $path)
Write-Host "COURIER_COVENANT_GATE_PIN_OK"
exit 0
