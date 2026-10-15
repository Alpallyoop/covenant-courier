# constellation.integration.receipt.v1 emitter and verifier (Constellation proposal 0013).
#
# Covenant Courier writes one receipt per exchange with another ecosystem service, locally first,
# including failed and refused exchanges. Layout (one folder per integration, so each folder can be
# registered as an NFL inbox in mode "receipt"):
#
#   proofs/integration_receipts/<consumer>__<provider>/receipts.ndjson
#
# Line format is fixed by the schema: keys in schema order, compact, UTF-8, LF. No timestamps.
# receipt hash = SHA-256 of the line bytes without the LF. prev_sha256 chains receipts per
# emitter and integration (64 zeros first). Witnessing by NFL is best effort and never blocks.

Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "_lib_covenant_courier_product_v1.ps1")

$script:CIR_Zero = ("0" * 64)
$script:CIR_Outcomes = @("ok","refused","unavailable","unknown","deferred","failed")

function CIR-Dir([string]$RepoRoot,[string]$Consumer,[string]$Provider){
  return (Join-Path $RepoRoot ("proofs\integration_receipts\" + $Consumer + "__" + $Provider))
}
function CIR-Path([string]$RepoRoot,[string]$Consumer,[string]$Provider){
  return (Join-Path (CIR-Dir $RepoRoot $Consumer $Provider) "receipts.ndjson")
}

function CIR-AssertServiceId([string]$Id,[string]$Field){
  if($Id -cnotmatch '^[a-z0-9][a-z0-9-]*\z'){ CC-Fail ("CIR_INVALID:" + $Field) }
}
function CIR-AssertContract($Contract,[string]$Field){
  if($null -eq $Contract){ return }
  if([string]$Contract -cnotmatch '^[a-z0-9][a-z0-9_.-]*\.v[0-9]+\z'){ CC-Fail ("CIR_INVALID:" + $Field) }
}
function CIR-AssertSha($Value,[string]$Field,[switch]$AllowNull){
  if($null -eq $Value){ if($AllowNull){ return } ; CC-Fail ("CIR_INVALID:" + $Field) }
  if([string]$Value -cnotmatch '^[0-9a-f]{64}\z'){ CC-Fail ("CIR_INVALID:" + $Field) }
}

function CIR-BuildLine {
  param(
    [Parameter(Mandatory=$true)][string]$Consumer,
    [Parameter(Mandatory=$true)][string]$Provider,
    [Parameter(Mandatory=$true)][string]$EmittedBy,
    $Contract,
    $RequestSha256,
    $ResponseSha256,
    [object[]]$Carried = @(),
    [Parameter(Mandatory=$true)][string]$Outcome,
    $ErrorToken,
    [Parameter(Mandatory=$true)][string]$PrevSha256
  )
  CIR-AssertServiceId $Consumer "consumer"
  CIR-AssertServiceId $Provider "provider"
  if(@("consumer","provider") -cnotcontains $EmittedBy){ CC-Fail "CIR_INVALID:emitted_by" }
  CIR-AssertContract $Contract "contract"
  CIR-AssertSha $RequestSha256 "request_sha256" -AllowNull
  CIR-AssertSha $ResponseSha256 "response_sha256" -AllowNull
  if($script:CIR_Outcomes -cnotcontains $Outcome){ CC-Fail "CIR_INVALID:outcome" }
  if($Outcome -eq "ok"){
    if($null -ne $ErrorToken){ CC-Fail "CIR_INVALID:error_token_must_be_null_when_ok" }
  } else {
    if([string]::IsNullOrEmpty([string]$ErrorToken) -or ([string]$ErrorToken -cnotmatch '^[A-Z][A-Z0-9_]*\z')){ CC-Fail "CIR_INVALID:error_token" }
  }
  CIR-AssertSha $PrevSha256 "prev_sha256"
  $carriedList = New-Object System.Collections.Generic.List[object]
  foreach($c in @($Carried)){
    if($null -eq $c){ continue }
    $cc = [string]$c.contract; $cs = [string]$c.sha256
    CIR-AssertContract $cc "carried.contract"; CIR-AssertSha $cs "carried.sha256"
    $carriedList.Add([ordered]@{ contract = $cc; sha256 = $cs })
  }
  $obj = [ordered]@{
    schema = "constellation.integration.receipt.v1"
    consumer = $Consumer
    provider = $Provider
    emitted_by = $EmittedBy
    contract = $(if($null -eq $Contract){ $null } else { [string]$Contract })
    request_sha256 = $(if($null -eq $RequestSha256){ $null } else { [string]$RequestSha256 })
    response_sha256 = $(if($null -eq $ResponseSha256){ $null } else { [string]$ResponseSha256 })
    carried = $carriedList.ToArray()
    outcome = $Outcome
    error_token = $(if($null -eq $ErrorToken){ $null } else { [string]$ErrorToken })
    prev_sha256 = $PrevSha256
  }
  return (CC-ToJson $obj)
}

function CIR-LastHash([string]$Path){
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ return $script:CIR_Zero }
  $raw = [System.IO.File]::ReadAllText($Path,(CC-Utf8NoBom))
  if($raw.Length -gt 0 -and -not $raw.EndsWith("`n")){ CC-Fail "CIR_FAIL:TORN_LAST_LINE" }
  $lines = @($raw -split "`n" | Where-Object { $_ -ne "" })
  if($lines.Count -eq 0){ return $script:CIR_Zero }
  return (CC-Sha256Text $lines[$lines.Count-1])
}

# Emits a receipt for one exchange. Emitting never throws for the caller's business outcome; it
# throws only if the receipt itself would be invalid (a programming error, fails closed).
function Write-ConstellationIntegrationReceipt {
  param(
    [Parameter(Mandatory=$true)][string]$RepoRoot,
    [Parameter(Mandatory=$true)][string]$Consumer,
    [Parameter(Mandatory=$true)][string]$Provider,
    [string]$EmittedBy = "consumer",
    $Contract,
    $RequestSha256 = $null,
    $ResponseSha256 = $null,
    [object[]]$Carried = @(),
    [Parameter(Mandatory=$true)][string]$Outcome,
    $ErrorToken = $null
  )
  CIR-AssertServiceId $Consumer "consumer"
  CIR-AssertServiceId $Provider "provider"
  $path = CIR-Path $RepoRoot $Consumer $Provider
  CC-EnsureDir (Split-Path -Parent $path)
  $lockPath = $path + ".lock"
  $lock = $null
  $until = [DateTime]::UtcNow.AddSeconds(30)
  while($null -eq $lock){
    try { $lock = [System.IO.File]::Open($lockPath,[System.IO.FileMode]::OpenOrCreate,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None) }
    catch [System.IO.IOException] { if([DateTime]::UtcNow -gt $until){ CC-Fail "CIR_FAIL:LOCK_TIMEOUT" }; Start-Sleep -Milliseconds 25 }
  }
  try {
    $prev = CIR-LastHash $path
    $line = CIR-BuildLine -Consumer $Consumer -Provider $Provider -EmittedBy $EmittedBy -Contract $Contract -RequestSha256 $RequestSha256 -ResponseSha256 $ResponseSha256 -Carried $Carried -Outcome $Outcome -ErrorToken $ErrorToken -PrevSha256 $prev
    CC-AppendLine $path $line
    return [pscustomobject]@{ Path = $path; Sha256 = (CC-Sha256Text $line); Line = $line; Label = ("constellation.integration.receipt.v1:" + $Consumer + ">" + $Provider) }
  } finally { $lock.Dispose() }
}

# Recomputes every line: exact canonical form, schema rules and the prev_sha256 chain.
function Test-ConstellationIntegrationReceiptFile {
  param([Parameter(Mandatory=$true)][string]$Path)
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ CC-Fail "CIR_VERIFY_FAIL:MISSING_FILE" }
  $raw = [System.IO.File]::ReadAllText($Path,(CC-Utf8NoBom))
  if($raw.Length -gt 0 -and -not $raw.EndsWith("`n")){ CC-Fail "CIR_VERIFY_FAIL:TRUNCATED_LAST_LINE" }
  if($raw.Contains("`r")){ CC-Fail "CIR_VERIFY_FAIL:CR_NOT_ALLOWED" }
  $lines = @($raw -split "`n" | Select-Object -SkipLast 1)
  $prev = $script:CIR_Zero
  $i = 0
  foreach($ln in $lines){
    if($ln -eq ""){ CC-Fail ("CIR_VERIFY_FAIL:EMPTY_LINE:" + $i) }
    try { $o = $ln | ConvertFrom-Json -ErrorAction Stop } catch { CC-Fail ("CIR_VERIFY_FAIL:INVALID_JSON:" + $i) }
    $names = @($o.PSObject.Properties | ForEach-Object { $_.Name })
    $expected = @("schema","consumer","provider","emitted_by","contract","request_sha256","response_sha256","carried","outcome","error_token","prev_sha256")
    if(($names -join ",") -cne ($expected -join ",")){ CC-Fail ("CIR_VERIFY_FAIL:KEY_ORDER:" + $i) }
    if([string]$o.schema -cne "constellation.integration.receipt.v1"){ CC-Fail ("CIR_VERIFY_FAIL:SCHEMA:" + $i) }
    if([string]$o.prev_sha256 -cne $prev){ CC-Fail ("CIR_VERIFY_FAIL:CHAIN_BROKEN:" + $i) }
    try {
      $rebuilt = CIR-BuildLine -Consumer ([string]$o.consumer) -Provider ([string]$o.provider) -EmittedBy ([string]$o.emitted_by) -Contract $o.contract -RequestSha256 $o.request_sha256 -ResponseSha256 $o.response_sha256 -Carried @($o.carried) -Outcome ([string]$o.outcome) -ErrorToken $o.error_token -PrevSha256 ([string]$o.prev_sha256)
    } catch { CC-Fail ("CIR_VERIFY_FAIL:" + $_.Exception.Message + ":" + $i) }
    if($rebuilt -cne $ln){ CC-Fail ("CIR_VERIFY_FAIL:NOT_CANONICAL:" + $i) }
    $prev = CC-Sha256Text $ln
    $i++
  }
  return [pscustomobject]@{ Path = $Path; Count = $i; Head = $prev }
}
