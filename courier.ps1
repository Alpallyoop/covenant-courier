param(
  [Parameter(Position=0)][string]$Command = "help",
  [string]$RepoRoot = ".",
  [string]$From = "local/sender/demo",
  [string]$To = "local/recipient/demo",
  [string]$RecipientIdentity = "local/recipient/demo",
  [string]$RecipientNodeId = "node-beta",
  [string]$PayloadText = "hello from covenant courier",
  [string]$PolicyProfile = "default",
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
  # integration-receipts
  [ValidateSet("verify","list","nfl-inboxes")][string]$Action = "verify"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path $RepoRoot).Path
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
  Write-Host "  .\courier.ps1 prepare [-PayloadText ..] [-PolicyProfile default|public|confidential]"
  Write-Host "  .\courier.ps1 send [-PayloadText ..] [-PolicyProfile ..]"
  Write-Host "  .\courier.ps1 deliver -MessagePath <message.json> -PayloadPath <payload> [-OutDir ..]"
  Write-Host "                        [-CovenantGateRoot <dir> | -CovenantGateDecisionPath <doc>]"
  Write-Host "  .\courier.ps1 receive"
  Write-Host "  .\courier.ps1 receive-negative"
  Write-Host "  .\courier.ps1 receipts"
  Write-Host "  .\courier.ps1 receipt-chain"
  Write-Host "  .\courier.ps1 trust-import -TrustBundlePath <neverlost trust_bundle.json> -ExpectedSha256 <sha> [-NeverLostRoot <dir>]"
  Write-Host "  .\courier.ps1 integration-receipts [-Action verify|list|nfl-inboxes]"
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
  Run-PS (Join-Path $Scripts "courier_prepare_message_v1.ps1") @("-RepoRoot",$RepoRoot,"-From",$From,"-To",$RecipientIdentity,"-RecipientNodeId",$RecipientNodeId,"-PolicyProfile",$PolicyProfile,"-PayloadText",$PayloadText)
  exit 0
}

if($Command -eq "send"){
  Run-PS (Join-Path $Scripts "courier_send_message_v1.ps1") @("-RepoRoot",$RepoRoot,"-From",$From,"-RecipientIdentity",$RecipientIdentity,"-RecipientNodeId",$RecipientNodeId,"-PolicyProfile",$PolicyProfile,"-PayloadText",$PayloadText)
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
  Run-PS (Join-Path $Scripts "courier_receipt_chain_v1.ps1") @("-RepoRoot",$RepoRoot)
  exit 0
}
throw ("UNKNOWN_COURIER_COMMAND:" + $Command)
