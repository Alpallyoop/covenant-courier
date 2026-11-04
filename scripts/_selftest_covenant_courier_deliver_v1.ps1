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
  # Continue: Windows PowerShell 5.1 turns redirected child stderr into a terminating error under Stop.
  $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
  try { $out = & $PS -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Script @A 2>&1; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
  return @{ Code = $code; Text = ($out | Out-String) }
}
function Must([bool]$Cond,[string]$Code){ if(-not $Cond){ throw ("COVENANT_COURIER_DELIVER_SELFTEST_FAIL:" + $Code) } }

# ---------------------------------------------------------------- sandbox
foreach($p in @("policy","policies","registry\nodes","registry\networks","registry\sessions","proofs\keys","proofs\trust","trust")){ CC-EnsureDir (Join-Path $Sandbox $p) }
$r = Child (Join-Path $PSScriptRoot "courier_bootstrap_local_trust_v1.ps1") @("-RepoRoot",$RepoRoot); Must ($r.Code -eq 0) "BOOTSTRAP"
Copy-Item -LiteralPath (Join-Path $RepoRoot "policy\courier_product_policy_v1.json") -Destination (Join-Path $Sandbox "policy") -Force
Copy-Item -LiteralPath (Join-Path $RepoRoot "policies\lexicon") -Destination (Join-Path $Sandbox "policies") -Recurse -Force
Copy-Item -Path (Join-Path $RepoRoot "proofs\keys\courier_courier-local_covenant_ed25519*") -Destination (Join-Path $Sandbox "proofs\keys") -Force
CC-RestrictPrivateKey (Join-Path $Sandbox "proofs\keys\courier_courier-local_covenant_ed25519")
# This machine's signer lines, without its receipt signer (the sandbox makes its own).
$sbAllowed = @([IO.File]::ReadAllLines((Join-Path $RepoRoot "proofs\trust\allowed_signers")) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and @($_.Trim() -split '\s+')[0] -cne "courier-receipts@local" })
[IO.File]::WriteAllText((Join-Path $Sandbox "proofs\trust\allowed_signers"),(($sbAllowed -join "`n") + "`n"))
$r = Child (Join-Path $PSScriptRoot "courier_seed_demo_registry_v1.ps1") @("-RepoRoot",$Sandbox); Must ($r.Code -eq 0) "SEED"
$r = Child (Join-Path $PSScriptRoot "courier_open_session_v1.ps1") @("-RepoRoot",$Sandbox,"-SessionId","session-alpha-beta-001","-SenderNodeId","node-alpha","-RecipientNodeId","node-beta","-NetworkId","courier-internal-net-v1","-SessionRole","message-delivery"); Must ($r.Code -eq 0) "OPEN_SESSION"
$r = Child (Join-Path $PSScriptRoot "courier_open_session_v1.ps1") @("-RepoRoot",$Sandbox,"-SessionId","session-closed-001","-SenderNodeId","node-alpha","-RecipientNodeId","node-beta","-NetworkId","courier-internal-net-v1","-SessionRole","message-delivery"); Must ($r.Code -eq 0) "OPEN_SESSION_2"
$r = Child (Join-Path $PSScriptRoot "courier_close_session_v1.ps1") @("-RepoRoot",$Sandbox,"-SessionId","session-closed-001"); Must ($r.Code -eq 0) "CLOSE_SESSION"

# A Covenant Gate decision signer of its own (never a node principal), trusted for covenant-gate/decision only.
$GateSigner = "covenant-gate-selftest@local"
$gk = Join-Path $Sandbox "proofs\keys\courier_covenant-gate-selftest_local_ed25519"
$kgExe = $(if($env:WINDIR -and (Test-Path -LiteralPath (Join-Path $env:WINDIR "System32\OpenSSH\ssh-keygen.exe"))){ Join-Path $env:WINDIR "System32\OpenSSH\ssh-keygen.exe" } else { (Get-Command ssh-keygen -ErrorAction Stop).Source })
$kp = Start-Process -FilePath $kgExe -ArgumentList ('-q -t ed25519 -N "" -C "gate" -f "' + $gk + '"') -Wait -PassThru -NoNewWindow
Must ($kp.ExitCode -eq 0) "GATE_KEYGEN"
CC-RestrictPrivateKey $gk
$gpub = @(([IO.File]::ReadAllText($gk + ".pub")).Trim() -split ' ')
[IO.File]::AppendAllText((Join-Path $Sandbox "proofs\trust\allowed_signers"),("`n" + $GateSigner + ' namespaces="covenant-gate/decision" ' + $gpub[0] + " " + $gpub[1] + "`n"))

# Test policy (inside the sandbox's policy folder: deliver refuses a policy file from anywhere else):
# the confidential profile names the Covenant Gate decision signer.
$pol = CC-ReadJsonFile (Join-Path $Sandbox "policy\courier_product_policy_v1.json")
$pol.profiles.confidential.covenant_gate_signer = $GateSigner
# Gate cases test the gate alone; VTP v2 payload encryption is tested through its own "sealed" profile.
$pol.profiles.confidential.payload_encryption = "none"
$sealed = CC-ParseJson (CC-ToCanonicalJson $pol.profiles.default)
$sealed.payload_encryption = "vtp2"
$pol.profiles | Add-Member -NotePropertyName "sealed" -NotePropertyValue $sealed
$TestPolicy = Join-Path $Sandbox "policy\policy.test.json"
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
  $a = @("-RepoRoot",$Root,"-MessagePath",$Case.Message,"-PayloadPath",$Case.Payload,"-OutDir",$out)
  # The sandbox uses the test policy; the real repository its own policy (deliver takes no other).
  if(@($Extra) -notcontains "-PolicyPath" -and $Root -eq $Sandbox){ $a += @("-PolicyPath",$TestPolicy) }
  $a += $Extra
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
$envR = CC-ReadJsonFile (Join-Path $res.Out "delivery.json"); Must ([string]$envR.message.notification_preview -eq "") "REDACTED_PREVIEW_NOT_IN_ENVELOPE"

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
$BadPolicy = Join-Path $Sandbox "policy\policy.bad.json"
[void](CC-WriteDocument $BadPolicy (CC-ToOrderedTree $badPol))
$c = New-Case "default" "x"
$res = Child $Deliver @("-RepoRoot",$Sandbox,"-MessagePath",$c.Message,"-PayloadPath",$c.Payload,"-OutDir",(Join-Path $c.Dir "out"),"-PolicyPath",$BadPolicy)
$res.Receipt = CC-ReadJsonFile (Join-Path $c.Dir "out\product_receipt.json")
Expect $res 1 "failed" "COURIER_POLICY_FAILED:POLICY_PROFILE_BAD_COVENANT_GATE" "misspelled-gate-mode-fails-closed"

# A policy file from outside this installation's policy folder is never used.
$OutsidePolicy = Join-Path $Run "policy.outside.json"
Copy-Item -LiteralPath $TestPolicy -Destination $OutsidePolicy
$c = New-Case "default" "x"
Expect (Deliver $c @("-PolicyPath",$OutsidePolicy)) 1 "failed" "COURIER_POLICY_FAILED:POLICY_PATH_NOT_IN_REPOSITORY" "policy-path-outside-repository"

# A gate signer that is a node principal could sign its own gate decision: refused.
$selfPol = CC-ReadJsonFile $TestPolicy
$selfPol.profiles.confidential.covenant_gate_signer = "courier-local@covenant"
$SelfPolicy = Join-Path $Sandbox "policy\policy.selfsigner.json"
[void](CC-WriteDocument $SelfPolicy (CC-ToOrderedTree $selfPol))
$c = New-Case "confidential" "board minutes"
Expect (Deliver $c @("-PolicyPath",$SelfPolicy)) 1 "failed" "COURIER_POLICY_FAILED:POLICY_PROFILE_GATE_SIGNER_IS_A_NODE" "gate-signer-is-a-node"

# Restricted terms survive folding: format characters, compatibility forms, combining marks, UTF-16
# text; bytes that are not text are never passed as allowed when a dictionary applies.
function Set-Bytes($Case,[byte[]]$B){
  [IO.File]::WriteAllBytes($Case.Payload,$B)
  $m = CC-ReadJsonFile $Case.Message; $m.payload_sha256 = (CC-Sha256Bytes $B)
  [void](CC-WriteDocument $Case.Message (CC-ToOrderedTree $m))
}
foreach($v in @(@("soft-hyphen",("a r" + [char]0xAD + "ose here")),@("zero-width-joiner",("a ro" + [char]0x200D + "se here")),@("fullwidth",("a " + [char]0xFF52 + [char]0xFF4F + [char]0xFF53 + [char]0xFF45)),@("combining-mark",("a ro" + [char]0x301 + "se")))){
  $c = New-Case "default" $v[1]
  Expect (Deliver $c) 42 "quarantined" "QUARANTINE:RESTRICTED_TERM" ("restricted-term-folded-" + $v[0])
}
$c = New-Case "default" "x"; Set-Bytes $c ([Text.Encoding]::Unicode.GetBytes("a rose here"))
Expect (Deliver $c) 42 "quarantined" "QUARANTINE:RESTRICTED_TERM" "restricted-term-utf16"
$c = New-Case "default" "x"; Set-Bytes $c ((CC-Utf8NoBom).GetBytes("a rose here") + [byte[]]@(0xFF))
Expect (Deliver $c) 42 "quarantined" "QUARANTINE:PAYLOAD_NOT_SCANNABLE" "payload-not-text-not-scanned"
$c = New-Case "default" "x" @{ notification_preview = ("ro" + [char]0xAD + "se") }
Expect (Deliver $c) 42 "quarantined" "QUARANTINE:RESTRICTED_TERM" "restricted-term-in-preview"

# A session that names its profile decides it: the message cannot pick a weaker one.
$r = Child (Join-Path $PSScriptRoot "courier_open_session_v1.ps1") @("-RepoRoot",$Sandbox,"-SessionId","session-pinned-001","-SenderNodeId","node-alpha","-RecipientNodeId","node-beta","-NetworkId","courier-internal-net-v1","-SessionRole","message-delivery","-SessionPolicyRef","confidential"); Must ($r.Code -eq 0) "OPEN_PINNED_SESSION"
$c = New-Case "default" "x" @{ session_id = "session-pinned-001" }
Expect (Deliver $c) 42 "rejected" "POLICY_PROFILE_NOT_SESSION_PROFILE" "session-profile-pinned"
# A closed session is never reopened by opening it again.
$r = Child (Join-Path $PSScriptRoot "courier_open_session_v1.ps1") @("-RepoRoot",$Sandbox,"-SessionId","session-closed-001","-SenderNodeId","node-alpha","-RecipientNodeId","node-beta","-NetworkId","courier-internal-net-v1","-SessionRole","message-delivery")
Must ($r.Code -ne 0 -and $r.Text -match "COURIER_SESSION_FAIL:SESSION_CLOSED") "CLOSED_SESSION_NOT_REOPENED"
$Cases++; Write-Host "COVENANT_COURIER_DELIVER_CASE_OK: closed-session-not-reopened -> COURIER_SESSION_FAIL:SESSION_CLOSED"

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

function New-GateDoc($Case,[string]$Decision,[switch]$WrongInput,[switch]$NoSign,[string]$PolicyHash = ("a" * 64)){
  $msg = CC-ReadJsonFile $Case.Message
  $inputHash = CCG-InputHash (CCG-BuildEvalInput $msg $Case.Obj.payload_sha256 "courier-local@covenant" "courier-local@covenant")
  if($WrongInput){ $inputHash = ("1" * 64) }
  $policyHash = $PolicyHash
  $doc = [ordered]@{
    schema = "covenantgate.eval_output.v1"; decision = $Decision; reason_codes = @($(if($Decision -eq "allow"){ "ALLOW_RULE_MATCHED" } else { "DENY_RULE_MATCHED" }))
    policy_hash = $policyHash; input_hash = $inputHash; engine_version = "covenantgate.eval.v1"
    evaluation_id = (CC-Sha256Text ($policyHash + "`n" + $inputHash + "`n" + "covenantgate.eval.v1"))
    matched_rules = [ordered]@{ allow = @(); deny = @() }
  }
  $p = Join-Path $Case.Dir "cg.eval_output.json"
  CC-WriteTextFile $p ((CC-ToCanonicalJson $doc) + "`n")
  if(-not $NoSign){
    $s = Child (Join-Path $PSScriptRoot "courier_sign_message_v1.ps1") @("-RepoRoot",$Sandbox,"-MessagePath",$p,"-SignerIdentity",$GateSigner,"-Namespace","covenant-gate/decision")
    Must ($s.Code -eq 0) "SIGN_GATE_DOC"
  }
  return $p
}

# Decisions count only under the pinned Covenant Gate policy.
$c = New-Case "confidential" "board minutes"
Expect (Deliver $c @("-CovenantGateDecisionPath",(New-GateDoc $c "allow"))) 42 "rejected" "COVENANT_GATE_REFUSED:CG_POLICY_NOT_PINNED" "gate-document-policy-not-pinned"
$r = Child (Join-Path $PSScriptRoot "courier_covenant_gate_pin_v1.ps1") @("-RepoRoot",$Sandbox,"-PolicyHash",("a" * 64)); Must ($r.Code -eq 0) ("PIN_POLICY:" + $r.Text)
$c = New-Case "confidential" "board minutes"
Expect (Deliver $c @("-CovenantGateDecisionPath",(New-GateDoc $c "allow" -PolicyHash ("c" * 64)))) 42 "rejected" "COVENANT_GATE_REFUSED:CG_POLICY_HASH_NOT_PINNED" "gate-document-other-policy"

$c = New-Case "confidential" "board minutes"
$gdoc = New-GateDoc $c "allow"
$res = Deliver $c @("-CovenantGateDecisionPath",$gdoc)
Expect $res 0 "sent" "POLICY_ALLOW" "gate-document-allow"
$last = @(Get-Content -LiteralPath $cirPath)[-1] | ConvertFrom-Json
Must ([string]$last.outcome -eq "ok" -and $null -eq $last.error_token) "CIR_OK_WRITTEN"
$envG = CC-ReadJsonFile (Join-Path $res.Out "delivery.json")
Must ((CC-HasProp $envG "covenant_gate_decision") -and [string]$envG.covenant_gate_decision.signer -eq $GateSigner -and (CC-Sha256Bytes ([Convert]::FromBase64String([string]$envG.covenant_gate_decision.decision_b64))) -eq (CC-Sha256File $gdoc)) "GATE_DECISION_CARRIED"

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

# Invoke mode runs only a pinned Covenant Gate checkout, and only while its files match the pin. The stub
# evaluator answers allow (policy "b"*64) in Covenant Gate's output form; its decision signer signs with
# the test gate key, so the delivery carries a gate-signed decision.
$stub = Join-Path $Run "stub-covenant-gate"
CC-EnsureDir (Join-Path $stub "scripts"); CC-EnsureDir (Join-Path $stub "policy")
CC-WriteTextFile (Join-Path $stub "policy\canonical.base.v1.json") '{"schema":"covenantgate.policy.v1"}'
CC-WriteTextFile (Join-Path $stub "scripts\_lib_covenantgate_eval_v1.ps1") ((@'
. '__LIB__'
function CG-EvalV1($Base,$Overlay,$In){
  $ih = CC-Sha256Text ((CC-ToCanonicalJson $In) + "`n"); $ph = ("b" * 64)
  return [ordered]@{ schema = "covenantgate.eval_output.v1"; decision = "allow"; reason_codes = @("ALLOW_RULE_MATCHED"); policy_hash = $ph; input_hash = $ih; engine_version = "covenantgate.eval.v1"; evaluation_id = (CC-Sha256Text ($ph + "`n" + $ih + "`n" + "covenantgate.eval.v1")); matched_rules = [ordered]@{ allow = @(); deny = @() } }
}
function CG-ToCanonJson($o){ return (CC-ToCanonicalJson $o) }
'@).Replace("__LIB__",(Join-Path $PSScriptRoot "_lib_covenant_courier_product_v1.ps1")))
$c = New-Case "confidential" "board minutes"
Expect (Deliver $c @("-CovenantGateRoot",$stub)) 42 "quarantined" "REQUIRE_APPROVAL:COVENANT_GATE_REQUIRED:COVENANT_GATE_ROOT_NOT_PINNED" "gate-invoke-unpinned-root-not-run"
$r = Child (Join-Path $PSScriptRoot "courier_covenant_gate_pin_v1.ps1") @("-RepoRoot",$Sandbox,"-CovenantGateRoot",$stub); Must ($r.Code -eq 0 -and $r.Text -match ("COURIER_COVENANT_GATE_PIN_POLICY_HASH: " + ("b" * 64))) ("PIN_STUB:" + $r.Text)
$c = New-Case "confidential" "board minutes"
Expect (Deliver $c @("-CovenantGateRoot",$stub)) 42 "quarantined" "REQUIRE_APPROVAL:COVENANT_GATE_REQUIRED:COVENANT_GATE_DECISION_UNSIGNED" "gate-invoke-allow-without-gate-signer"
CC-WriteTextFile (Join-Path $stub "scripts\cg_sign_decision_v1.ps1") @'
param([string]$DecisionPath,[string]$RepoRoot)
$kg = $(if($env:WINDIR -and (Test-Path -LiteralPath (Join-Path $env:WINDIR "System32\OpenSSH\ssh-keygen.exe"))){ Join-Path $env:WINDIR "System32\OpenSSH\ssh-keygen.exe" } else { (Get-Command ssh-keygen).Source })
$p = Start-Process -FilePath $kg -ArgumentList ('-Y sign -f "' + $env:CG_DECISION_SIGNER_KEY + '" -n covenant-gate/decision "' + $DecisionPath + '"') -Wait -PassThru -NoNewWindow
exit $p.ExitCode
'@
CC-WriteTextFile (Join-Path $stub "scripts\_lib_cg_decision_sig_v1.ps1") "# stub"
$r = Child (Join-Path $PSScriptRoot "courier_covenant_gate_pin_v1.ps1") @("-RepoRoot",$Sandbox,"-CovenantGateRoot",$stub); Must ($r.Code -eq 0 -and $r.Text -match "COURIER_COVENANT_GATE_PIN_SIGNER: pinned") ("PIN_STUB_SIGNER:" + $r.Text)
$env:CG_DECISION_SIGNER_KEY = $gk
try {
  $c = New-Case "confidential" "board minutes"
  $res = Deliver $c @("-CovenantGateRoot",$stub)
  Expect $res 0 "sent" "POLICY_ALLOW" "gate-invoke-allow-signed-by-gate"
  Must (CC-HasProp (CC-ReadJsonFile (Join-Path $res.Out "delivery.json")) "covenant_gate_decision") "INVOKE_GATE_DECISION_CARRIED"
  Add-Content -LiteralPath (Join-Path $stub "scripts\cg_sign_decision_v1.ps1") -Value "# changed after pinning"
  $c = New-Case "confidential" "board minutes"
  Expect (Deliver $c @("-CovenantGateRoot",$stub)) 42 "rejected" "COVENANT_GATE_REFUSED:COVENANT_GATE_PIN_MISMATCH" "gate-invoke-pinned-signer-changed"
} finally { $env:CG_DECISION_SIGNER_KEY = $null }
Add-Content -LiteralPath (Join-Path $stub "scripts\_lib_covenantgate_eval_v1.ps1") -Value "# changed after pinning"
$c = New-Case "confidential" "board minutes"
Expect (Deliver $c @("-CovenantGateRoot",$stub)) 42 "rejected" "COVENANT_GATE_REFUSED:COVENANT_GATE_PIN_MISMATCH" "gate-invoke-pinned-files-changed"
Remove-Item -LiteralPath (Join-Path $Sandbox "proofs\trust\covenant_gate_pin.json") -Force

$v = Child (Join-Path $PSScriptRoot "courier_integration_receipts_v1.ps1") @("-RepoRoot",$Sandbox,"verify")
Must ($v.Code -eq 0) ("CIR_CHAIN_VERIFY:" + $v.Text)

if(-not [string]::IsNullOrWhiteSpace($env:COVENANT_GATE_ROOT)){
  # Against the real Covenant Gate: human-originated deliveries are allowed only if its base policy
  # carries allow.courier.deliver.human; ai and unspecified origins are always default-deny.
  $cgBase = Join-Path $env:COVENANT_GATE_ROOT "policy\canonical.base.v1.json"
  $hasRule = (Test-Path -LiteralPath $cgBase) -and ([IO.File]::ReadAllText($cgBase).Contains("allow.courier.deliver.human"))
  $r = Child (Join-Path $PSScriptRoot "courier_covenant_gate_pin_v1.ps1") @("-RepoRoot",$Sandbox,"-CovenantGateRoot",$env:COVENANT_GATE_ROOT); Must ($r.Code -eq 0) ("PIN_REAL:" + $r.Text)
  foreach($o in @("human","ai","")){
    $ov = @{}; if($o -ne ""){ $ov = @{ origin = $o } }
    $c = New-Case "confidential" "board minutes" $ov
    $res = Deliver $c @("-CovenantGateRoot",$env:COVENANT_GATE_ROOT)
    if($null -eq $res.Receipt){ Write-Host $res.Text; throw "COVENANT_COURIER_DELIVER_SELFTEST_FAIL:GATE_INVOKE_NO_RECEIPT" }
    $last = @(Get-Content -LiteralPath $cirPath)[-1] | ConvertFrom-Json
    Must ([string]$last.outcome -eq "ok") ("GATE_INVOKE_OUTCOME:" + [string]$last.outcome + ":" + [string]$last.error_token)
    $name = "gate-invoke-real-covenant-gate-origin-" + $(if($o -eq ""){ "unspecified" } else { $o })
    if($o -eq "human" -and $hasRule){ Expect $res 0 "sent" "POLICY_ALLOW" $name }
    else { Expect $res 42 "rejected" "COVENANT_GATE_DENY:DEFAULT_DENY" $name }
  }
} else {
  Write-Host "COVENANT_COURIER_DELIVER_CASE_NOT_RUN: gate-invoke-real-covenant-gate (COVENANT_GATE_ROOT not set; not counted as a pass)"
}

# ---------------------------------------------------------------- VTP v2 payload encryption
if($env:OS -ne "Windows_NT" -and [string]::IsNullOrWhiteSpace($env:VTP2_STATE_KEY_FILE)){
  # A stable test key: the real repository's node states (sealed session test below) must open on
  # the next run too. Operators set VTP2_STATE_KEY_FILE themselves; this is only the self-test's.
  $kf = Join-Path $RepoRoot "runtime\vtp2\selftest.state.key"
  if(-not (Test-Path -LiteralPath $kf)){ CC-EnsureDir (Split-Path -Parent $kf); [IO.File]::WriteAllBytes($kf,[Security.Cryptography.RandomNumberGenerator]::GetBytes(32)) }
  & chmod 600 $kf
  $env:VTP2_STATE_KEY_FILE = $kf
}
$c = New-Case "sealed" "sealed payload alpha"
Expect (Deliver $c) 42 "quarantined" "REQUIRE_STRONGER_SESSION:VTP2_SESSION_NOT_BOUND" "vtp2-required-no-binding"
$r = Child (Join-Path $PSScriptRoot "courier_secure_session_v1.ps1") @("-RepoRoot",$Sandbox,"-SessionId","session-alpha-beta-001","-LocalPair")
Must ($r.Code -eq 0 -and $r.Text -match "COURIER_SECURE_SESSION_OK") ("SECURE_SESSION:" + $r.Text)
$c = New-Case "sealed" "sealed payload bravo"
$res = Deliver $c
Expect $res 0 "sent" "POLICY_ALLOW" "vtp2-sealed-delivery"
$envText = [IO.File]::ReadAllText((Join-Path $res.Out "delivery.json"))
$envObj = CC-ParseJson $envText
Must ((CC-HasProp $envObj "payload_vtp2_b64") -and -not (CC-HasProp $envObj "payload_b64")) "VTP2_ENVELOPE_FORM"
Must (-not $envText.Contains("sealed payload bravo") -and -not $envText.Contains([Convert]::ToBase64String((CC-Utf8NoBom).GetBytes("sealed payload bravo")))) "VTP2_NO_PLAINTEXT_IN_ENVELOPE"
Must ([string]$envObj.message.notification_preview -ceq "") "VTP2_NO_PREVIEW_IN_ENVELOPE"
$c = New-Case "default" "default profile on a bound session"
$res = Deliver $c
Expect $res 0 "sent" "POLICY_ALLOW" "bound-session-default-profile-encrypted"
$envObj = CC-ReadJsonFile (Join-Path $res.Out "delivery.json")
Must ((CC-HasProp $envObj "payload_vtp2_b64") -and -not (CC-HasProp $envObj "payload_b64")) "BOUND_SESSION_ALWAYS_SEALED"
$c = New-Case "sealed" ("a" * 600001)
Expect (Deliver $c) 42 "rejected" "PAYLOAD_TOO_LARGE" "vtp2-payload-over-envelope-limit"
$c = New-Case "sealed" "x"
$bp = Join-Path $Sandbox "registry\vtp2_bindings\session-alpha-beta-001.json"
$saved = [IO.File]::ReadAllText($bp)
[IO.File]::WriteAllText($bp,$saved.Replace('"sender_node_id":"node-alpha"','"sender_node_id":"node-mallory"'))
Expect (Deliver $c) 42 "rejected" "VTP2_BINDING_INVALID:VTP2_BINDING:NODE_MISMATCH" "vtp2-binding-tampered"
[IO.File]::WriteAllText($bp,$saved)

# ---------------------------------------------------------------- receipt chain tamper
$rl = Join-Path $Run "chain-tamper\receipts.ndjson"; $cl = Join-Path $Run "chain-tamper\chain.ndjson"
CC-EnsureDir (Split-Path -Parent $rl)
Copy-Item -LiteralPath (Join-Path $Sandbox "proofs\receipts\covenant_courier_product.ndjson") -Destination $rl
Copy-Item -LiteralPath (Join-Path $Sandbox "proofs\receipts\covenant_courier_product.chain.ndjson") -Destination $cl
foreach($x in @(".head.json",".head.json.sig")){ Copy-Item -LiteralPath (Join-Path $Sandbox ("proofs\receipts\covenant_courier_product.chain.ndjson" + $x)) -Destination ($cl + $x) }
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

# The signed head: rewriting log and chain together (consistently re-chained) still fails without the
# receipt key, and so does dropping the head, or the head's signature.
$hl = Join-Path $Run "chain-head"; CC-EnsureDir $hl
$hr = Join-Path $hl "receipts.ndjson"; $hc = Join-Path $hl "chain.ndjson"
Copy-Item -LiteralPath (Join-Path $Sandbox "proofs\receipts\covenant_courier_product.ndjson") -Destination $hr
Copy-Item -LiteralPath (Join-Path $Sandbox "proofs\receipts\covenant_courier_product.chain.ndjson") -Destination $hc
foreach($x in @(".head.json",".head.json.sig")){ Copy-Item -LiteralPath (Join-Path $Sandbox ("proofs\receipts\covenant_courier_product.chain.ndjson" + $x)) -Destination ($hc + $x) }
$ok = Child (Join-Path $PSScriptRoot "courier_receipt_chain_v1.ps1") @("-RepoRoot",$Sandbox,"-ReceiptPath",$hr,"-ChainPath",$hc,"-VerifyOnly")
Must ($ok.Code -eq 0) ("HEAD_CLEAN:" + $ok.Text)
# Consistent rewrite: edit receipt 1 and rebuild the chain entries from scratch.
$lines = @([IO.File]::ReadAllText($hr).Split("`n") | Where-Object { $_ -ne "" })
$lines[1] = $lines[1].Replace('"rejected"','"accepted"').Replace('"sent"','"accepted"')
[IO.File]::WriteAllText($hr,(($lines -join "`n") + "`n"))
$prev = "0" * 64; $chain = New-Object System.Collections.Generic.List[string]
for($i = 0; $i -lt $lines.Count; $i++){ $rh = CC-Sha256Text $lines[$i]; $ch = CC-Sha256Text ($prev + ":" + $rh); $chain.Add((CC-ToJson ([ordered]@{ schema = "covenant_courier.product_receipt_chain.v1"; index = [int64]$i; previous_chain_hash = $prev; receipt_sha256 = $rh; chain_hash = $ch }))); $prev = $ch }
[IO.File]::WriteAllText($hc,(($chain.ToArray() -join "`n") + "`n"))
$bad = Child (Join-Path $PSScriptRoot "courier_receipt_chain_v1.ps1") @("-RepoRoot",$Sandbox,"-ReceiptPath",$hr,"-ChainPath",$hc,"-VerifyOnly")
Must ($bad.Code -ne 0 -and $bad.Text -match "TAMPER_DETECTED:HEAD_MISMATCH") ("HEAD_REWRITE:" + $bad.Text)
# Forged head (edited to the rewritten chain) without the key: signature fails.
$h = CC-ReadJsonFile ($hc + ".head.json"); $h.chain_hash = $prev; $h.entries = [int64]$lines.Count
CC-WriteTextFile ($hc + ".head.json") (CC-ToCanonicalJson $h)
$bad = Child (Join-Path $PSScriptRoot "courier_receipt_chain_v1.ps1") @("-RepoRoot",$Sandbox,"-ReceiptPath",$hr,"-ChainPath",$hc,"-VerifyOnly")
Must ($bad.Code -ne 0 -and $bad.Text -match "TAMPER_DETECTED:HEAD_SIGNATURE") ("HEAD_FORGED:" + $bad.Text)
# Dropping the head.
Remove-Item -LiteralPath ($hc + ".head.json"),($hc + ".head.json.sig") -Force
$bad = Child (Join-Path $PSScriptRoot "courier_receipt_chain_v1.ps1") @("-RepoRoot",$Sandbox,"-ReceiptPath",$hr,"-ChainPath",$hc)
Must ($bad.Code -ne 0 -and $bad.Text -match "HEAD_MISSING") ("HEAD_DROPPED:" + $bad.Text)
$Cases++; Write-Host "COVENANT_COURIER_DELIVER_CASE_OK: consistent log+chain rewrite, forged head, dropped head -> refused (receipt key required)"

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

# Encrypted delivery end to end in the real repository, on its own session so the demo session
# (plaintext) is unaffected; a plaintext envelope on a VTP v2-bound session is refused on receive.
$sid = "session-alpha-beta-sealed"
$r = Child (Join-Path $PSScriptRoot "courier_seed_demo_registry_v1.ps1") @("-RepoRoot",$RepoRoot); Must ($r.Code -eq 0) "REAL_SEED"
$r = Child (Join-Path $PSScriptRoot "courier_open_session_v1.ps1") @("-RepoRoot",$RepoRoot,"-SessionId",$sid,"-SenderNodeId","node-alpha","-RecipientNodeId","node-beta","-NetworkId","courier-internal-net-v1","-SessionRole","message-delivery"); Must ($r.Code -eq 0) "REAL_OPEN_SEALED"
$r = Child (Join-Path $PSScriptRoot "courier_secure_session_v1.ps1") @("-RepoRoot",$RepoRoot,"-SessionId",$sid,"-LocalPair"); Must ($r.Code -eq 0) ("REAL_SECURE_SESSION:" + $r.Text)
# Downgrade 1: a plaintext envelope sent before the session was bound, received after it was.
$bpReal = Join-Path $RepoRoot ("registry\vtp2_bindings\" + $sid + ".json")
$savedBinding = [IO.File]::ReadAllText($bpReal); Remove-Item -LiteralPath $bpReal -Force
$c = New-Case "default" "downgrade attempt" @{ session_id = $sid }
$res = Deliver $c @() $RepoRoot
[IO.File]::WriteAllText($bpReal,$savedBinding)
Must ($res.Code -eq 0) ("REAL_PLAIN_BEFORE_BINDING_SEND:" + $res.Text)
$r = Child (Join-Path $RepoRoot "courier.ps1") @("receive","-RepoRoot",$RepoRoot)
Must ($r.Code -ne 0 -and $r.Text -match "VTP2_DOWNGRADE_REFUSED") ("DOWNGRADE_NOT_REFUSED:" + $r.Text)
$Cases++; Write-Host "COVENANT_COURIER_DELIVER_CASE_OK: plaintext-on-vtp2-session -> rejected:VTP2_DOWNGRADE_REFUSED"
# Downgrade 2: plaintext for a profile the receiver's own policy requires sealed (the self-test
# sender's policy has confidential = none; the real policy has confidential = vtp2), unbound session.
$sidConf = "session-alpha-beta-conf"
$r = Child (Join-Path $PSScriptRoot "courier_open_session_v1.ps1") @("-RepoRoot",$RepoRoot,"-SessionId",$sidConf,"-SenderNodeId","node-alpha","-RecipientNodeId","node-beta","-NetworkId","courier-internal-net-v1","-SessionRole","message-delivery"); Must ($r.Code -eq 0) "REAL_OPEN_CONF"
# This sender's policy: confidential without encryption and without the gate (the gate is tested above).
$polPlain = CC-ReadJsonFile $TestPolicy
$polPlain.profiles.confidential.covenant_gate = "off"
# (Deliver takes a policy only from the repository's policy folder: written there for this case, removed after.)
$TestPolicyPlainConf = Join-Path $RepoRoot "policy\_selftest_plain_confidential.json"
[void](CC-WriteDocument $TestPolicyPlainConf (CC-ToOrderedTree $polPlain))
$c = New-Case "confidential" "confidential in plaintext" @{ session_id = $sidConf }
try { $res = Deliver $c @("-PolicyPath",$TestPolicyPlainConf) $RepoRoot } finally { Remove-Item -LiteralPath $TestPolicyPlainConf -Force -ErrorAction SilentlyContinue }
Must ($res.Code -eq 0) ("REAL_CONFIDENTIAL_PLAIN_SEND:" + $res.Text)
$r = Child (Join-Path $RepoRoot "courier.ps1") @("receive","-RepoRoot",$RepoRoot)
Must ($r.Code -ne 0 -and $r.Text -match "VTP2_DOWNGRADE_REFUSED") ("PROFILE_DOWNGRADE_NOT_REFUSED:" + $r.Text)
$Cases++; Write-Host "COVENANT_COURIER_DELIVER_CASE_OK: plaintext-for-vtp2-profile -> rejected:VTP2_DOWNGRADE_REFUSED"
# A bound session always carries the payload sealed, whatever the profile (here the real policy's default).
$c = New-Case "default" "end to end sealed payload" @{ session_id = $sid }
$res = Deliver $c @() $RepoRoot
Must ($res.Code -eq 0) ("REAL_SEALED_SEND:" + $res.Text)
$r = Child (Join-Path $RepoRoot "courier.ps1") @("receive","-RepoRoot",$RepoRoot)
Must ($r.Code -eq 0 -and $r.Text -match "COURIER_RECEIVE_DECRYPTED") ("REAL_SEALED_RECEIVE:" + $r.Text)
$inbox = $null; foreach($l in ($r.Text -split "`n")){ if($l -match 'COURIER_RECEIVE_INBOX:\s+(.+)$'){ $inbox = $Matches[1].Trim() } }
Must ([IO.File]::ReadAllText((Join-Path $inbox "payload.bin")) -eq "end to end sealed payload") "SEALED_INBOX_PAYLOAD"
$Cases++; Write-Host "COVENANT_COURIER_DELIVER_CASE_OK: vtp2 sealed delivery -> decrypted and released to inbox"

# Private keys copied or made for the sandbox do not outlive the run.
Remove-Item -LiteralPath (Join-Path $Sandbox "proofs\keys") -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ("COVENANT_COURIER_DELIVER_SELFTEST_CASES: " + $Cases)
Write-Host "COVENANT_COURIER_DELIVER_SELFTEST_OK"
