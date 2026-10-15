# Covenant Courier -> Covenant Gate adapter (v1).
#
# Courier asks Covenant Gate for a decision on one delivery and verifies what comes back. Two modes:
#
#   invoke    COVENANT_GATE_ROOT (or -CovenantGateRoot) names a Covenant Gate checkout. Courier runs
#             Covenant Gate's own sealed evaluator (scripts/_lib_covenantgate_eval_v1.ps1, CG-EvalV1)
#             in a separate process against Covenant Gate's canonical base policy and overlay.
#   document  The caller supplies a covenantgate.eval_output.v1 document plus a detached ssh signature
#             (<doc>.sig, namespace covenant-gate/decision) from the principal the policy profile names.
#
# In both modes Courier recomputes input_hash from the eval input it built itself and recomputes
# evaluation_id; a mismatch is a refusal, never an allow. Every exchange writes a
# constellation.integration.receipt.v1 (covenant-courier > covenant-gate), including failures.
# Nothing here is needed for standalone delivery: with the profile's covenant_gate = "off" Covenant
# Gate is never consulted.

Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "_lib_covenant_courier_product_v1.ps1")
. (Join-Path $PSScriptRoot "_lib_constellation_integration_receipt_v1.ps1")

$script:CCG_Engine = "covenantgate.eval.v1"
$script:CCG_Contract = "covenantgate.eval_output.v1"

# Covenant Gate accepts enforcement points ingest.packet, policy.update.overlay and eval.request; a
# delivery is a generic evaluation request whose action type names the courier operation.
# The subject and recipient are the registry principals (the identities that actually sign and
# receive), not the message's self-asserted identities; those travel as claimed_* for policy use.
function CCG-BuildEvalInput($Message,[string]$PayloadSha256,[string]$SenderPrincipal,[string]$RecipientPrincipal){
  if([string]::IsNullOrWhiteSpace($SenderPrincipal) -or [string]::IsNullOrWhiteSpace($RecipientPrincipal)){ CC-Fail "CCG_FAIL:REGISTRY_PRINCIPAL_REQUIRED" }
  return [ordered]@{
    schema = "covenantgate.eval_input.v1"
    enforcement_point = "eval.request"
    subject = [ordered]@{ type = "courier_sender"; principal = $SenderPrincipal; node_id = [string]$Message.sender_node_id; claimed_identity = [string]$Message.sender_identity }
    action = [ordered]@{ type = "courier.deliver" }
    execution_surface = "covenant-courier"
    resource = [ordered]@{
      domain = "courier.message"
      message_id = [string]$Message.message_id
      payload_sha256 = $PayloadSha256
      policy_profile = [string]$Message.policy_profile
      recipient_claimed_identity = [string]$Message.recipient_identity
      recipient_node_id = [string]$Message.recipient_node_id
      recipient_principal = $RecipientPrincipal
      session_id = [string]$Message.session_id
    }
  }
}

# Covenant Gate's canonical bytes: sorted keys, compact, UTF-8, plus one LF.
function CCG-InputHash($EvalInput){ return (CC-Sha256Text ((CC-ToCanonicalJson $EvalInput) + "`n")) }

function CCG-VerifyOutput($Output,[string]$ExpectedInputHash){
  if($null -eq $Output){ return "CG_OUTPUT_MISSING" }
  foreach($n in @("schema","decision","reason_codes","policy_hash","input_hash","engine_version","evaluation_id")){
    if(-not (CC-HasProp $Output $n)){ return ("CG_OUTPUT_MISSING_FIELD_" + $n.ToUpperInvariant()) }
  }
  if([string]$Output.schema -cne $script:CCG_Contract){ return "CG_OUTPUT_BAD_SCHEMA" }
  if(@("allow","deny") -cnotcontains [string]$Output.decision){ return "CG_OUTPUT_BAD_DECISION" }
  if([string]$Output.engine_version -cne $script:CCG_Engine){ return "CG_OUTPUT_BAD_ENGINE" }
  foreach($h in @("policy_hash","input_hash","evaluation_id")){ if([string]$Output.$h -cnotmatch '^[0-9a-f]{64}\z'){ return ("CG_OUTPUT_BAD_" + $h.ToUpperInvariant()) } }
  if([string]$Output.input_hash -cne $ExpectedInputHash){ return "CG_INPUT_HASH_MISMATCH" }
  $eid = CC-Sha256Text ([string]$Output.policy_hash + "`n" + [string]$Output.input_hash + "`n" + $script:CCG_Engine)
  if([string]$Output.evaluation_id -cne $eid){ return "CG_EVALUATION_ID_MISMATCH" }
  return $null
}

# Runs Covenant Gate's sealed evaluator out of process. Returns @{ Ok; Token; OutputPath }.
function CCG-Invoke([string]$RepoRoot,[string]$CovenantGateRoot,[string]$EvalInputPath,[string]$OutPath){
  if([string]::IsNullOrWhiteSpace($CovenantGateRoot) -or -not (Test-Path -LiteralPath $CovenantGateRoot -PathType Container)){
    return @{ Ok = $false; Token = "COVENANT_GATE_UNAVAILABLE"; OutputPath = $null }
  }
  $lib = Join-Path $CovenantGateRoot "scripts\_lib_covenantgate_eval_v1.ps1"
  $base = Join-Path $CovenantGateRoot "policy\canonical.base.v1.json"
  if(-not (Test-Path -LiteralPath $lib -PathType Leaf) -or -not (Test-Path -LiteralPath $base -PathType Leaf)){
    return @{ Ok = $false; Token = "COVENANT_GATE_EVALUATOR_MISSING"; OutputPath = $null }
  }
  $runner = Join-Path $PSScriptRoot "courier_covenant_gate_invoke_v1.ps1"
  $log = & (CC-HostExe) -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $runner -CovenantGateRoot $CovenantGateRoot -EvalInputPath $EvalInputPath -OutPath $OutPath 2>&1
  $code = $LASTEXITCODE
  CC-WriteTextFile ($OutPath + ".log.txt") (($log | Out-String))
  if($code -ne 0 -or -not (Test-Path -LiteralPath $OutPath -PathType Leaf)){
    return @{ Ok = $false; Token = "COVENANT_GATE_EVALUATOR_FAILED"; OutputPath = $null }
  }
  return @{ Ok = $true; Token = $null; OutputPath = $OutPath }
}

# Verifies a supplied decision document and its detached signature.
function CCG-VerifyDocumentSignature([string]$RepoRoot,[string]$DocPath,[string]$Signer){
  if([string]::IsNullOrWhiteSpace($Signer)){ return "CG_DOCUMENT_SIGNER_NOT_CONFIGURED" }
  if(-not (Test-Path -LiteralPath ($DocPath + ".sig") -PathType Leaf)){ return "CG_DOCUMENT_SIGNATURE_MISSING" }
  $verify = Join-Path $PSScriptRoot "courier_verify_signature_v1.ps1"
  $out = & (CC-HostExe) -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $verify -RepoRoot $RepoRoot -MessagePath $DocPath -SignerIdentity $Signer -Namespace "covenant-gate/decision" 2>&1
  if($LASTEXITCODE -ne 0){
    $t = ($out | Out-String)
    if($t -match 'UNTRUSTED_SIGNER'){ return "CG_DOCUMENT_UNTRUSTED_SIGNER" }
    return "CG_DOCUMENT_SIGNATURE_INVALID"
  }
  return $null
}

# One consultation. Returns a hashtable:
#   Consulted (bool) Decision ("allow"|"deny"|$null) Outcome (receipt outcome) Token ReasonCodes
#   EvaluationId OutputSha256 InputSha256 Mode
function Invoke-CourierCovenantGate {
  param(
    [Parameter(Mandatory=$true)][string]$RepoRoot,
    [Parameter(Mandatory=$true)]$Message,
    [Parameter(Mandatory=$true)][string]$PayloadSha256,
    [Parameter(Mandatory=$true)][string]$SenderPrincipal,
    [Parameter(Mandatory=$true)][string]$RecipientPrincipal,
    [Parameter(Mandatory=$true)][string]$WorkDir,
    [string]$CovenantGateRoot,
    [string]$DecisionDocumentPath,
    [string]$DocumentSigner
  )
  CC-EnsureDir $WorkDir
  $evalInput = CCG-BuildEvalInput $Message $PayloadSha256 $SenderPrincipal $RecipientPrincipal
  $evalInputPath = Join-Path $WorkDir "covenantgate.eval_input.json"
  CC-WriteTextFile $evalInputPath ((CC-ToCanonicalJson $evalInput) + "`n")
  $inputHash = CC-Sha256File $evalInputPath
  $result = @{ Consulted = $false; Decision = $null; Outcome = "unavailable"; Token = "COVENANT_GATE_UNAVAILABLE"; ReasonCodes = @(); EvaluationId = $null; OutputSha256 = $null; InputSha256 = $inputHash; Mode = "none" }

  $outputPath = $null
  if(-not [string]::IsNullOrWhiteSpace($DecisionDocumentPath)){
    $result.Mode = "document"
    if(-not (Test-Path -LiteralPath $DecisionDocumentPath -PathType Leaf)){
      $result.Outcome = "failed"; $result.Token = "CG_DOCUMENT_MISSING"
    } else {
      $sigErr = CCG-VerifyDocumentSignature $RepoRoot $DecisionDocumentPath $DocumentSigner
      if($null -ne $sigErr){ $result.Outcome = "refused"; $result.Token = $sigErr; $result.OutputSha256 = (CC-Sha256File $DecisionDocumentPath) }
      else { $outputPath = $DecisionDocumentPath }
    }
  } elseif(-not [string]::IsNullOrWhiteSpace($CovenantGateRoot)) {
    $result.Mode = "invoke"
    $inv = CCG-Invoke $RepoRoot $CovenantGateRoot $evalInputPath (Join-Path $WorkDir "covenantgate.eval_output.json")
    if($inv.Ok){ $outputPath = $inv.OutputPath } else { $result.Outcome = $(if($inv.Token -eq "COVENANT_GATE_UNAVAILABLE"){ "unavailable" } else { "failed" }); $result.Token = $inv.Token }
  }

  if($null -ne $outputPath){
    $result.OutputSha256 = CC-Sha256File $outputPath
    $out = $null
    try { $out = CC-ReadJsonFile $outputPath } catch { $out = $null }
    $err = CCG-VerifyOutput $out $inputHash
    if($null -ne $err){
      $result.Outcome = "refused"; $result.Token = $err
    } else {
      $result.Consulted = $true
      $result.Decision = [string]$out.decision
      $result.ReasonCodes = @($out.reason_codes | ForEach-Object { [string]$_ })
      $result.EvaluationId = [string]$out.evaluation_id
      $result.Outcome = "ok"; $result.Token = $null
    }
  }

  # Record the exchange (also when nothing could be reached: "called and got nothing" is evidence).
  if($result.Mode -ne "none"){
    $carried = @()
    $rc = Write-ConstellationIntegrationReceipt -RepoRoot $RepoRoot -Consumer "covenant-courier" -Provider "covenant-gate" -Contract $script:CCG_Contract -RequestSha256 $inputHash -ResponseSha256 $result.OutputSha256 -Carried $carried -Outcome $result.Outcome -ErrorToken $result.Token
    $result.IntegrationReceiptSha256 = $rc.Sha256
  }
  return $result
}
