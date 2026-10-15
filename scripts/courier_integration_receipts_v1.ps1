param(
  [string]$RepoRoot = ".",
  [Parameter(Position=0)][ValidateSet("verify","list","nfl-inboxes")][string]$Action = "verify"
)

# Lists and verifies the constellation.integration.receipt.v1 files Courier writes as an emitter
# (proofs/integration_receipts/<consumer>__<provider>/receipts.ndjson).
#   verify       recompute every line and chain; fails closed on any defect
#   list         integration, count, chain head, NFL artifact label
#   nfl-inboxes  nfl.inbox_registry.v1 entries NFL can add to witness these folders (mode receipt)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_lib_constellation_integration_receipt_v1.ps1")

$RepoRoot = (Resolve-Path $RepoRoot).Path
$root = Join-Path $RepoRoot "proofs\integration_receipts"
$dirs = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Sort-Object Name)

if($Action -eq "nfl-inboxes"){
  $entries = New-Object System.Collections.Generic.List[object]
  foreach($d in $dirs){
    $parts = $d.Name -split '__'
    if($parts.Count -ne 2){ continue }
    $entries.Add([ordered]@{ name = ("courier-" + $parts[1] + "-receipts"); path = ("../covenant-courier/proofs/integration_receipts/" + $d.Name); mode = "receipt"; integration = ($parts[0] + ">" + $parts[1]) })
  }
  Write-Host (CC-ToJson ([ordered]@{ inboxes = $entries.ToArray() }))
  Write-Host "COURIER_INTEGRATION_RECEIPTS_NFL_INBOXES_OK"
  exit 0
}

$total = 0
foreach($d in $dirs){
  $f = Join-Path $d.FullName "receipts.ndjson"
  if(-not (Test-Path -LiteralPath $f -PathType Leaf)){ continue }
  $r = Test-ConstellationIntegrationReceiptFile -Path $f
  $parts = $d.Name -split '__'
  Write-Host ("COURIER_INTEGRATION_RECEIPTS: " + $parts[0] + ">" + $parts[1] + " count=" + $r.Count + " head=" + $r.Head + " label=constellation.integration.receipt.v1:" + $parts[0] + ">" + $parts[1])
  $total += $r.Count
}
Write-Host ("COURIER_INTEGRATION_RECEIPTS_TOTAL: " + $total)
if($Action -eq "verify"){ Write-Host "COURIER_INTEGRATION_RECEIPTS_VERIFY_OK" } else { Write-Host "COURIER_INTEGRATION_RECEIPTS_LIST_OK" }
