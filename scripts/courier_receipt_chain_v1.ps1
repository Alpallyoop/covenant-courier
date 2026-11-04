param(
  [string]$RepoRoot = ".",
  [string]$ReceiptPath,
  [string]$ChainPath,
  # Re-verify only: report receipts not yet chained (COVENANT_COURIER_RECEIPT_CHAIN_UNCHAINED) and write
  # nothing. Read-only callers (the Global Workbench plugin) use this.
  [switch]$VerifyOnly
)

# Product receipt chain (covenant_courier.product_receipt_chain.v1), append-only.
#
# Every existing chain entry is first re-verified against the receipt log: index, previous hash,
# receipt hash and chain hash are all recomputed. Any mismatch (an edited, removed or reordered
# receipt, or an edited chain) fails closed with COVENANT_COURIER_RECEIPT_CHAIN_FAIL:TAMPER_DETECTED
# and nothing is written. Only then are entries for new receipt lines appended. The chain is never
# rewritten in place.
#
# Signed head (covenant_courier.receipt_chain_head.v1, <chain>.head.json + .sig): after every append the
# entry count and chain hash are signed by this installation's receipt signer (courier-receipts@local,
# namespace courier/receipt-chain, created on first use under proofs/keys/). Every run checks the
# signature and that the chain still contains the signed head, so rewriting the log and chain together
# needs the receipt key. A chain without a head is signed on its next append (first use); -VerifyOnly
# refuses a non-empty chain without a valid head. Not covered: restoring an older signed state as a whole
# (that needs an outside witness).

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_lib_covenant_courier_product_v1.ps1")

$RepoRoot = (Resolve-Path $RepoRoot).Path
$DefaultLog = [string]::IsNullOrWhiteSpace($ReceiptPath)
$ReceiptKeyExisted = Test-Path -LiteralPath (Join-Path $RepoRoot "proofs\keys\courier_courier-receipts_local_ed25519") -PathType Leaf
$ReceiptSigner = "courier-receipts@local"
$ReceiptNamespace = "courier/receipt-chain"
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

# 1b. The signed head: the chain must still hold what was signed.
$HeadPath = $ChainPath + ".head.json"
function Test-SignedHead(){
  if(-not (Test-Path -LiteralPath $HeadPath -PathType Leaf)){ return $null }
  $eapPrev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
  $v = & (CC-HostExe) -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "courier_verify_signature_v1.ps1") -RepoRoot $RepoRoot -MessagePath $HeadPath -SignerIdentity $ReceiptSigner -Namespace $ReceiptNamespace 2>&1
  $vc = $LASTEXITCODE; $ErrorActionPreference = $eapPrev
  if($vc -ne 0){ throw "COVENANT_COURIER_RECEIPT_CHAIN_FAIL:TAMPER_DETECTED:HEAD_SIGNATURE" }
  $vh = ([regex]::Match(($v | Out-String),'COURIER_SIGNATURE_VERIFIED_SHA256: ([0-9a-f]{64})')).Groups[1].Value
  $hb = [IO.File]::ReadAllBytes($HeadPath)
  if($vh -cne (CC-Sha256Bytes $hb)){ throw "COVENANT_COURIER_RECEIPT_CHAIN_FAIL:TAMPER_DETECTED:HEAD_SIGNATURE" }
  $h = CC-ParseJson ((CC-Utf8NoBom).GetString($hb))
  if([string]$h.schema -cne "covenant_courier.receipt_chain_head.v1"){ throw "COVENANT_COURIER_RECEIPT_CHAIN_FAIL:TAMPER_DETECTED:HEAD_SCHEMA" }
  $n = [int64]$h.entries
  if($n -lt 0 -or $n -gt $chainLines.Count){ throw "COVENANT_COURIER_RECEIPT_CHAIN_FAIL:TAMPER_DETECTED:HEAD_BEYOND_CHAIN" }
  $at = $(if($n -eq 0){ $zero } else { [string](CC-ParseJson $chainLines[$n - 1]).chain_hash })
  if($at -cne [string]$h.chain_hash){ throw "COVENANT_COURIER_RECEIPT_CHAIN_FAIL:TAMPER_DETECTED:HEAD_MISMATCH" }
  return $h
}
$signedHead = Test-SignedHead
# A head may be missing only before this installation ever signed one (first use of the receipt signer) or
# for a new, empty chain of a log other than the product log. A product log whose chain and head were
# removed is not silently re-chained.
if($null -eq $signedHead){
  if($VerifyOnly -and $chainLines.Count -gt 0){ throw "COVENANT_COURIER_RECEIPT_CHAIN_FAIL:HEAD_MISSING" }
  if($ReceiptKeyExisted -and $chainLines.Count -gt 0){ throw "COVENANT_COURIER_RECEIPT_CHAIN_FAIL:HEAD_MISSING" }
  if($ReceiptKeyExisted -and $DefaultLog -and $lines.Count -gt 1){ throw "COVENANT_COURIER_RECEIPT_CHAIN_FAIL:HEAD_MISSING" }
}

function Ensure-ReceiptSigner(){
  $key = Join-Path $RepoRoot "proofs\keys\courier_courier-receipts_local_ed25519"
  if(-not (Test-Path -LiteralPath $key -PathType Leaf)){
    CC-EnsureDir (Split-Path -Parent $key)
    $kg = $(if($env:WINDIR -and (Test-Path -LiteralPath (Join-Path $env:WINDIR "System32\OpenSSH\ssh-keygen.exe"))){ Join-Path $env:WINDIR "System32\OpenSSH\ssh-keygen.exe" } else { $c = Get-Command ssh-keygen -ErrorAction SilentlyContinue; if($null -eq $c){ throw "COVENANT_COURIER_RECEIPT_CHAIN_FAIL:SSH_KEYGEN_NOT_FOUND" }; $c.Source })
    $pk = Start-Process -FilePath $kg -ArgumentList ('-q -t ed25519 -N "" -C "{0}" -f "{1}"' -f $ReceiptSigner,$key) -Wait -PassThru -NoNewWindow
    if($pk.ExitCode -ne 0){ throw "COVENANT_COURIER_RECEIPT_CHAIN_FAIL:RECEIPT_SIGNER_KEYGEN" }
    CC-RestrictPrivateKey $key
  }
  $parts = @(([IO.File]::ReadAllText($key + ".pub")).Trim() -split '\s+')
  $line = $ReceiptSigner + ' namespaces="' + $ReceiptNamespace + '" ' + $parts[0] + " " + $parts[1]
  $allowed = Join-Path $RepoRoot "proofs\trust\allowed_signers"
  CC-EnsureDir (Split-Path -Parent $allowed)
  $have = @()
  if(Test-Path -LiteralPath $allowed -PathType Leaf){ $have = @([IO.File]::ReadAllLines($allowed)) }
  if(@($have | Where-Object { $_.Trim() -ceq $line }).Count -eq 0){
    if(@($have | Where-Object { @($_.Trim() -split '\s+')[0] -ceq $ReceiptSigner }).Count -gt 0){ throw "COVENANT_COURIER_RECEIPT_CHAIN_FAIL:RECEIPT_SIGNER_KEY_CHANGED" }
    $prefix = $(if($have.Count -gt 0 -and -not ([IO.File]::ReadAllText($allowed)).EndsWith("`n")){ "`n" } else { "" })
    [IO.File]::AppendAllText($allowed,($prefix + $line + "`n"),(CC-Utf8NoBom))
  }
}

# 2. Append entries for new receipts.
$appended = 0
if($VerifyOnly){ Write-Host ("COVENANT_COURIER_RECEIPT_CHAIN_UNCHAINED: " + [Math]::Max(0,$lines.Count - $chainLines.Count)) }
for($i = $chainLines.Count; (-not $VerifyOnly) -and $i -lt $lines.Count; $i++){
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

# 3. Sign the new head (also the first time for a chain that has none).
if(-not $VerifyOnly -and $lines.Count -gt 0 -and ($appended -gt 0 -or $null -eq $signedHead)){
  Ensure-ReceiptSigner
  $head = [ordered]@{ schema = "covenant_courier.receipt_chain_head.v1"; chain = (Split-Path -Leaf $ChainPath); entries = [int64]$lines.Count; chain_hash = $prev; signed_utc = (CC-UtcNow); signer = $ReceiptSigner }
  $tmpHead = $HeadPath + ".tmp"
  CC-WriteTextFile $tmpHead (CC-ToCanonicalJson $head)
  $eapPrev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
  $sg = & (CC-HostExe) -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "courier_sign_message_v1.ps1") -RepoRoot $RepoRoot -MessagePath $tmpHead -SignerIdentity $ReceiptSigner -Namespace $ReceiptNamespace 2>&1
  $sc = $LASTEXITCODE; $ErrorActionPreference = $eapPrev
  if($sc -ne 0){ Write-Host ($sg | Out-String).Trim(); throw "COVENANT_COURIER_RECEIPT_CHAIN_FAIL:HEAD_SIGN_FAILED" }
  Move-Item -LiteralPath ($tmpHead + ".sig") -Destination ($HeadPath + ".sig") -Force
  Move-Item -LiteralPath $tmpHead -Destination $HeadPath -Force
  Write-Host ("COVENANT_COURIER_RECEIPT_CHAIN_HEAD_SIGNED: " + $lines.Count)
}

} finally { $lock.Dispose() }

Write-Host ("COVENANT_COURIER_RECEIPT_CHAIN_ENTRIES: " + $lines.Count)
Write-Host ("COVENANT_COURIER_RECEIPT_CHAIN_APPENDED: " + $appended)
Write-Host ("COVENANT_COURIER_RECEIPT_CHAIN_HEAD: " + $prev)
Write-Host ("COVENANT_COURIER_RECEIPT_CHAIN_PATH: " + $ChainPath)
Write-Host "COVENANT_COURIER_RECEIPT_CHAIN_OK"
