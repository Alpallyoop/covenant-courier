param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

# Positive and negative proof of the governed delivery path (courier_deliver_v1.ps1), the
# append-only receipt chain and the receive-side envelope check.
#
# Most cases run in a sandbox repository root under runtime/selftest_deliver/<run>/repo so their
# receipts (including the Constellation integration receipts the Covenant Gate cases write) never
# mix with this machine's real evidence. The receive cases use the real repository, like the
# other product tests.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_lib_covenant_courier_product_v1.ps1")
. (Join-Path $PSScriptRoot "_lib_courier_covenant_gate_v1.ps1")

$RepoRoot = (Resolve-Path $RepoRoot).Path
$PS = CC-HostExe
$Deliver = Join-Path $PSScriptRoot "courier_deliver_v1.ps1"
$Run = Join-Path $RepoRoot ("runtime\selftest_deliver\" + (CC-UtcStampId))
$Sandbox = Join-Path $Run "repo"
$Cases = 0

function Child([string]$Script,[string[]]$A){
  $out = & $PS -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Script @A 2>&1
  return @{ Code = $LASTEXITCODE; Text = ($out | Out-String) }
}
function Must([bool]$Cond,[string]$Code){ if(-not $Cond){ throw ("COVENANT_COURIER_DELIVER_SELFTEST_FAIL:" + $Code) } }

# ---------------------------------------------------------------- sandbox
foreach($p in @("policy","policies","registry\nodes","registry\networks","registry\sessions","proofs\keys","proofs\trust","trust")){ CC-EnsureDir (Join-Path $Sandbox $p) }
$r = Child (Join-Path $PSScriptRoot "courier_bootstrap_local_trust_v1.ps1") @("-RepoRoot",$RepoRoot); Must ($r.Code -eq 0) "BOOTSTRAP"
Copy-Item -LiteralPath (Join-Path $RepoRoot "policy\courier_product_policy_v1.json") -Destination (Join-Path $Sandbox "policy") -Force
Copy-Item -LiteralPath (Join-Path $RepoRoot "policies\lexicon") -Destination (Join-Path $Sandbox "policies") -Recurse -Force
Copy-Item -Path (Join-Path $RepoRoot "proofs\keys\courier_courier-local_covenant_ed25519*") -Destination (Join-Path $Sandbox "proofs\keys") -Force
Copy-Item -LiteralPath (Join-Path $RepoRoot "proofs\trust\allowed_signers") -Destination (Join-Path $Sandbox "proofs\trust") -Force
$r = Child (Join-Path $PSScriptRoot "courier_seed_demo_registry_v1.ps1") @("-RepoRoot",$Sandbox); Must ($r.Code -eq 0) "SEED"
$r = Child (Join-Path $PSScriptRoot "courier_open_session_v1.ps1") @("-RepoRoot",$Sandbox,"-SessionId","session-alpha-beta-001","-SenderNodeId","node-alpha","-RecipientNodeId","node-beta","-NetworkId","courier-internal-net-v1","-SessionRole","message-delivery"); Must ($r.Code -eq 0) "OPEN_SESSION"
$r = Child (Join-Path $PSScriptRoot "courier_open_session_v1.ps1") @("-RepoRoot",$Sandbox,"-SessionId","session-closed-001","-SenderNodeId","node-alpha","-RecipientNodeId","node-beta","-NetworkId","courier-internal-net-v1","-SessionRole","message-delivery"); Must ($r.Code -eq 0) "OPEN_SESSION_2"
$r = Child (Join-Path $PSScriptRoot "courier_close_session_v1.ps1") @("-RepoRoot",$Sandbox,"-SessionId","session-closed-001"); Must ($r.Code -eq 0) "CLOSE_SESSION"

# Test policy: the confidential profile names the Covenant Gate decision signer.
$pol = CC-ReadJsonFile (Join-Path $Sandbox "policy\courier_product_policy_v1.json")
$pol.profiles.confidential | Add-Member -NotePropertyName "covenant_gate_signer" -NotePropertyValue "courier-local@covenant"
$TestPolicy = Join-Path $Run "policy.test.json"
[void](CC-WriteDocument $TestPolicy (CC-ToOrderedTree $pol))

$n = 0
function New-Case([string]$Profile,[string]$Text,[hashtable]$Override = @{},[string]$Raw = $null){
  $script:n++
  $dir = Join-Path $Run ("case-" + $script:n)
  CC-EnsureDir $dir
  $bytes = (CC-Utf8NoBom).GetBytes($Text)
  [IO.File]::WriteAllBytes((Join-Path $dir "payload.bin"),$bytes)
  $m = [ordered]@{
    schema = "covenant_courier.message.v1"; message_id = ("ccmsg-selftest-" + (CC-UtcStampId) + "-" + $script:n)
    sender_identity = "local/sender/selftest"; recipient_identity = "local/recipient/selftest"
    sender_node_id = "node-alpha"; recipient_node_id = "node-beta"; organization_id = $null
    session_id = "session-alpha-beta-001"; policy_profile = $Profile; notification_preview = "Quarterly update"
    payload_sha256 = (CC-Sha256Bytes $bytes); created_utc = (CC-UtcNow)
  }
  foreach($k in $Override.Keys){ if($null -eq $Override[$k] -and $k.StartsWith("-")){ $m.Remove($k.Substring(1)) } else { $m[$k] = $Override[$k] } }
  $mp = Join-Path $dir "message.json"
  if(-not [string]::IsNullOrEmpty($Raw)){ CC-WriteTextFile $mp $Raw } else { [void](CC-WriteDocument $mp $m) }
  return @{ Dir = $dir; Message = $mp; Payload = (Join-Path $dir "payload.bin"); Id = $m.message_id; Obj = $m }
}

function Deliver($Case,[string[]]$Extra = @(),[string]$Root = $Sandbox){
  $out = Join-Path $Case.Dir "out"
  $a = @("-RepoRoot",$Root,"-MessagePath",$Case.Message,"-PayloadPath",$Case.Payload,"-OutDir",$out,"-PolicyPath",$TestPolicy) + $Extra
  $res = Child $Deliver $a
  $receipt = $null
  $rp = Join-Path $out "product_receipt.json"
  if(Test-Path -LiteralPath $rp){ $receipt = CC-ReadJsonFile $rp }
  return @{ Code = $res.Code; Text = $res.Text; Receipt = $receipt; Out = $out; ReceiptSha = $(if(Test-Path -LiteralPath $rp){ CC-Sha256File $rp } else { $null }) }
}

function Expect($Res,[int]$Code,[string]$Decision,[string]$ReasonLike,[string]$Name){
  if($Res.Code -ne $Code -or $null -eq $Res.Receipt -or [string]$Res.Receipt.decision -ne $Decision -or ([string]$Res.Receipt.reason_code) -notlike $ReasonLike){
    Write-Host $Res.Text
    throw ("COVENANT_COURIER_DELIVER_SELFTEST_FAIL:" + $Name + ":code=" + $Res.Code + ":decision=" + $(if($Res.Receipt){ $Res.Receipt.decision } else { "none" }) + ":reason=" + $(if($Res.Receipt){ $Res.Receipt.reason_code } else { "none" }))
  }
  $script:Cases++
  Write-Host ("COVENANT_COURIER_DELIVER_CASE_OK: " + $Name + " -> " + $Decision + ":" + [string]$Res.Receipt.reason_code)
}

# ---------------------------------------------------------------- positive
$c = New-Case "default" "hello from the deliver selftest"
$res = Deliver $c
Expect $res 0 "sent" "POLICY_ALLOW" "allow-default"
foreach($f in @("message.json","policy_decision.json","notification.json","product_receipt.json","delivery.json","delivery.json.sig")){ Must (Test-Path -LiteralPath (Join-Path $res.Out $f)) ("MISSING_OUTPUT_" + $f) }
$pd = CC-ReadJsonFile (Join-Path $res.Out "policy_decision.json"); Must ([string]$pd.decision -eq "allow") "POLICY_DECISION_DOC"
$nt = CC-ReadJsonFile (Join-Path $res.Out "notification.json"); Must ([string]$nt.display_mode -eq "generic" -and [string]$nt.preview -eq "New secure message") "NOTIFICATION_GENERIC"
$env1 = CC-ReadJsonFile (Join-Path $res.Out "delivery.json"); Must ([string]$env1.schema -eq "covenant_courier.delivery.v1") "ENVELOPE_SCHEMA"
Must ((CC-Sha256Bytes ([Convert]::FromBase64String([string]$env1.payload_b64))) -eq $c.Obj.payload_sha256) "ENVELOPE_PAYLOAD"
$frames = @(Get-ChildItem -LiteralPath (Join-Path $Sandbox "runtime\nodes\node-beta\inbox\drop") -Directory | Where-Object { $_.Name -eq [string]$res.Receipt.frame_id })
Must ($frames.Count -eq 1) "FRAME_IN_DROP"
$chainLast = @(Get-Content -LiteralPath (Join-Path $Sandbox "proofs\receipts\covenant_courier_product.chain.ndjson"))[-1] | ConvertFrom-Json
Must ([string]$chainLast.receipt_sha256 -eq $res.ReceiptSha) "RECEIPT_FILE_HASH_IS_CHAIN_HASH"

$c = New-Case "public" "a rose by any other name"
$res = Deliver $c
Expect $res 0 "sent" "RESTRICTED_TERM_NOTIFICATION_REDACTED" "redact-notification"
$nt = CC-ReadJsonFile (Join-Path $res.Out "notification.json"); Must ([string]$nt.display_mode -eq "redacted" -and [string]$nt.preview -eq "[redacted]") "NOTIFICATION_REDACTED"

$c = New-Case "default" ""
Expect (Deliver $c) 0 "sent" "POLICY_ALLOW" "empty-payload"

# ---------------------------------------------------------------- negative: input
$c = New-Case "default" "x" @{} "{not json"
Expect (Deliver $c) 42 "rejected" "MESSAGE_INVALID:MESSAGE_INVALID_JSON" "invalid-json"
$c = New-Case "default" "x" @{ smuggled = "field" }
Expect (Deliver $c) 42 "rejected" "MESSAGE_INVALID:MESSAGE:UNKNOWN_FIELD:smuggled" "unknown-field"
$c = New-Case "default" "x" @{ "-session_id" = $null }
Expect (Deliver $c) 42 "rejected" "MESSAGE_INVALID:MESSAGE:MISSING_FIELD:session_id" "missing-field"
$c = New-Case "default" "x" @{ message_id = "../escape" }
Expect (Deliver $c) 42 "rejected" "MESSAGE_INVALID:MESSAGE:BAD_MESSAGE_ID" "path-traversal-message-id"
$c = New-Case "default" "x" @{ message_id = "ccmsg-newline`n" }
Expect (Deliver $c) 42 "rejected" "MESSAGE_INVALID:MESSAGE:BAD_MESSAGE_ID" "trailing-newline-id"
$c = New-Case "default" "x"
[IO.File]::Delete($c.Payload)
$res = Deliver $c
Expect $res 1 "failed" "COURIER_DELIVER_FAILED:MISSING_PAYLOAD" "missing-payload-still-receipted"
$c = New-Case "default" "payload" @{ payload_sha256 = ("0" * 64) }
Expect (Deliver $c) 42 "rejected" "PAYLOAD_HASH_MISMATCH" "payload-hash-mismatch"

# ---------------------------------------------------------------- negative: policy
$c = New-Case "no-such-profile" "x"
Expect (Deliver $c) 42 "rejected" "POLICY_PROFILE_UNKNOWN" "unknown-profile"
$c = New-Case "default" "x" @{ recipient_node_id = "node-gamma" }
Expect (Deliver $c) 42 "rejected" "RECIPIENT_NODE_NOT_ALLOWED" "recipient-not-allowed"
$c = New-Case "default" "x" @{ session_id = "session-closed-001" }
Expect (Deliver $c) 42 "rejected" "SESSION_NOT_OPEN" "session-closed"
$c = New-Case "default" "x" @{ session_id = "session-never-opened" }
Expect (Deliver $c) 42 "rejected" "SESSION_UNKNOWN" "session-unknown"
$c = New-Case "confidential" ("y" * 300000)
Expect (Deliver $c) 42 "rejected" "PAYLOAD_TOO_LARGE" "payload-too-large"
$c = New-Case "default" "meet by the Roses at noon"
$res = Deliver $c
Expect $res 42 "quarantined" "QUARANTINE:RESTRICTED_TERM" "restricted-term-quarantine"
Must (Test-Path -LiteralPath (Join-Path $Sandbox ("runtime\product_messages\quarantine\" + $c.Id + "\payload.bin"))) "QUARANTINE_STORED"
Must (-not (Test-Path -LiteralPath (Join-Path $res.Out "delivery.json"))) "QUARANTINE_NOT_SENT"
$c = New-Case "confidential" "a rose"
Expect (Deliver $c) 42 "rejected" "RESTRICTED_TERM" "restricted-term-reject"

$badPol = CC-ReadJsonFile $TestPolicy
$badPol.profiles.default.covenant_gate = "requried"
$BadPolicy = Join-Path $Run "policy.bad.json"
[void](CC-WriteDocument $BadPolicy (CC-ToOrderedTree $badPol))
$c = New-Case "default" "x"
$res = Child $Deliver @("-RepoRoot",$Sandbox,"-MessagePath",$c.Message,"-PayloadPath",$c.Payload,"-OutDir",(Join-Path $c.Dir "out"),"-PolicyPath",$BadPolicy)
$res.Receipt = CC-ReadJsonFile (Join-Path $c.Dir "out\product_receipt.json")
Expect $res 1 "failed" "COURIER_POLICY_FAILED:POLICY_PROFILE_BAD_COVENANT_GATE" "misspelled-gate-mode-fails-closed"

# ---------------------------------------------------------------- Covenant Gate
$cirPath = Join-Path $Sandbox "proofs\integration_receipts\covenant-courier__covenant-gate\receipts.ndjson"
$c = New-Case "confidential" "board minutes"
$savedGate = $env:COVENANT_GATE_ROOT; $env:COVENANT_GATE_ROOT = $null
try { $res = Deliver $c } finally { $env:COVENANT_GATE_ROOT = $savedGate }
Expect $res 42 "quarantined" "REQUIRE_APPROVAL:COVENANT_GATE_REQUIRED:COVENANT_GATE_UNAVAILABLE" "gate-required-not-configured"
Must (-not (Test-Path -LiteralPath $cirPath)) "NO_RECEIPT_WHEN_NOT_CONSULTED"

$c = New-Case "confidential" "board minutes"
Expect (Deliver $c @("-CovenantGateRoot",(Join-Path $Run "no-covenant-gate-here"))) 42 "quarantined" "REQUIRE_APPROVAL:COVENANT_GATE_REQUIRED:COVENANT_GATE_UNAVAILABLE" "gate-required-unavailable"
$last = @(Get-Content -LiteralPath $cirPath)[-1] | ConvertFrom-Json
Must ([string]$last.outcome -eq "unavailable" -and [string]$last.error_token -eq "COVENANT_GATE_UNAVAILABLE") "CIR_UNAVAILABLE_WRITTEN"

function New-GateDoc($Case,[string]$Decision,[switch]$WrongInput,[switch]$NoSign){
  $msg = CC-ReadJsonFile $Case.Message
  $inputHash = CCG-InputHash (CCG-BuildEvalInput $msg $Case.Obj.payload_sha256 "courier-local@covenant" "courier-local@covenant")
  if($WrongInput){ $inputHash = ("1" * 64) }
  $policyHash = ("a" * 64)
  $doc = [ordered]@{
    schema = "covenantgate.eval_output.v1"; decision = $Decision; reason_codes = @($(if($Decision -eq "allow"){ "ALLOW_RULE_MATCHED" } else { "DENY_RULE_MATCHED" }))
    policy_hash = $policyHash; input_hash = $inputHash; engine_version = "covenantgate.eval.v1"
    evaluation_id = (CC-Sha256Text ($policyHash + "`n" + $inputHash + "`n" + "covenantgate.eval.v1"))
    matched_rules = [ordered]@{ allow = @(); deny = @() }
  }
  $p = Join-Path $Case.Dir "cg.eval_output.json"
  CC-WriteTextFile $p ((CC-ToCanonicalJson $doc) + "`n")
  if(-not $NoSign){
    $s = Child (Join-Path $PSScriptRoot "courier_sign_message_v1.ps1") @("-RepoRoot",$Sandbox,"-MessagePath",$p,"-SignerIdentity","courier-local@covenant","-Namespace","covenant-gate/decision")
    Must ($s.Code -eq 0) "SIGN_GATE_DOC"
  }
  return $p
}

$c = New-Case "confidential" "board minutes"
Expect (Deliver $c @("-CovenantGateDecisionPath",(New-GateDoc $c "allow"))) 0 "sent" "POLICY_ALLOW" "gate-document-allow"
$last = @(Get-Content -LiteralPath $cirPath)[-1] | ConvertFrom-Json
Must ([string]$last.outcome -eq "ok" -and $null -eq $last.error_token) "CIR_OK_WRITTEN"

$c = New-Case "confidential" "board minutes"
Expect (Deliver $c @("-CovenantGateDecisionPath",(New-GateDoc $c "deny"))) 42 "rejected" "COVENANT_GATE_DENY:DENY_RULE_MATCHED" "gate-document-deny"

$c = New-Case "confidential" "board minutes"
Expect (Deliver $c @("-CovenantGateDecisionPath",(New-GateDoc $c "allow" -WrongInput))) 42 "rejected" "COVENANT_GATE_REFUSED:CG_INPUT_HASH_MISMATCH" "gate-document-wrong-input"

$c = New-Case "confidential" "board minutes"
Expect (Deliver $c @("-CovenantGateDecisionPath",(New-GateDoc $c "allow" -NoSign))) 42 "rejected" "COVENANT_GATE_REFUSED:CG_DOCUMENT_SIGNATURE_MISSING" "gate-document-unsigned"

$c = New-Case "confidential" "board minutes"
$doc = New-GateDoc $c "allow"
$t = [IO.File]::ReadAllText($doc).Replace('ALLOW_RULE_MATCHED','ALLOW_RULE_EDITED!')
[IO.File]::WriteAllText($doc,$t)
Expect (Deliver $c @("-CovenantGateDecisionPath",$doc)) 42 "rejected" "COVENANT_GATE_REFUSED:CG_DOCUMENT_SIGNATURE_INVALID" "gate-document-tampered"

$v = Child (Join-Path $PSScriptRoot "courier_integration_receipts_v1.ps1") @("-RepoRoot",$Sandbox,"verify")
Must ($v.Code -eq 0) ("CIR_CHAIN_VERIFY:" + $v.Text)

if(-not [string]::IsNullOrWhiteSpace($env:COVENANT_GATE_ROOT)){
  $c = New-Case "confidential" "board minutes"
  $res = Deliver $c @("-CovenantGateRoot",$env:COVENANT_GATE_ROOT)
  if($null -eq $res.Receipt){ Write-Host $res.Text; throw "COVENANT_COURIER_DELIVER_SELFTEST_FAIL:GATE_INVOKE_NO_RECEIPT" }
  $last = @(Get-Content -LiteralPath $cirPath)[-1] | ConvertFrom-Json
  Must ([string]$last.outcome -eq "ok") ("GATE_INVOKE_OUTCOME:" + [string]$last.outcome + ":" + [string]$last.error_token)
  Write-Host ("COVENANT_COURIER_DELIVER_CASE_OK: gate-invoke-real-covenant-gate -> " + [string]$res.Receipt.decision + ":" + [string]$res.Receipt.reason_code)
  $Cases++
} else {
  Write-Host "COVENANT_COURIER_DELIVER_CASE_NOT_RUN: gate-invoke-real-covenant-gate (COVENANT_GATE_ROOT not set; not counted as a pass)"
}

# ---------------------------------------------------------------- receipt chain tamper
$rl = Join-Path $Run "chain-tamper\receipts.ndjson"; $cl = Join-Path $Run "chain-tamper\chain.ndjson"
CC-EnsureDir (Split-Path -Parent $rl)
Copy-Item -LiteralPath (Join-Path $Sandbox "proofs\receipts\covenant_courier_product.ndjson") -Destination $rl
Copy-Item -LiteralPath (Join-Path $Sandbox "proofs\receipts\covenant_courier_product.chain.ndjson") -Destination $cl
$ok = Child (Join-Path $PSScriptRoot "courier_receipt_chain_v1.ps1") @("-RepoRoot",$Sandbox,"-ReceiptPath",$rl,"-ChainPath",$cl)
Must ($ok.Code -eq 0 -and $ok.Text -match "APPENDED: 0") "CHAIN_CLEAN_REVERIFY"
$lines = [IO.File]::ReadAllText($rl).Split("`n")
$lines[1] = $lines[1].Replace('"rejected"','"accepted"').Replace('"sent"','"accepted"')
[IO.File]::WriteAllText($rl,($lines -join "`n"))
$bad = Child (Join-Path $PSScriptRoot "courier_receipt_chain_v1.ps1") @("-RepoRoot",$Sandbox,"-ReceiptPath",$rl,"-ChainPath",$cl)
Must ($bad.Code -ne 0 -and $bad.Text -match "TAMPER_DETECTED:1") "CHAIN_EDIT_DETECTED"
$Cases++; Write-Host "COVENANT_COURIER_DELIVER_CASE_OK: receipt-edit -> TAMPER_DETECTED"
Copy-Item -LiteralPath (Join-Path $Sandbox "proofs\receipts\covenant_courier_product.ndjson") -Destination $rl -Force
$lines = @([IO.File]::ReadAllText($rl).Split("`n") | Where-Object { $_ -ne "" })
[IO.File]::WriteAllText($rl,((@($lines[0]) + @($lines | Select-Object -Skip 2)) -join "`n") + "`n")
$bad = Child (Join-Path $PSScriptRoot "courier_receipt_chain_v1.ps1") @("-RepoRoot",$Sandbox,"-ReceiptPath",$rl,"-ChainPath",$cl)
Must ($bad.Code -ne 0 -and $bad.Text -match "TAMPER_DETECTED") "CHAIN_REMOVAL_DETECTED"
$Cases++; Write-Host "COVENANT_COURIER_DELIVER_CASE_OK: receipt-removed -> TAMPER_DETECTED"

# ---------------------------------------------------------------- receive (real repository)
$r = Child (Join-Path $RepoRoot "courier.ps1") @("send","-RepoRoot",$RepoRoot,"-PayloadText","receive selftest payload")
Must ($r.Code -eq 0) ("REAL_SEND:" + $r.Text)
$frameId = $null; foreach($l in ($r.Text -split "`n")){ if($l -match 'COURIER_SEND_FRAME_ID:\s+(.+)$'){ $frameId = $Matches[1].Trim() } }
$dropFrame = Join-Path $RepoRoot ("runtime\nodes\node-beta\inbox\drop\" + $frameId)
$frameObj = CC-ReadJsonFile (Join-Path $dropFrame "frame.json")
$envFile = Join-Path $dropFrame ([string]$frameObj.message_rel)
$envText = [IO.File]::ReadAllText($envFile)
$envObj = CC-ParseJson $envText
$forged = [Convert]::ToBase64String((CC-Utf8NoBom).GetBytes("forged payload"))
[IO.File]::WriteAllText($envFile,$envText.Replace([string]$envObj.payload_b64,$forged))
$r = Child (Join-Path $RepoRoot "courier.ps1") @("receive","-RepoRoot",$RepoRoot)
Must ($r.Code -ne 0 -and $r.Text -match "FRAME_REJECTED") ("TAMPERED_FRAME_NOT_REJECTED:" + $r.Text)
$lastReceipt = @(Get-Content -LiteralPath (Join-Path $RepoRoot "proofs\receipts\covenant_courier_product.ndjson"))[-1] | ConvertFrom-Json
Must ([string]$lastReceipt.decision -eq "rejected" -and [string]$lastReceipt.frame_id -eq $frameId -and [string]$lastReceipt.reason_code -like "TRANSPORT_REJECTED:*") "REJECT_RECEIPT_WRITTEN"
$Cases++; Write-Host ("COVENANT_COURIER_DELIVER_CASE_OK: tampered-frame -> rejected:" + [string]$lastReceipt.reason_code)

$r = Child (Join-Path $RepoRoot "courier.ps1") @("send","-RepoRoot",$RepoRoot,"-PayloadText","receive selftest payload two")
Must ($r.Code -eq 0) "REAL_SEND_2"
$r = Child (Join-Path $RepoRoot "courier.ps1") @("receive","-RepoRoot",$RepoRoot)
Must ($r.Code -eq 0 -and $r.Text -match "COVENANT_COURIER_RECEIVE_OK") ("REAL_RECEIVE:" + $r.Text)
$inbox = $null; foreach($l in ($r.Text -split "`n")){ if($l -match 'COURIER_RECEIVE_INBOX:\s+(.+)$'){ $inbox = $Matches[1].Trim() } }
Must ([IO.File]::ReadAllText((Join-Path $inbox "payload.bin")) -eq "receive selftest payload two") "INBOX_PAYLOAD"
$Cases++; Write-Host "COVENANT_COURIER_DELIVER_CASE_OK: receive -> accepted, payload released to inbox"

Write-Host ("COVENANT_COURIER_DELIVER_SELFTEST_CASES: " + $Cases)
Write-Host "COVENANT_COURIER_DELIVER_SELFTEST_OK"
