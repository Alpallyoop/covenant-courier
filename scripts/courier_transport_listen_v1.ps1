param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\_lib_courier_v1.ps1"
. "$PSScriptRoot\_lib_courier_receipts_v1.ps1"

function Fail([string]$Code){
  throw $Code
}

function Ensure-Dir([string]$Path){
  if(-not (Test-Path -LiteralPath $Path)){
    [void][System.IO.Directory]::CreateDirectory($Path)
  }
}

function Test-FrameIdSeen {
  param(
    [Parameter(Mandatory=$true)][string]$RootPath,
    [Parameter(Mandatory=$true)][string]$FrameId
  )

  if(-not (Test-Path -LiteralPath $RootPath)){ return $false }

  $dirs = @(Get-ChildItem -LiteralPath $RootPath -Directory -ErrorAction SilentlyContinue)
  foreach($d in $dirs){
    $fj = Join-Path $d.FullName "frame.json"
    if(-not (Test-Path -LiteralPath $fj)){ continue }
    try {
      $obj = Read-Json $fj
      if((@($obj.PSObject.Properties.Name) -contains "frame_id") -and ([string]$obj.frame_id -eq $FrameId)){
        return $true
      }
    } catch {
      continue
    }
  }
  return $false
}

function Read-RegistryJson([string]$Path,[string]$FailCode){
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ throw $FailCode }
  return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Resolve-FrameChildPath([string]$FrameRoot,[string]$RelativePath,[string]$FailCode){
  if([string]::IsNullOrWhiteSpace($RelativePath)){ throw $FailCode }
  if([System.IO.Path]::IsPathRooted($RelativePath)){ throw $FailCode }
  $sep = [System.IO.Path]::DirectorySeparatorChar
  $root = [System.IO.Path]::GetFullPath($FrameRoot).TrimEnd('\','/') + $sep
  $normalized = ($RelativePath -replace '[\\/]', [string]$sep)
  $candidate = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine([System.IO.Path]::GetFullPath($FrameRoot), $normalized))
  $cmp = $(if($env:OS -eq "Windows_NT"){ [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal })
  if(-not $candidate.StartsWith($root,$cmp)){
    throw $FailCode
  }
  return $candidate
}

$PSExe     = ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$VerifySig = Join-Path $PSScriptRoot "courier_verify_signature_v1.ps1"

$config = Read-Json $ConfigPath
if(-not $config){ Fail "COURIER_TRANSPORT_FAIL:INVALID_CONFIG" }

$dropRoot     = Join-Path $RepoRoot ([string]$config.drop_root)
$acceptedRoot = Join-Path $RepoRoot ([string]$config.accepted_root)
$rejectedRoot = Join-Path $RepoRoot ([string]$config.rejected_root)

$nodeRoot    = Join-Path $RepoRoot "registry\nodes"
$networkRoot = Join-Path $RepoRoot "registry\networks"
$sessionRoot = Join-Path $RepoRoot "registry\sessions"

Ensure-Dir $dropRoot
Ensure-Dir $acceptedRoot
Ensure-Dir $rejectedRoot

$frames = @(Get-ChildItem -LiteralPath $dropRoot -Directory | Sort-Object Name)

foreach($frameDir in $frames){
  $frameJson = Join-Path $frameDir.FullName "frame.json"

  try {
    if(-not (Test-Path -LiteralPath $frameJson)){ throw "COURIER_TRANSPORT_FAIL:MISSING_FRAME_JSON" }

    $frame = Read-Json $frameJson
    $topProps = @($frame.PSObject.Properties.Name)

    foreach($req in @(
      "frame_id","created_utc","sender_identity","recipient_identity",
      "sender_node_id","recipient_node_id","network_id","session_id","sender_role",
      "message_rel","signature_rel","payload_sha256"
    )){
      if(-not ($topProps -contains $req)){
        throw ("COURIER_TRANSPORT_FAIL:MISSING_FIELD:" + $req)
      }
    }

    $frameId = [string]$frame.frame_id
    if([string]::IsNullOrWhiteSpace($frameId)){ throw "COURIER_TRANSPORT_FAIL:MISSING_FIELD:frame_id" }

    if((Test-FrameIdSeen -RootPath $acceptedRoot -FrameId $frameId) -or
       (Test-FrameIdSeen -RootPath $rejectedRoot -FrameId $frameId)){
      throw "COURIER_TRANSPORT_FAIL:REPLAY_DETECTED"
    }

    # Every ID in the (unsigned) frame header is used to build a registry path: constrain it first.
    foreach($idField in @("frame_id","sender_node_id","recipient_node_id","network_id","session_id")){
      if([string]$frame.$idField -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z' -or ([string]$frame.$idField).Contains("..")){
        throw ("COURIER_TRANSPORT_FAIL:BAD_ID:" + $idField)
      }
    }
    if($frameDir.Name -cne $frameId){ throw "COURIER_TRANSPORT_FAIL:FRAME_DIR_ID_MISMATCH" }

    $senderNodeId = [string]$frame.sender_node_id
    $recipientNodeId = [string]$frame.recipient_node_id
    $networkId = [string]$frame.network_id
    $sessionId = [string]$frame.session_id
    $senderRole = [string]$frame.sender_role

    $senderNode = Read-RegistryJson (Join-Path $nodeRoot ($senderNodeId + ".json")) "COURIER_TRANSPORT_FAIL:UNKNOWN_SENDER_NODE"
    $recipientNode = Read-RegistryJson (Join-Path $nodeRoot ($recipientNodeId + ".json")) "COURIER_TRANSPORT_FAIL:UNKNOWN_RECIPIENT_NODE"
    $network = Read-RegistryJson (Join-Path $networkRoot ($networkId + ".json")) "COURIER_TRANSPORT_FAIL:UNKNOWN_NETWORK"
    $session = Read-RegistryJson (Join-Path $sessionRoot ($sessionId + ".json")) "COURIER_TRANSPORT_FAIL:UNKNOWN_SESSION"

    if([string]$session.status -ne "open"){ throw "COURIER_TRANSPORT_FAIL:SESSION_NOT_OPEN" }
    if([string]$session.sender_node_id -ne $senderNodeId){ throw "COURIER_TRANSPORT_FAIL:SENDER_NODE_MISMATCH" }
    if([string]$session.recipient_node_id -ne $recipientNodeId){ throw "COURIER_TRANSPORT_FAIL:RECIPIENT_NODE_MISMATCH" }
    if([string]$session.network_id -ne $networkId){ throw "COURIER_TRANSPORT_FAIL:NETWORK_MISMATCH" }
    if([string]$session.session_role -ne $senderRole){ throw "COURIER_TRANSPORT_FAIL:SENDER_ROLE_MISMATCH" }
    if([string]$senderNode.status -ne "active"){ throw "COURIER_TRANSPORT_FAIL:SENDER_NODE_INACTIVE" }
    if([string]$recipientNode.status -ne "active"){ throw "COURIER_TRANSPORT_FAIL:RECIPIENT_NODE_INACTIVE" }
    if([string]$network.status -ne "active"){ throw "COURIER_TRANSPORT_FAIL:NETWORK_INACTIVE" }

    $allowedNodes = @($network.allowed_nodes)
    if(($allowedNodes -notcontains $senderNodeId) -or ($allowedNodes -notcontains $recipientNodeId)){
      throw "COURIER_TRANSPORT_FAIL:NODE_NOT_ALLOWED_ON_NETWORK"
    }

    # The frame must be signed by the sender node's registered principal; nothing else is trusted.
    $expectedSender = [string]$senderNode.principal
    if([string]::IsNullOrWhiteSpace($expectedSender)){
      throw "COURIER_TRANSPORT_FAIL:SENDER_PRINCIPAL_MISSING"
    }
    if([string]$frame.sender_identity -cne $expectedSender){
      throw "COURIER_TRANSPORT_FAIL:UNEXPECTED_SENDER_IDENTITY"
    }

    $msgPath = Resolve-FrameChildPath $frameDir.FullName ([string]$frame.message_rel) "COURIER_TRANSPORT_FAIL:MESSAGE_PATH_ESCAPE"
    $sigPath = Resolve-FrameChildPath $frameDir.FullName ([string]$frame.signature_rel) "COURIER_TRANSPORT_FAIL:SIGNATURE_PATH_ESCAPE"

    if(-not (Test-Path -LiteralPath $msgPath)){ throw "COURIER_TRANSPORT_FAIL:MISSING_MESSAGE_ARTIFACT" }
    if(-not (Test-Path -LiteralPath $sigPath)){ throw "COURIER_TRANSPORT_FAIL:MISSING_SIGNATURE_ARTIFACT" }

    $actualHash = (Get-FileHash -LiteralPath $msgPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if($actualHash -ne [string]$frame.payload_sha256){
      throw "COURIER_TRANSPORT_FAIL:PAYLOAD_HASH_MISMATCH"
    }

    # Scratch output stays inside the repository (Constellation agent policy: no system temp folder).
    $verifyTmp = Join-Path $RepoRoot "runtime\tmp"
    Ensure-Dir $verifyTmp
    $verifyOut = Join-Path $verifyTmp ("courier_verify_out_" + $frameDir.Name + "_" + [guid]::NewGuid().ToString("N") + ".txt")
    $verifyErr = Join-Path $verifyTmp ("courier_verify_err_" + $frameDir.Name + "_" + [guid]::NewGuid().ToString("N") + ".txt")
    if(Test-Path -LiteralPath $verifyOut){ Remove-Item -LiteralPath $verifyOut -Force }
    if(Test-Path -LiteralPath $verifyErr){ Remove-Item -LiteralPath $verifyErr -Force }

    $p = Start-Process -FilePath $PSExe -ArgumentList @(
      "-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass",
      "-File",$VerifySig,
      "-RepoRoot",$RepoRoot,
      "-MessagePath",$msgPath,
      "-SignerIdentity",$expectedSender
    ) -NoNewWindow -RedirectStandardOutput $verifyOut -RedirectStandardError $verifyErr -Wait -PassThru

    if($p.ExitCode -ne 0){
      $errText = ""
      if(Test-Path -LiteralPath $verifyErr){
        $errText = (Get-Content -LiteralPath $verifyErr -Raw)
      }
      if([string]::IsNullOrWhiteSpace($errText)){
        throw "COURIER_TRANSPORT_FAIL:VERIFY_FAILED"
      }
      throw ("COURIER_TRANSPORT_FAIL:VERIFY_FAILED:" + $errText.Trim())
    }
    foreach($t in @($verifyOut,$verifyErr)){ if(Test-Path -LiteralPath $t){ Remove-Item -LiteralPath $t -Force } }

    $dest = Join-Path $acceptedRoot $frameDir.Name
    # Accepted evidence is never overwritten: an existing destination is a replay.
    if(Test-Path -LiteralPath $dest){ throw "COURIER_TRANSPORT_FAIL:REPLAY_DETECTED" }
    if(-not (Test-Path -LiteralPath $frameDir.FullName -PathType Container)){
      continue
    }
    try {
      Move-Item -LiteralPath $frameDir.FullName -Destination $dest -ErrorAction Stop
    } catch {
      if(-not (Test-Path -LiteralPath $frameDir.FullName -PathType Container)){
        continue
      }
      throw
    }

    $receiptPath = Append-CourierReceipt -RepoRoot $RepoRoot -Receipt ([ordered]@{
      schema = "courier.transport.receipt.v1"
      event_type = "courier.transport.accept.v1"
      timestamp_utc = (Get-Date).ToUniversalTime().ToString("o")
      details = [ordered]@{
        frame_id = $frameId
        sender_node_id = $senderNodeId
        recipient_node_id = $recipientNodeId
        network_id = $networkId
        session_id = $sessionId
        sender_role = $senderRole
        accepted_root = $dest
        payload_sha256 = $actualHash
      }
    })

    Write-Host ("COURIER_TRANSPORT_LISTEN_ACCEPT_OK: " + $dest)
    Write-Host ("COURIER_TRANSPORT_ACCEPT_RECEIPT_OK: " + $receiptPath)
  }
  catch {
    $dest = Join-Path $rejectedRoot $frameDir.Name
    if(Test-Path -LiteralPath $dest){ $dest = $dest + "-dup-" + [guid]::NewGuid().ToString("N").Substring(0,8) }
    if(-not (Test-Path -LiteralPath $frameDir.FullName -PathType Container)){
      continue
    }
    try {
      Move-Item -LiteralPath $frameDir.FullName -Destination $dest -ErrorAction Stop
    } catch {
      if(-not (Test-Path -LiteralPath $frameDir.FullName -PathType Container)){
        continue
      }
      throw
    }

    $reasonPath = Join-Path $dest "reject_reason.txt"
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($reasonPath, ([string]$_.Exception.Message + "`n"), $enc)

    $receiptPath = Append-CourierReceipt -RepoRoot $RepoRoot -Receipt ([ordered]@{
      schema = "courier.transport.receipt.v1"
      event_type = "courier.transport.reject.v1"
      timestamp_utc = (Get-Date).ToUniversalTime().ToString("o")
      details = [ordered]@{
        frame_root = $dest
        reason = [string]$_.Exception.Message
      }
    })

    Write-Host ("COURIER_TRANSPORT_LISTEN_REJECT_OK: " + $dest)
    Write-Host ("COURIER_TRANSPORT_REJECT_RECEIPT_OK: " + $receiptPath)
  }
}

exit 0
