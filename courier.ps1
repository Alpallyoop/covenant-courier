param(
  [Parameter(Position=0)][string]$Command = "help",
  [string]$RepoRoot = ".",
  [string]$From = "local/sender/demo",
  [string]$To = "local/recipient/demo",
  [string]$RecipientIdentity = "local/recipient/demo",
  [string]$RecipientNodeId = "node-beta",
  [string]$PayloadText = "hello from covenant courier",
  [string]$PolicyProfile = "default",
  [ValidateSet("","human","ai","service")][string]$Origin = "",
  # deliver
  [string]$MessagePath,
  [string]$PayloadPath,
  [string]$OutDir,
  [string]$CovenantGateRoot,
  [string]$CovenantGateDecisionPath,
  # trust-import
  [string]$TrustBundlePath,
  [string]$ExpectedSha256,
  [string]$NeverLostRoot,
  # secure-session (bind a Courier session to a VTP v2 session)
  [string]$SessionId,
  [switch]$LocalPair,
  [string]$Vtp2SessionId,
  [string]$SenderFingerprint,
  [string]$RecipientFingerprint,
  # receipt-chain: re-verify without appending
  [switch]$VerifyOnly,
  # node-signer (NeverLost-issued node signing keys)
  [string]$NodeId,
  [string]$Principal,
  # integration-receipts
  # integration-receipts: verify|list|nfl-inboxes; node-signer: keygen|adopt|status
  [ValidateSet("verify","list","nfl-inboxes","keygen","adopt","status")][string]$Action = "verify"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path $RepoRoot).Path
# Windows PowerShell 5.1 drops empty string arguments to child processes: pass -Origin only when set.
$OriginArgs = @(); if(-not [string]::IsNullOrWhiteSpace($Origin)){ $OriginArgs = @("-Origin",$Origin) }
$Scripts = Join-Path $RepoRoot "scripts"

function Run-PS {
  param(
    [Parameter(Mandatory=$true)][string]$Script,
    [string[]]$ChildArgs = @(),
    [int[]]$PassThroughCodes = @()
  )

  $ps = ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)

  & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Script @ChildArgs
  $code = $LASTEXITCODE

  if($PassThroughCodes -contains $code){ exit $code }
  if($code -ne 0){
    throw ("COURIER_CHILD_FAIL:" + $Script)
  }
}

if($Command -eq "help"){
  Write-Host "Covenant Courier"
  Write-Host "Product CLI"
  Write-Host ""
  Write-Host "Commands:"
  Write-Host "  .\courier.ps1 help"
  Write-Host "  .\courier.ps1 schema-test"
  Write-Host "  .\courier.ps1 prepare [-PayloadText ..] [-PolicyProfile default|public|confidential] [-Origin human|ai|service]"
  Write-Host "  .\courier.ps1 send [-PayloadText ..] [-PolicyProfile ..]"
  Write-Host "  .\courier.ps1 deliver -MessagePath <message.json> -PayloadPath <payload> [-OutDir ..]"
  Write-Host "                        [-CovenantGateRoot <dir> | -CovenantGateDecisionPath <doc>]"
  Write-Host "  .\courier.ps1 secure-session -SessionId <id> (-LocalPair | -Vtp2SessionId <hex> -SenderFingerprint <hex> -RecipientFingerprint <hex>)"
  Write-Host "                        bind a Courier session to a VTP v2 session (payload_encryption vtp2)"
  Write-Host "  .\courier.ps1 receive"
  Write-Host "  .\courier.ps1 receive-negative"
  Write-Host "  .\courier.ps1 receipts"
  Write-Host "  .\courier.ps1 receipt-chain [-VerifyOnly]"
  Write-Host "  .\courier.ps1 trust-import -TrustBundlePath <neverlost trust_bundle.json> -ExpectedSha256 <sha> [-NeverLostRoot <dir>]"
  Write-Host "  .\courier.ps1 integration-receipts [-Action verify|list|nfl-inboxes]"
  Write-Host "  .\courier.ps1 node-signer -Action keygen|adopt|status -NodeId <node> [-Principal single-tenant/device_agent/...]"
  Write-Host "                        NeverLost-issued node signing key (keygen -> issue in NeverLost -> trust-import -> adopt)"
  Write-Host "  .\courier.ps1 verify          product + VTP substrate proof"
  Write-Host "  .\courier.ps1 verify-all      verify + delivery, integration, trust-import and VTP v2 proofs"
  Write-Host ""
  Write-Host "Protocol substrate:"
  Write-Host "  .\vtp.ps1 verify"
  Write-Host "  .\vtp2.ps1 verify             (VTP v2 secure core; needs the .NET 10 SDK)"
  exit 0
}

if($Command -eq "schema-test"){
  Run-PS (Join-Path $Scripts "courier_schema_test_v1.ps1") @("-RepoRoot",$RepoRoot)
  exit 0
}

if($Command -eq "prepare"){
  Run-PS (Join-Path $Scripts "courier_prepare_message_v1.ps1") (@("-RepoRoot",$RepoRoot,"-From",$From,"-To",$RecipientIdentity,"-RecipientNodeId",$RecipientNodeId,"-PolicyProfile",$PolicyProfile,"-PayloadText",$PayloadText) + $OriginArgs)
  exit 0
}

if($Command -eq "send"){
  Run-PS (Join-Path $Scripts "courier_send_message_v1.ps1") (@("-RepoRoot",$RepoRoot,"-From",$From,"-RecipientIdentity",$RecipientIdentity,"-RecipientNodeId",$RecipientNodeId,"-PolicyProfile",$PolicyProfile,"-PayloadText",$PayloadText) + $OriginArgs)
  exit 0
}

if($Command -eq "deliver"){
  if([string]::IsNullOrWhiteSpace($MessagePath) -or [string]::IsNullOrWhiteSpace($PayloadPath)){ throw "COURIER_DELIVER_USAGE:MessagePath_and_PayloadPath_required" }
  $a = @("-RepoRoot",$RepoRoot,"-MessagePath",$MessagePath,"-PayloadPath",$PayloadPath)
  if(-not [string]::IsNullOrWhiteSpace($OutDir)){ $a += @("-OutDir",$OutDir) }
  if(-not [string]::IsNullOrWhiteSpace($CovenantGateRoot)){ $a += @("-CovenantGateRoot",$CovenantGateRoot) }
  if(-not [string]::IsNullOrWhiteSpace($CovenantGateDecisionPath)){ $a += @("-CovenantGateDecisionPath",$CovenantGateDecisionPath) }
  # Exit code contract: 0 sent, 42 refused by policy, anything else failed.
  Run-PS (Join-Path $Scripts "courier_deliver_v1.ps1") $a @(42)
  exit 0
}

if($Command -eq "node-signer"){
  if([string]::IsNullOrWhiteSpace($NodeId) -or @("keygen","adopt","status") -notcontains $Action){ throw "COURIER_NODE_SIGNER_USAGE:-Action_keygen|adopt|status_and_-NodeId_required" }
  $a = @("-RepoRoot",$RepoRoot,"-Action",$Action,"-NodeId",$NodeId)
  if(-not [string]::IsNullOrWhiteSpace($Principal)){ $a += @("-Principal",$Principal) }
  Run-PS (Join-Path $Scripts "courier_node_signer_v1.ps1") $a
  exit 0
}

if($Command -eq "secure-session"){
  if([string]::IsNullOrWhiteSpace($SessionId)){ throw "COURIER_SECURE_SESSION_USAGE:SessionId_required" }
  $a = @("-RepoRoot",$RepoRoot,"-SessionId",$SessionId)
  if($LocalPair){ $a += @("-LocalPair") }
  if(-not [string]::IsNullOrWhiteSpace($Vtp2SessionId)){ $a += @("-Vtp2SessionId",$Vtp2SessionId) }
  if(-not [string]::IsNullOrWhiteSpace($SenderFingerprint)){ $a += @("-SenderFingerprint",$SenderFingerprint) }
  if(-not [string]::IsNullOrWhiteSpace($RecipientFingerprint)){ $a += @("-RecipientFingerprint",$RecipientFingerprint) }
  Run-PS (Join-Path $Scripts "courier_secure_session_v1.ps1") $a
  exit 0
}

if($Command -eq "receipts"){
  Run-PS (Join-Path $Scripts "courier_receipts_latest_v1.ps1") @("-RepoRoot",$RepoRoot)
  exit 0
}

if($Command -eq "trust-import"){
  if([string]::IsNullOrWhiteSpace($TrustBundlePath) -or [string]::IsNullOrWhiteSpace($ExpectedSha256)){ throw "COURIER_TRUST_IMPORT_USAGE:TrustBundlePath_and_ExpectedSha256_required" }
  $a = @("-RepoRoot",$RepoRoot,"-TrustBundlePath",$TrustBundlePath,"-ExpectedSha256",$ExpectedSha256)
  if(-not [string]::IsNullOrWhiteSpace($NeverLostRoot)){ $a += @("-NeverLostRoot",$NeverLostRoot) }
  Run-PS (Join-Path $Scripts "courier_trust_import_neverlost_v1.ps1") $a
  exit 0
}

if($Command -eq "integration-receipts"){
  if(@("verify","list","nfl-inboxes") -notcontains $Action){ throw "COURIER_INTEGRATION_RECEIPTS_USAGE:-Action_verify|list|nfl-inboxes" }
  Run-PS (Join-Path $Scripts "courier_integration_receipts_v1.ps1") @("-RepoRoot",$RepoRoot,$Action)
  exit 0
}

if($Command -eq "verify"){
  Run-PS (Join-Path $Scripts "courier_verify_all_v1.ps1") @("-RepoRoot",$RepoRoot)
  exit 0
}

if($Command -eq "verify-all"){
  Run-PS (Join-Path $Scripts "courier_verify_all_v1.ps1") @("-RepoRoot",$RepoRoot,"-Full")
  exit 0
}

if($Command -eq "receive"){
  Run-PS (Join-Path $Scripts "courier_receive_message_v1.ps1") @("-RepoRoot",$RepoRoot,"-NodeId",$RecipientNodeId)
  exit 0
}

if($Command -eq "receive-negative"){
  Run-PS (Join-Path $Scripts "courier_receive_negative_v1.ps1") @("-RepoRoot",$RepoRoot,"-NodeId",$RecipientNodeId)
  exit 0
}

if($Command -eq "receipt-chain"){
  $a = @("-RepoRoot",$RepoRoot); if($VerifyOnly){ $a += @("-VerifyOnly") }
  Run-PS (Join-Path $Scripts "courier_receipt_chain_v1.ps1") $a
  exit 0
}
throw ("UNKNOWN_COURIER_COMMAND:" + $Command)
