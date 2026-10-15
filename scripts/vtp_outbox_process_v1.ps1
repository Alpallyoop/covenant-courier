param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$QueueRoot,
  [Parameter(Mandatory=$true)][string]$DestinationDropRoot,
  [int]$MaxAttempts = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Dir([string]$Path){
  if(-not (Test-Path -LiteralPath $Path)){
    [void][System.IO.Directory]::CreateDirectory($Path)
  }
}

function Write-Utf8NoBomLf([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path
  if($dir){ Ensure-Dir $dir }
  $t = ($Text -replace "`r`n","`n") -replace "`r","`n"
  if(-not $t.EndsWith("`n")){ $t += "`n" }
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path,$t,$enc)
}

function Append-Receipt([string]$Event,[hashtable]$Details){
  $receiptRoot = Join-Path $RepoRoot "proofs\receipts"
  Ensure-Dir $receiptRoot
  $receipt = [ordered]@{
    schema = "vtp.outbox.receipt.v1"
    event_type = $Event
    timestamp_utc = (Get-Date).ToUniversalTime().ToString("o")
    details = $Details
  }
  Add-Content -LiteralPath (Join-Path $receiptRoot "vtp_outbox.ndjson") -Value ($receipt | ConvertTo-Json -Depth 20 -Compress)
}

# PowerShell 7 ConvertFrom-Json turns ISO-8601 strings into DateTime objects, and
# [string] on those drops the offset; Windows PowerShell 5.1 keeps strings. Accept both
# without any local-time reinterpretation.
function ConvertTo-UtcDateTime($Value){
  if($Value -is [datetime]){
    if($Value.Kind -eq [System.DateTimeKind]::Unspecified){ return [datetime]::SpecifyKind($Value,[System.DateTimeKind]::Utc) }
    return $Value.ToUniversalTime()
  }
  $parsed = [datetimeoffset]::MinValue
  if(-not [datetimeoffset]::TryParse([string]$Value,[System.Globalization.CultureInfo]::InvariantCulture,[System.Globalization.DateTimeStyles]::AssumeUniversal,[ref]$parsed)){
    throw "VTP_OUTBOX_FAIL:BAD_NEXT_ATTEMPT_UTC"
  }
  return $parsed.UtcDateTime
}

Ensure-Dir $QueueRoot
Ensure-Dir $DestinationDropRoot

$now = (Get-Date).ToUniversalTime()
$items = @(Get-ChildItem -LiteralPath $QueueRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name)

foreach($item in $items){
  $metaPath = Join-Path $item.FullName "queue_item.json"
  if(-not (Test-Path -LiteralPath $metaPath -PathType Leaf)){
    Append-Receipt "vtp.outbox.skip_bad_item.v1" @{ item = $item.FullName; reason = "missing_queue_item" }
    continue
  }

  $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json

  if([string]$meta.status -eq "delivered"){
    continue
  }

  if([int]$meta.attempts -ge $MaxAttempts){
    $meta.status = "failed"
    $meta.last_error = "max_attempts_reached"
    Write-Utf8NoBomLf $metaPath (($meta | ConvertTo-Json -Depth 20 -Compress))
    Append-Receipt "vtp.outbox.failed.v1" @{ queue_id = [string]$meta.queue_id; reason = "max_attempts_reached" }
    continue
  }

  $next = ConvertTo-UtcDateTime $meta.next_attempt_utc
  if($next -gt $now){
    continue
  }

  $frameSource = Join-Path $item.FullName ([string]$meta.frame_root)
  if(-not (Test-Path -LiteralPath $frameSource -PathType Container)){
    $meta.status = "failed"
    $meta.last_error = "missing_frame"
    Write-Utf8NoBomLf $metaPath (($meta | ConvertTo-Json -Depth 20 -Compress))
    Append-Receipt "vtp.outbox.failed.v1" @{ queue_id = [string]$meta.queue_id; reason = "missing_frame" }
    continue
  }

  $frameName = [System.IO.Path]::GetFileName($frameSource)
  if($frameName -eq "frame"){
    $inner = @(Get-ChildItem -LiteralPath $frameSource -Directory -ErrorAction SilentlyContinue | Sort-Object Name)
    if($inner.Count -eq 1){
      $frameSource = $inner[0].FullName
      $frameName = $inner[0].Name
    }
  }

  $dest = Join-Path $DestinationDropRoot $frameName

  try {
    if(Test-Path -LiteralPath $dest){
      Remove-Item -LiteralPath $dest -Recurse -Force
    }

    Copy-Item -LiteralPath $frameSource -Destination $dest -Recurse -Force

    $meta.status = "delivered"
    $meta.attempts = [int]$meta.attempts + 1
    $meta.last_attempt_utc = (Get-Date).ToUniversalTime().ToString("o")
    $meta.last_error = $null
    Write-Utf8NoBomLf $metaPath (($meta | ConvertTo-Json -Depth 20 -Compress))

    Append-Receipt "vtp.outbox.delivered.v1" @{
      queue_id = [string]$meta.queue_id
      destination_drop_root = $DestinationDropRoot
      destination_frame = $dest
    }

    Write-Host ("VTP_OUTBOX_DELIVERED: " + $dest)
  }
  catch {
    $meta.status = "queued"
    $meta.attempts = [int]$meta.attempts + 1
    $meta.last_attempt_utc = (Get-Date).ToUniversalTime().ToString("o")
    $delaySeconds = [math]::Min(300, [math]::Pow(2,[int]$meta.attempts))
    $meta.next_attempt_utc = (Get-Date).ToUniversalTime().AddSeconds($delaySeconds).ToString("o")
    $meta.last_error = $_.ToString()
    Write-Utf8NoBomLf $metaPath (($meta | ConvertTo-Json -Depth 20 -Compress))

    Append-Receipt "vtp.outbox.retry_scheduled.v1" @{
      queue_id = [string]$meta.queue_id
      attempts = [int]$meta.attempts
      next_attempt_utc = [string]$meta.next_attempt_utc
      error = $_.ToString()
    }
  }
}

Write-Host "VTP_OUTBOX_PROCESS_OK"
