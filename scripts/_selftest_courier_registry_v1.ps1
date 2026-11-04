param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PSExe    = ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$RegNode  = Join-Path $PSScriptRoot "courier_register_node_v1.ps1"
$RegNet   = Join-Path $PSScriptRoot "courier_register_network_v1.ps1"
$OpenSes  = Join-Path $PSScriptRoot "courier_open_session_v1.ps1"
$CloseSes = Join-Path $PSScriptRoot "courier_close_session_v1.ps1"

function Quote-Arg([string]$Value){
  if($null -eq $Value){ return '""' }
  $escaped = $Value.Replace('"','\"')
  return ('"' + $escaped + '"')
}

function Run-Step{
  param(
    [Parameter(Mandatory=$true)][string]$Script,
    [Parameter(Mandatory=$true)][string[]]$ChildArgs,
    [Parameter(Mandatory=$true)][string]$FailCode
  )

  $parts = New-Object System.Collections.Generic.List[string]
  [void]$parts.Add("-NoProfile")
  [void]$parts.Add("-NonInteractive")
  [void]$parts.Add("-ExecutionPolicy")
  [void]$parts.Add("Bypass")
  [void]$parts.Add("-File")
  [void]$parts.Add((Quote-Arg $Script))

  foreach($arg in $ChildArgs){
    [void]$parts.Add((Quote-Arg $arg))
  }

  $argString = [string]::Join(" ", $parts.ToArray())

  $p = Start-Process -FilePath $PSExe `
    -ArgumentList $argString `
    -NoNewWindow `
    -Wait `
    -PassThru

  if($p.ExitCode -ne 0){
    throw ($FailCode + "_" + $p.ExitCode)
  }
}

$RegistryRoot = Join-Path $RepoRoot "registry"
if(Test-Path -LiteralPath $RegistryRoot){
  Remove-Item -LiteralPath $RegistryRoot -Recurse -Force
}

Run-Step -Script $RegNode -ChildArgs @(
  "-RepoRoot",$RepoRoot,
  "-NodeId","node-alpha",
  "-NodeName","Node Alpha",
  "-NodeRole","sender",
  "-Principal","courier-local@covenant"
) -FailCode "COURIER_REGISTRY_FAIL:REGISTER_NODE_ALPHA"

Run-Step -Script $RegNode -ChildArgs @(
  "-RepoRoot",$RepoRoot,
  "-NodeId","node-beta",
  "-NodeName","Node Beta",
  "-NodeRole","receiver",
  "-Principal","courier-local@covenant"
) -FailCode "COURIER_REGISTRY_FAIL:REGISTER_NODE_BETA"

Run-Step -Script $RegNet -ChildArgs @(
  "-RepoRoot",$RepoRoot,
  "-NetworkId","courier-internal-net-v1",
  "-NetworkName","Courier Internal Net",
  "-TransportKind","filesystem-drop",
  "-ListenerPort","47151",
  "-BindingMode","dedicated",
  "-Visibility","private",
  "-Status","active",
  "-AllowedNodesCsv","node-alpha,node-beta"
) -FailCode "COURIER_REGISTRY_FAIL:REGISTER_NETWORK"

# A session of its own (closing the demo session would leave it closed: sessions are never reopened).
$SelftestSession = "session-registry-selftest-" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ")
Run-Step -Script $OpenSes -ChildArgs @(
  "-RepoRoot",$RepoRoot,
  "-SessionId",$SelftestSession,
  "-SenderNodeId","node-alpha",
  "-RecipientNodeId","node-beta",
  "-NetworkId","courier-internal-net-v1",
  "-SessionRole","message-delivery"
) -FailCode "COURIER_REGISTRY_FAIL:OPEN_SESSION"

Run-Step -Script $CloseSes -ChildArgs @(
  "-RepoRoot",$RepoRoot,
  "-SessionId",$SelftestSession
) -FailCode "COURIER_REGISTRY_FAIL:CLOSE_SESSION"

# A closed session stays closed.
$reopenOk = $true
try { & $OpenSes -RepoRoot $RepoRoot -SessionId $SelftestSession -SenderNodeId "node-alpha" -RecipientNodeId "node-beta" -NetworkId "courier-internal-net-v1" -SessionRole "message-delivery" | Out-Null } catch { $reopenOk = $false; if($_.ToString() -notmatch "COURIER_SESSION_FAIL:SESSION_CLOSED"){ throw ("COURIER_REGISTRY_FAIL:REOPEN_WRONG_ERROR:" + $_.ToString()) } }
if($reopenOk){ throw "COURIER_REGISTRY_FAIL:CLOSED_SESSION_REOPENED" }
Remove-Item -LiteralPath (Join-Path $RepoRoot ("registry\sessions\" + $SelftestSession + ".json")) -Force
Write-Host "COURIER_REGISTRY_CASE_OK: closed session -> reopen refused"

Write-Host "COURIER_REGISTRY_SELFTEST_OK"
exit 0
