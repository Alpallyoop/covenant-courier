param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$OutRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RegSelf   = Join-Path $PSScriptRoot "_selftest_courier_registry_v1.ps1"
$OpenSes   = Join-Path $PSScriptRoot "courier_open_session_v1.ps1"
$Bootstrap = Join-Path $PSScriptRoot "courier_bootstrap_local_trust_v1.ps1"
$Pipeline  = Join-Path $PSScriptRoot "courier_cli_run_pipeline_v1.ps1"
$Send      = Join-Path $PSScriptRoot "courier_transport_send_v1.ps1"

function Fail([string]$Code){ throw $Code }

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

function Reset-Dir([string]$Path){
  if(Test-Path -LiteralPath $Path){
    Remove-Item -LiteralPath $Path -Recurse -Force
  }
  [void][System.IO.Directory]::CreateDirectory($Path)
}

function Get-Sha256Hex([string]$Path){
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $fs = [System.IO.File]::OpenRead($Path)
  try { $hash = $sha.ComputeHash($fs) }
  finally { $fs.Dispose(); $sha.Dispose() }
  return (($hash | ForEach-Object { $_.ToString("x2") }) -join "")
}

function Get-RelPath([string]$Root,[string]$Path){
  return $Path.Substring($Root.Length).TrimStart('\','/').Replace('\','/')
}

function Run-Step([scriptblock]$Block,[string]$FailCode){
  try {
    & $Block
  }
  catch {
    Fail ($FailCode + ":" + $_.ToString())
  }
}

Reset-Dir $OutRoot
$FrameOut = Join-Path $OutRoot "frame_outbox"
Ensure-Dir $FrameOut

Run-Step { & $RegSelf -RepoRoot $RepoRoot } "VTP_M2M_EXPORT_FAIL:REGISTRY"
Run-Step {
  & $OpenSes `
    -RepoRoot $RepoRoot `
    -SessionId "session-alpha-beta-m2m-001" `
    -SenderNodeId "node-alpha" `
    -RecipientNodeId "node-beta" `
    -NetworkId "courier-internal-net-v1" `
    -SessionRole "message-delivery"
} "VTP_M2M_EXPORT_FAIL:OPEN_SESSION"
Run-Step { & $Bootstrap -RepoRoot $RepoRoot } "VTP_M2M_EXPORT_FAIL:BOOTSTRAP"
Run-Step {
  & $Pipeline `
    -RepoRoot $RepoRoot `
    -InputDir (Join-Path $RepoRoot "test_vectors\courier_v1\transport_hardening\prep")
} "VTP_M2M_EXPORT_FAIL:PIPELINE"

$MessagePath = Join-Path $RepoRoot "test_vectors\courier_v1\transport_hardening\prep\message.tokenized.json"

Run-Step {
  & $Send `
    -RepoRoot $RepoRoot `
    -MessagePath $MessagePath `
    -SenderIdentity "courier-local@covenant" `
    -RecipientIdentity "courier-local@covenant" `
    -SenderNodeId "node-alpha" `
    -RecipientNodeId "node-beta" `
    -NetworkId "courier-internal-net-v1" `
    -SessionId "session-alpha-beta-m2m-001" `
    -SenderRole "message-delivery" `
    -DropRoot $FrameOut
} "VTP_M2M_EXPORT_FAIL:SEND"

$frames = @(Get-ChildItem -LiteralPath $FrameOut -Directory | Sort-Object Name)
if($frames.Count -ne 1){ Fail ("VTP_M2M_EXPORT_FAIL:EXPECTED_ONE_FRAME:COUNT_" + $frames.Count) }

$manifest = [ordered]@{
  schema = "vtp.machine_to_machine.export.v1"
  created_utc = (Get-Date).ToUniversalTime().ToString("o")
  protocol = "VTP"
  protocol_version = "v1"
  sender_node_id = "node-alpha"
  recipient_node_id = "node-beta"
  session_id = "session-alpha-beta-m2m-001"
  frame_dir = ("frame_outbox/" + $frames[0].Name)
}

Write-Utf8NoBomLf (Join-Path $OutRoot "m2m_manifest.json") (($manifest | ConvertTo-Json -Depth 20 -Compress))

$ShaPath = Join-Path $OutRoot "sha256sums.txt"
$files = @(Get-ChildItem -LiteralPath $OutRoot -Recurse -File | Where-Object {
  $_.FullName -ne $ShaPath
} | Sort-Object FullName)

$lines = New-Object System.Collections.Generic.List[string]
foreach($f in $files){
  [void]$lines.Add((Get-Sha256Hex $f.FullName) + "  " + (Get-RelPath $OutRoot $f.FullName))
}
Write-Utf8NoBomLf $ShaPath (($lines.ToArray()) -join "`n")

Write-Host ("M2M_EXPORT_ROOT: " + $OutRoot)
Write-Host ("M2M_FRAME_DIR: " + $frames[0].FullName)
Write-Host ("SHA256SUMS_OK: " + $ShaPath)
Write-Host "VTP_M2M_EXPORT_OK"
