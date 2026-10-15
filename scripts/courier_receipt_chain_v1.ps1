param(
  [string]$RepoRoot = ".",
  [string]$ReceiptPath,
  [string]$ChainPath
)

# Product receipt chain (covenant_courier.product_receipt_chain.v1), append-only.
#
# Every existing chain entry is first re-verified against the receipt log: index, previous hash,
# receipt hash and chain hash are all recomputed. Any mismatch (an edited, removed or reordered
# receipt, or an edited chain) fails closed with COVENANT_COURIER_RECEIPT_CHAIN_FAIL:TAMPER_DETECTED
# and nothing is written. Only then are entries for new receipt lines appended. The chain is never
# rewritten in place.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_lib_covenant_courier_product_v1.ps1")

$RepoRoot = (Resolve-Path $RepoRoot).Path
if([string]::IsNullOrWhiteSpace($ReceiptPath)){ $ReceiptPath = Join-Path $RepoRoot "proofs\receipts\covenant_courier_product.ndjson" }
if([string]::IsNullOrWhiteSpace($ChainPath)){ $ChainPath = Join-Path $RepoRoot "proofs\receipts\covenant_courier_product.chain.ndjson" }

function Read-Lines([string]$Path){
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ return @() }
  $raw = [System.IO.File]::ReadAllText($Path,(CC-Utf8NoBom))
  if($raw.Contains("`r")){ throw "COVENANT_COURIER_RECEIPT_CHAIN_FAIL:CR_IN_LOG" }
  if($raw.Length -gt 0 -and -not $raw.EndsWith("`n")){ throw "COVENANT_COURIER_RECEIPT_CHAIN_FAIL:TRUNCATED_LAST_LINE" }
  return @($raw -split "`n" | Select-Object -SkipLast 1)
}

if(-not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)){
  if(Test-Path -LiteralPath $ChainPath -PathType Leaf){
    if(@(Read-Lines $ChainPath).Count -gt 0){ throw "COVENANT_COURIER_RECEIPT_CHAIN_FAIL:TAMPER_DETECTED:RECEIPTS_MISSING" }
  }
  Write-Host "COVENANT_COURIER_RECEIPT_CHAIN_STATUS:MISSING_PRODUCT_RECEIPTS"
  Write-Host "COVENANT_COURIER_RECEIPT_CHAIN_OK"
  exit 0
}

# One writer at a time: concurrent deliveries must not append duplicate chain entries.
$lockPath = $ChainPath + ".lock"
$lockDir = Split-Path -Parent $lockPath
if($lockDir){ CC-EnsureDir $lockDir }
$lock = $null
$until = [DateTime]::UtcNow.AddSeconds(60)
while($null -eq $lock){
  try { $lock = [System.IO.File]::Open($lockPath,[System.IO.FileMode]::OpenOrCreate,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None) }
  catch [System.IO.IOException] { if([DateTime]::UtcNow -gt $until){ throw "COVENANT_COURIER_RECEIPT_CHAIN_FAIL:LOCK_TIMEOUT" }; Start-Sleep -Milliseconds 25 }
}
try {

$lines = @(Read-Lines $ReceiptPath)
foreach($i in 0..([Math]::Max(0,$lines.Count-1))){
  if($lines.Count -eq 0){ break }
  if([string]::IsNullOrWhiteSpace($lines[$i])){ throw ("COVENANT_COURIER_RECEIPT_CHAIN_FAIL:EMPTY_RECEIPT_LINE:" + $i) }
  $obj = $null
  try { $obj = CC-ParseJson $lines[$i] } catch { throw ("COVENANT_COURIER_RECEIPT_CHAIN_FAIL:INVALID_RECEIPT_JSON:" + $i) }
  foreach($name in @("schema","receipt_id","message_id","event_type","time_utc","frame_id","payload_sha256","decision")){
    if(-not (CC-HasProp $obj $name)){ throw ("COVENANT_COURIER_RECEIPT_CHAIN_FAIL:MISSING_FIELD:" + $i + ":" + $name) }
  }
  if([string]$obj.schema -cne "covenant_courier.product_receipt.v1"){ throw ("COVENANT_COURIER_RECEIPT_CHAIN_FAIL:BAD_SCHEMA:" + $i) }
}

$zero = "0" * 64
$chainLines = @(Read-Lines $ChainPath)
if($chainLines.Count -gt $lines.Count){ throw "COVENANT_COURIER_RECEIPT_CHAIN_FAIL:TAMPER_DETECTED:CHAIN_LONGER_THAN_RECEIPTS" }

# 1. Re-verify the existing chain.
$prev = $zero
for($i = 0; $i -lt $chainLines.Count; $i++){
  $c = $null
  try { $c = CC-ParseJson $chainLines[$i] } catch { throw ("COVENANT_COURIER_RECEIPT_CHAIN_FAIL:TAMPER_DETECTED:INVALID_CHAIN_JSON:" + $i) }
  $receiptHash = CC-Sha256Text $lines[$i]
  $expected = CC-Sha256Text ($prev + ":" + $receiptHash)
  if([string]$c.schema -cne "covenant_courier.product_receipt_chain.v1" -or [int64]$c.index -ne $i -or [string]$c.previous_chain_hash -cne $prev -or [string]$c.receipt_sha256 -cne $receiptHash -or [string]$c.chain_hash -cne $expected){
    throw ("COVENANT_COURIER_RECEIPT_CHAIN_FAIL:TAMPER_DETECTED:" + $i)
  }
  $prev = $expected
}

# 2. Append entries for new receipts.
$appended = 0
for($i = $chainLines.Count; $i -lt $lines.Count; $i++){
  $receiptHash = CC-Sha256Text $lines[$i]
  $chainHash = CC-Sha256Text ($prev + ":" + $receiptHash)
  $entry = [ordered]@{
    schema = "covenant_courier.product_receipt_chain.v1"
    index = [int64]$i
    previous_chain_hash = $prev
    receipt_sha256 = $receiptHash
    chain_hash = $chainHash
  }
  CC-AppendLine $ChainPath (CC-ToJson $entry)
  $prev = $chainHash
  $appended++
}

} finally { $lock.Dispose() }

Write-Host ("COVENANT_COURIER_RECEIPT_CHAIN_ENTRIES: " + $lines.Count)
Write-Host ("COVENANT_COURIER_RECEIPT_CHAIN_APPENDED: " + $appended)
Write-Host ("COVENANT_COURIER_RECEIPT_CHAIN_HEAD: " + $prev)
Write-Host ("COVENANT_COURIER_RECEIPT_CHAIN_PATH: " + $ChainPath)
Write-Host "COVENANT_COURIER_RECEIPT_CHAIN_OK"
