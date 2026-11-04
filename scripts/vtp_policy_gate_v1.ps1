param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$FrameDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path $RepoRoot).Path
$FrameJson = Join-Path $FrameDir "frame.json"
$PolicyPath = Join-Path $RepoRoot "policy\vtp_dlp_policy_v1.json"

if(-not (Test-Path -LiteralPath $FrameJson -PathType Leaf)){
  Write-Host "VTP_POLICY_DENY:MISSING_FRAME_JSON"
  exit 42
}

if(-not (Test-Path -LiteralPath $PolicyPath -PathType Leaf)){
  Write-Host "VTP_POLICY_DENY:MISSING_POLICY"
  exit 42
}

if((Get-Item -LiteralPath $FrameJson).Length -gt 65536){ Write-Host "VTP_POLICY_DENY:FRAME_TOO_LARGE"; exit 42 }
try { $frame = Get-Content -LiteralPath $FrameJson -Raw | ConvertFrom-Json -ErrorAction Stop } catch { Write-Host "VTP_POLICY_DENY:FRAME_INVALID_JSON"; exit 42 }
try { $policy = Get-Content -LiteralPath $PolicyPath -Raw | ConvertFrom-Json -ErrorAction Stop } catch { Write-Host "VTP_POLICY_DENY:POLICY_INVALID_JSON"; exit 42 }
if($null -eq $frame -or $null -eq $policy){ Write-Host "VTP_POLICY_DENY:EMPTY_FRAME_OR_POLICY"; exit 42 }

function Has-Value($obj,[string]$name){
  return ($null -ne $obj.PSObject.Properties[$name])
}

if((Has-Value $policy "require_payload_sha256") -and $policy.require_payload_sha256){
  if((-not (Has-Value $frame "payload_sha256")) -or [string]::IsNullOrWhiteSpace([string]$frame.payload_sha256)){
    Write-Host "VTP_POLICY_DENY:MISSING_PAYLOAD_SHA256"
    exit 42
  }
}

# An empty or missing allow-list allows nothing (fail closed), it does not allow everything.
$allowedNetworks = @($(if(Has-Value $policy "allowed_networks"){ $policy.allowed_networks }) | Where-Object { $null -ne $_ })
if($allowedNetworks -cnotcontains [string]$frame.network_id){
  Write-Host ("VTP_POLICY_DENY:NETWORK_NOT_ALLOWED:" + [string]$frame.network_id)
  exit 42
}

$allowedRecipients = @($(if(Has-Value $policy "allowed_recipient_nodes"){ $policy.allowed_recipient_nodes }) | Where-Object { $null -ne $_ })
if($allowedRecipients -cnotcontains [string]$frame.recipient_node_id){
  Write-Host ("VTP_POLICY_DENY:RECIPIENT_NOT_ALLOWED:" + [string]$frame.recipient_node_id)
  exit 42
}

$deniedRoles = @($policy.denied_sender_roles)
if($deniedRoles.Count -gt 0 -and ($deniedRoles -contains [string]$frame.sender_role)){
  Write-Host ("VTP_POLICY_DENY:SENDER_ROLE_DENIED:" + [string]$frame.sender_role)
  exit 42
}

Write-Host "VTP_POLICY_ALLOW"
exit 0