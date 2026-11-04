param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [string]$CovenantGateRoot = "",
  # The Covenant Gate policy_hash to accept, for a node without a Covenant Gate checkout (a receiver).
  # With -CovenantGateRoot it is read from the pinned evaluator instead (and must match if given).
  [string]$PolicyHash = ""
)

# Pins what this installation trusts of Covenant Gate (proofs/trust/covenant_gate_pin.json, local,
# never committed):
#   root, evaluator_sha256, base_policy_sha256, overlay_sha256   the checkout invoke mode may run
#   signer_sha256                                                Covenant Gate's decision signer scripts
#                                                                (cg_sign_decision_v1.ps1 + library), when present
#   policy_hash                                                  the only Covenant Gate policy whose
#                                                                decisions are accepted (sender and receiver)
# Invoke mode runs nothing from an unpinned root and refuses changed files; a decision made under any
# other policy_hash is refused, so an old allow stops counting once Covenant Gate's policy changes.
# Re-run after reviewing a Covenant Gate update.
#
# Tokens: COURIER_COVENANT_GATE_PIN_OK / COURIER_COVENANT_GATE_PIN_FAIL:<reason>.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_lib_covenant_courier_product_v1.ps1")
. (Join-Path $PSScriptRoot "_lib_courier_covenant_gate_v1.ps1")
function Fail([string]$R){ throw ("COURIER_COVENANT_GATE_PIN_FAIL:" + $R) }

$RepoRoot = (Resolve-Path $RepoRoot).Path
if(-not [string]::IsNullOrWhiteSpace($PolicyHash) -and $PolicyHash -cnotmatch '^[0-9a-f]{64}\z'){ Fail "BAD_POLICY_HASH" }
if([string]::IsNullOrWhiteSpace($CovenantGateRoot) -and [string]::IsNullOrWhiteSpace($PolicyHash)){ Fail "USAGE:CovenantGateRoot_or_PolicyHash_required" }

$pin = [ordered]@{ schema = "covenant_courier.covenant_gate_pin.v1"; root = $null; evaluator_sha256 = $null; base_policy_sha256 = $null; overlay_sha256 = $null; signer_sha256 = $null; policy_hash = $null; pinned_utc = (CC-UtcNow) }

if(-not [string]::IsNullOrWhiteSpace($CovenantGateRoot)){
  if(-not (Test-Path -LiteralPath $CovenantGateRoot -PathType Container)){ Fail "ROOT_MISSING" }
  $root = (Resolve-Path -LiteralPath $CovenantGateRoot).Path
  $lib = Join-Path $root "scripts\_lib_covenantgate_eval_v1.ps1"
  $base = Join-Path $root "policy\canonical.base.v1.json"
  $overlay = Join-Path $root "policy\policy.overlay.v1.json"
  foreach($f in @($lib,$base)){ if(-not (Test-Path -LiteralPath $f -PathType Leaf)){ Fail ("MISSING:" + (Split-Path -Leaf $f)) } }
  $signerFiles = @("cg_sign_decision_v1.ps1","_lib_cg_decision_sig_v1.ps1")
  foreach($f in @($root,$lib,$base,$overlay) + @($signerFiles | ForEach-Object { Join-Path $root ("scripts\" + $_) })){
    if((Test-Path -LiteralPath $f) -and ((Get-Item -LiteralPath $f -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){ Fail "LINK_NOT_ALLOWED" }
  }
  $pin.root = $root
  $pin.evaluator_sha256 = CC-Sha256File $lib
  $pin.base_policy_sha256 = CC-Sha256File $base
  $pin.overlay_sha256 = $(if(Test-Path -LiteralPath $overlay -PathType Leaf){ CC-Sha256File $overlay } else { $null })
  if(Test-Path -LiteralPath (Join-Path $root "scripts\cg_sign_decision_v1.ps1") -PathType Leaf){
    $ss = [ordered]@{}
    foreach($n in $signerFiles){ $p = Join-Path $root ("scripts\" + $n); if(Test-Path -LiteralPath $p -PathType Leaf){ $ss[$n] = CC-Sha256File $p } }
    $pin.signer_sha256 = $ss
  }

  # The policy_hash this evaluator produces (it does not depend on the input): one probe evaluation
  # through the same runner invoke mode uses, against the hashes just pinned.
  $work = Join-Path $RepoRoot ("runtime\tmp\cgpin-" + [guid]::NewGuid().ToString("N"))
  CC-EnsureDir $work
  try {
    $probeMsg = [ordered]@{ message_id = "cg-pin-probe"; sender_node_id = "probe"; sender_identity = "probe"; recipient_identity = "probe"; recipient_node_id = "probe"; session_id = "probe"; policy_profile = "probe"; payload_sha256 = ("0" * 64) }
    $probeIn = Join-Path $work "probe.eval_input.json"
    CC-WriteTextFile $probeIn ((CC-ToCanonicalJson (CCG-BuildEvalInput ([pscustomobject]$probeMsg) ("0" * 64) "probe" "probe")) + "`n")
    $probeOut = Join-Path $work "probe.eval_output.json"
    $ov = $(if($null -eq $pin.overlay_sha256){ "none" } else { [string]$pin.overlay_sha256 })
    $eapPrev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    $log = & (CC-HostExe) -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "courier_covenant_gate_invoke_v1.ps1") -CovenantGateRoot $root -EvalInputPath $probeIn -OutPath $probeOut -EvaluatorSha256 $pin.evaluator_sha256 -BasePolicySha256 $pin.base_policy_sha256 -OverlaySha256 $ov 2>&1
    $code = $LASTEXITCODE; $ErrorActionPreference = $eapPrev
    if($code -ne 0 -or -not (Test-Path -LiteralPath $probeOut -PathType Leaf)){ Write-Host ($log | Out-String).Trim(); Fail "PROBE_FAILED" }
    $ph = [string](CC-ReadJsonFile $probeOut).policy_hash
    if($ph -cnotmatch '^[0-9a-f]{64}\z'){ Fail "PROBE_BAD_POLICY_HASH" }
    if(-not [string]::IsNullOrWhiteSpace($PolicyHash) -and $PolicyHash -cne $ph){ Fail ("POLICY_HASH_DIFFERS:" + $ph) }
    $pin.policy_hash = $ph
  } finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
} else {
  $pin.policy_hash = $PolicyHash
}

$path = Join-Path $RepoRoot "proofs\trust\covenant_gate_pin.json"
CC-EnsureDir (Split-Path -Parent $path)
[void](CC-WriteDocument $path $pin)
if($null -ne $pin.root){
  Write-Host ("COURIER_COVENANT_GATE_PIN_ROOT: " + $pin.root)
  Write-Host ("COURIER_COVENANT_GATE_PIN_EVALUATOR_SHA256: " + $pin.evaluator_sha256)
  Write-Host ("COURIER_COVENANT_GATE_PIN_BASE_POLICY_SHA256: " + $pin.base_policy_sha256)
  Write-Host ("COURIER_COVENANT_GATE_PIN_SIGNER: " + $(if($null -eq $pin.signer_sha256){ "none (Covenant Gate has no decision signer; required-gate deliveries will wait for approval)" } else { "pinned" }))
}
Write-Host ("COURIER_COVENANT_GATE_PIN_POLICY_HASH: " + $pin.policy_hash)
Write-Host ("COURIER_COVENANT_GATE_PIN_PATH: " + $path)
Write-Host "COURIER_COVENANT_GATE_PIN_OK"
exit 0
