# Covenant Courier -> Covenant Gate adapter (v1).
#
# Courier asks Covenant Gate for a decision on one delivery and verifies what comes back. Two modes:
#
#   invoke    COVENANT_GATE_ROOT (or -CovenantGateRoot) names a Covenant Gate checkout, which must be the
#             one pinned with courier.ps1 cg-pin (root and file hashes). Courier runs
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
    # origin comes from the message (human | ai | service); absent = "unspecified", which no
    # Covenant Gate allow rule names, so it stays default-deny.
    action = [ordered]@{ type = "courier.deliver"; origin = $(if((CC-HasProp $Message "origin") -and -not [string]::IsNullOrWhiteSpace([string]$Message.origin)){ [string]$Message.origin } else { "unspecified" }) }
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

# The Covenant Gate pin (courier.ps1 cg-pin): root and file hashes for invoke mode, and policy_hash, the
# only Covenant Gate policy whose decisions this installation accepts (sender and receiver). $null when
# there is no pin.
function CCG-ReadPin([string]$RepoRoot){
  $pinPath = Join-Path $RepoRoot "proofs\trust\covenant_gate_pin.json"
  if(-not (Test-Path -LiteralPath $pinPath -PathType Leaf)){ return $null }
  $pin = CC-ReadJsonFile $pinPath
  if([string]$pin.schema -cne "covenant_courier.covenant_gate_pin.v1"){ CC-Fail "CCG_FAIL:PIN_INVALID" }
  return $pin
}

# A decision is only as current as the policy it was made under: its policy_hash must be the pinned one.
function CCG-PolicyHashError($Output,$Pin){
  if($null -eq $Pin -or -not (CC-HasProp $Pin "policy_hash") -or [string]$Pin.policy_hash -cnotmatch '^[0-9a-f]{64}\z'){ return "CG_POLICY_NOT_PINNED" }
  if([string]$Output.policy_hash -cne [string]$Pin.policy_hash){ return "CG_POLICY_HASH_NOT_PINNED" }
  return $null
}

# Verifies Covenant Gate decision bytes and their detached signature (both in memory) for one message:
# signature by $Signer (namespace covenant-gate/decision) over exactly these bytes, a well-formed
# eval_output whose input_hash is the one rebuilt from this message, and the pinned policy_hash.
# Returns @{ Error; Output }.
function CCG-VerifySignedDecision([string]$RepoRoot,[byte[]]$DecisionBytes,[byte[]]$SignatureBytes,[string]$Signer,[string]$ExpectedInputHash){
  $r = @{ Error = $null; Output = $null }
  if([string]::IsNullOrWhiteSpace($Signer)){ $r.Error = "CG_DOCUMENT_SIGNER_NOT_CONFIGURED"; return $r }
  $stage = Join-Path $RepoRoot ("runtime\tmp\cgdec-" + [guid]::NewGuid().ToString("N"))
  [void][IO.Directory]::CreateDirectory($stage)
  try {
    $doc = Join-Path $stage "decision.json"
    [IO.File]::WriteAllBytes($doc,$DecisionBytes); [IO.File]::WriteAllBytes(($doc + ".sig"),$SignatureBytes)
    $verify = Join-Path $PSScriptRoot "courier_verify_signature_v1.ps1"
    $eapPrev = $ErrorActionPreference; $ErrorActionPreference = "Continue"; $out = & (CC-HostExe) -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $verify -RepoRoot $RepoRoot -MessagePath $doc -SignerIdentity $Signer -Namespace "covenant-gate/decision" 2>&1; $code = $LASTEXITCODE; $ErrorActionPreference = $eapPrev
    $t = ($out | Out-String)
    if($code -ne 0){ $r.Error = $(if($t -match 'UNTRUSTED_SIGNER'){ "CG_DOCUMENT_UNTRUSTED_SIGNER" } else { "CG_DOCUMENT_SIGNATURE_INVALID" }); return $r }
    $vh = ([regex]::Match($t,'COURIER_SIGNATURE_VERIFIED_SHA256: ([0-9a-f]{64})')).Groups[1].Value
    if($vh -cne (CC-Sha256Bytes $DecisionBytes)){ $r.Error = "CG_DOCUMENT_SIGNATURE_INVALID"; return $r }
  } finally { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
  $o = $null
  try { $o = CC-ParseJson ((New-Object System.Text.UTF8Encoding($false,$true)).GetString($DecisionBytes)) } catch { $r.Error = "CG_OUTPUT_INVALID_JSON"; return $r }
  $e = CCG-VerifyOutput $o $ExpectedInputHash
  if($null -eq $e){ $e = CCG-PolicyHashError $o (CCG-ReadPin $RepoRoot) }
  if($null -ne $e){ $r.Error = $e; return $r }
  $r.Output = $o
  return $r
}

# Invoke mode, after an allow: have the pinned Covenant Gate checkout sign its decision with the key
# NeverLost issued to Covenant Gate (scripts/cg_sign_decision_v1.ps1, Covenant Gate PR #7). The signer
# script and its library must match the pin; they run from a staged copy of the checked bytes. Returns
# the signature bytes, or $null when Covenant Gate has no signer (or it fails).
function CCG-SignWithCovenantGate([string]$RepoRoot,$Pin,[string]$DecisionPath){
  if($null -eq $Pin -or -not (CC-HasProp $Pin "signer_sha256") -or $null -eq $Pin.signer_sha256){ return $null }
  $root = [string]$Pin.root
  $stage = Join-Path $RepoRoot ("runtime\tmp\cgsign-" + [guid]::NewGuid().ToString("N"))
  [void][IO.Directory]::CreateDirectory((Join-Path $stage "scripts"))
  try {
    foreach($n in @("cg_sign_decision_v1.ps1","_lib_cg_decision_sig_v1.ps1")){
      $src = Join-Path $root ("scripts\" + $n)
      $expected = $(if(CC-HasProp $Pin.signer_sha256 $n){ [string]$Pin.signer_sha256.$n } else { $null })
      if($null -eq $expected){ continue }
      if(-not (Test-Path -LiteralPath $src -PathType Leaf)){ return $null }
      $b = [IO.File]::ReadAllBytes($src)
      if((CC-Sha256Bytes $b) -cne $expected){ CC-Fail "COVENANT_GATE_PIN_MISMATCH" }
      [IO.File]::WriteAllBytes((Join-Path $stage ("scripts\" + $n)),$b)
    }
    $signer = Join-Path $stage "scripts\cg_sign_decision_v1.ps1"
    if(-not (Test-Path -LiteralPath $signer -PathType Leaf)){ return $null }
    $eapPrev = $ErrorActionPreference; $ErrorActionPreference = "Continue"; $log = & (CC-HostExe) -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $signer -DecisionPath $DecisionPath -RepoRoot $root 2>&1; $code = $LASTEXITCODE; $ErrorActionPreference = $eapPrev
    CC-WriteTextFile ($DecisionPath + ".sign.log.txt") (($log | Out-String))
    if($code -ne 0 -or -not (Test-Path -LiteralPath ($DecisionPath + ".sig") -PathType Leaf)){ return $null }
    return [IO.File]::ReadAllBytes($DecisionPath + ".sig")
  } finally { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
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
  # Only a pinned Covenant Gate checkout is run (courier.ps1 cg-pin): a root named by an environment
  # variable or an argument alone is not trusted to execute as Courier. Unpinned = not reachable.
  $pin = CCG-ReadPin $RepoRoot
  if($null -eq $pin -or -not (CC-HasProp $pin "root") -or [string]::IsNullOrWhiteSpace([string]$pin.root)){ return @{ Ok = $false; Token = "COVENANT_GATE_ROOT_NOT_PINNED"; OutputPath = $null; Unpinned = $true } }
  $cmp = $(if($env:OS -eq "Windows_NT"){ [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal })
  $rootFull = (Resolve-Path -LiteralPath $CovenantGateRoot).Path
  if([string]$pin.schema -cne "covenant_courier.covenant_gate_pin.v1" -or -not [string]::Equals([string]$pin.root,$rootFull,$cmp)){ return @{ Ok = $false; Token = "COVENANT_GATE_ROOT_NOT_PINNED"; OutputPath = $null; Unpinned = $true } }
  $ovSha = $(if($null -eq $pin.overlay_sha256){ "none" } else { [string]$pin.overlay_sha256 })
  $runner = Join-Path $PSScriptRoot "courier_covenant_gate_invoke_v1.ps1"
  $eapPrev = $ErrorActionPreference; $ErrorActionPreference = "Continue"; $log = & (CC-HostExe) -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $runner -CovenantGateRoot $rootFull -EvalInputPath $EvalInputPath -OutPath $OutPath -EvaluatorSha256 ([string]$pin.evaluator_sha256) -BasePolicySha256 ([string]$pin.base_policy_sha256) -OverlaySha256 $ovSha 2>&1; $ErrorActionPreference = $eapPrev
  $code = $LASTEXITCODE
  CC-WriteTextFile ($OutPath + ".log.txt") (($log | Out-String))
  if($code -eq 3){ return @{ Ok = $false; Token = "COVENANT_GATE_PIN_MISMATCH"; OutputPath = $null; Changed = $true } }
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
  $eapPrev = $ErrorActionPreference; $ErrorActionPreference = "Continue"; $out = & (CC-HostExe) -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $verify -RepoRoot $RepoRoot -MessagePath $DocPath -SignerIdentity $Signer -Namespace "covenant-gate/decision" 2>&1; $ErrorActionPreference = $eapPrev
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
  $result = @{ Consulted = $false; Decision = $null; Outcome = "unavailable"; Token = "COVENANT_GATE_UNAVAILABLE"; ReasonCodes = @(); EvaluationId = $null; OutputSha256 = $null; InputSha256 = $inputHash; Mode = "none"; DecisionBytes = $null; SignatureBytes = $null; PolicyHash = $null }

  $outputPath = $null
  if(-not [string]::IsNullOrWhiteSpace($DecisionDocumentPath)){
    $result.Mode = "document"
    if(-not (Test-Path -LiteralPath $DecisionDocumentPath -PathType Leaf)){
      $result.Outcome = "failed"; $result.Token = "CG_DOCUMENT_MISSING"
    } else {
      # Read once; what is verified is what the envelope carries.
      $dBytes = [IO.File]::ReadAllBytes($DecisionDocumentPath)
      $result.OutputSha256 = CC-Sha256Bytes $dBytes
      if(-not (Test-Path -LiteralPath ($DecisionDocumentPath + ".sig") -PathType Leaf)){ $result.Outcome = "refused"; $result.Token = $(if([string]::IsNullOrWhiteSpace($DocumentSigner)){ "CG_DOCUMENT_SIGNER_NOT_CONFIGURED" } else { "CG_DOCUMENT_SIGNATURE_MISSING" }) }
      else {
        $sBytes = [IO.File]::ReadAllBytes($DecisionDocumentPath + ".sig")
        $sv = CCG-VerifySignedDecision $RepoRoot $dBytes $sBytes $DocumentSigner $inputHash
        if($null -ne $sv.Error){ $result.Outcome = "refused"; $result.Token = $sv.Error }
        else {
          $result.Consulted = $true; $result.Decision = [string]$sv.Output.decision
          $result.ReasonCodes = @($sv.Output.reason_codes | ForEach-Object { [string]$_ })
          $result.EvaluationId = [string]$sv.Output.evaluation_id; $result.PolicyHash = [string]$sv.Output.policy_hash
          $result.Outcome = "ok"; $result.Token = $null
          $result.DecisionBytes = $dBytes; $result.SignatureBytes = $sBytes
        }
      }
    }
  } elseif(-not [string]::IsNullOrWhiteSpace($CovenantGateRoot)) {
    $result.Mode = "invoke"
    $inv = CCG-Invoke $RepoRoot $CovenantGateRoot $evalInputPath (Join-Path $WorkDir "covenantgate.eval_output.json")
    if($inv.Ok){ $outputPath = $inv.OutputPath }
    else {
      # Unpinned root: not run, treated as unreachable. Pinned files changed: refused (tampering or an
      # unreviewed update).
      $result.Outcome = $(if($inv.Token -eq "COVENANT_GATE_UNAVAILABLE" -or $inv.ContainsKey("Unpinned")){ "unavailable" } elseif($inv.ContainsKey("Changed")){ "refused" } else { "failed" })
      $result.Token = $inv.Token
    }
  }

  if($null -ne $outputPath){
    $result.OutputSha256 = CC-Sha256File $outputPath
    $out = $null
    try { $out = CC-ReadJsonFile $outputPath } catch { $out = $null }
    $err = CCG-VerifyOutput $out $inputHash
    if($null -eq $err){ $err = CCG-PolicyHashError $out (CCG-ReadPin $RepoRoot) }
    if($null -ne $err){
      $result.Outcome = "refused"; $result.Token = $err
    } else {
      $result.Consulted = $true
      $result.Decision = [string]$out.decision
      $result.ReasonCodes = @($out.reason_codes | ForEach-Object { [string]$_ })
      $result.EvaluationId = [string]$out.evaluation_id; $result.PolicyHash = [string]$out.policy_hash
      $result.Outcome = "ok"; $result.Token = $null
      # Evidence the receiver can check: Covenant Gate's own signature over its decision.
      $result.DecisionBytes = [IO.File]::ReadAllBytes($outputPath)
      if($result.Decision -eq "allow"){
        try { $sig = CCG-SignWithCovenantGate $RepoRoot (CCG-ReadPin $RepoRoot) $outputPath } catch { $sig = $null; $result.Outcome = "refused"; $result.Token = "COVENANT_GATE_PIN_MISMATCH"; $result.Consulted = $false; $result.Decision = $null }
        if($null -ne $sig){
          $chk = CCG-VerifySignedDecision $RepoRoot $result.DecisionBytes $sig $DocumentSigner $inputHash
          if($null -eq $chk.Error){ $result.SignatureBytes = $sig }
        }
      }
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
