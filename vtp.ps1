param(
  [Parameter(Position=0)][string]$Command = "help",
  [string]$RepoRoot = ".",
  [string]$NodeId = "node-beta",
  [string]$To = "node-beta"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path $RepoRoot).Path
$Scripts = Join-Path $RepoRoot "scripts"

function Run-PS([string]$Script,[string[]]$ArgsList){
  & ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Script @ArgsList
  if($LASTEXITCODE -ne 0){
    throw ("VTP_CHILD_FAIL:" + $Script)
  }
}

if($Command -eq "help"){
  Write-Host "VTP commands:"
  Write-Host "  .\vtp.ps1 smoke"
  Write-Host "  .\vtp.ps1 status"
  Write-Host "  .\vtp.ps1 transmit -To node-beta"
  Write-Host "  .\vtp.ps1 send -To node-beta"
  Write-Host "  .\vtp.ps1 node-loop -NodeId node-beta"
  Write-Host "  .\vtp.ps1 dlp-test"
  Write-Host "  .\vtp.ps1 full-green"
  Write-Host "  .\vtp.ps1 run-node -NodeId node-beta"
  Write-Host "  .\vtp.ps1 install-node -NodeId node-beta"
  Write-Host "  .\vtp.ps1 dev-fast"
  Write-Host "  .\vtp.ps1 conformance"
  exit 0
}

if($Command -eq "smoke"){
  foreach($rel in @(
    "scripts\vtp_node_loop_v1.ps1",
    "scripts\vtp_node_loop_policy_v1.ps1",
    "scripts\vtp_node_loop_forever_v1.ps1",
    "scripts\vtp_policy_gate_v1.ps1",
    "scripts\_selftest_vtp_dlp_negative_v1.ps1",
    "scripts\vtp_install_node_task_v1.ps1",
    "scripts\_RUN_vtp_dev_fast_v1.ps1",
    "scripts\_RUN_vtp_conformance_v1.ps1"
  )){
    if(-not (Test-Path -LiteralPath (Join-Path $RepoRoot $rel) -PathType Leaf)){
      throw "VTP_SMOKE_FAIL:MISSING:$rel"
    }
  }

  $task = $null
  if(Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue){
    $task = Get-ScheduledTask -TaskName "VTP Node Loop" -ErrorAction SilentlyContinue
  }
  if($null -eq $task){
    Write-Host "VTP_SMOKE_WARN:NO_SCHEDULED_TASK"
  } else {
    Write-Host ("VTP_TASK_STATE: " + $task.State)
  }

  Write-Host "VTP_SMOKE_PASS"
  exit 0
}

if($Command -eq "status"){
  $drop = Join-Path $RepoRoot ("runtime\nodes\" + $NodeId + "\inbox\drop")
  $accepted = Join-Path $RepoRoot ("runtime\nodes\" + $NodeId + "\accepted")
  $rejected = Join-Path $RepoRoot ("runtime\nodes\" + $NodeId + "\rejected")
  $receipts = Join-Path $RepoRoot "proofs\receipts"

  $dropItems = @(Get-ChildItem -LiteralPath $drop -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
  $acceptedItems = @(Get-ChildItem -LiteralPath $accepted -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
  $rejectedItems = @(Get-ChildItem -LiteralPath $rejected -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)

  Write-Host "VTP STATUS"
  Write-Host ("Repo: " + $RepoRoot)
  Write-Host ("Node: " + $NodeId)
  Write-Host ("Inbox drop: " + $dropItems.Count)
  if($dropItems.Count -gt 0){ Write-Host ("Latest drop: " + $dropItems[0].Name) }
  Write-Host ("Accepted: " + $acceptedItems.Count)
  if($acceptedItems.Count -gt 0){ Write-Host ("Latest accepted: " + $acceptedItems[0].Name) }
  Write-Host ("Rejected: " + $rejectedItems.Count)
  if($rejectedItems.Count -gt 0){
    Write-Host ("Latest rejected: " + $rejectedItems[0].Name)
    $reason = Join-Path $rejectedItems[0].FullName "reject_reason.txt"
    if(Test-Path -LiteralPath $reason -PathType Leaf){
      $reasonText = (Get-Content -LiteralPath $reason -Raw).Trim()
      if(-not [string]::IsNullOrWhiteSpace($reasonText)){
        Write-Host ("Latest reject reason: " + $reasonText)
      }
    }
  }
  Write-Host ("Receipts: " + $receipts)

  $task = $null
  if(Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue){
    $task = Get-ScheduledTask -TaskName "VTP Node Loop" -ErrorAction SilentlyContinue
  }
  if($null -eq $task){
    Write-Host "Task: missing (scheduled tasks are Windows-only)"
  } else {
    $info = Get-ScheduledTaskInfo -TaskName "VTP Node Loop"
    Write-Host ("Task state: " + $task.State)
    Write-Host ("Last run: " + $info.LastRunTime)
    Write-Host ("Next run: " + $info.NextRunTime)
    Write-Host ("Last result: " + $info.LastTaskResult)
  }

  exit 0
}

if($Command -eq "install-node"){
  Run-PS (Join-Path $Scripts "vtp_install_node_task_v1.ps1") @("-RepoRoot",$RepoRoot,"-NodeId",$NodeId)
  exit 0
}

if($Command -eq "run-node"){
  Write-Host ("VTP_RUN_NODE_START: " + $NodeId)
  Write-Host "VTP_RUN_NODE_MODE: foreground-silent"
  Write-Host "VTP_RUN_NODE_STOP: Ctrl+C"

  & ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File (Join-Path $Scripts "vtp_node_loop_forever_v1.ps1") `
    -RepoRoot $RepoRoot `
    -NodeId $NodeId

  if($LASTEXITCODE -ne 0){
    throw "VTP_RUN_NODE_FAIL"
  }

  exit 0
}

if($Command -eq "node-loop"){
  Run-PS (Join-Path $Scripts "vtp_node_loop_policy_v1.ps1") @("-RepoRoot",$RepoRoot,"-NodeId",$NodeId,"-Once")
  exit 0
}

if($Command -eq "send"){
  $messagePath = Join-Path $RepoRoot "test_vectors\courier_v1\transport_hardening\prep\message.tokenized.json"

  if(-not (Test-Path -LiteralPath $messagePath -PathType Leaf)){
    $prepDir = Split-Path -Parent $messagePath
    [void][IO.Directory]::CreateDirectory($prepDir)

    $prepared = [ordered]@{
      schema = "courier.message.tokenized.v1"
      message_id = "vtp-demo-" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ")
      created_utc = (Get-Date).ToUniversalTime().ToString("o")
      sender_identity = "courier-local@covenant"
      recipient_identity = "courier-local@covenant"
      payload_text = "covenant courier local preview message"
      preview = "Covenant Courier local preview"
    }

    $json = $prepared | ConvertTo-Json -Depth 20 -Compress
    [IO.File]::WriteAllText($messagePath, ($json + [string][char]10), [Text.UTF8Encoding]::new($false))

    Write-Host ("VTP_SEND_PREPARED_MESSAGE_BOOTSTRAP_OK: " + $messagePath)
  }

  $nodeRoot = Join-Path $RepoRoot "registry\nodes"
  $netRoot = Join-Path $RepoRoot "registry\networks"
  [void][IO.Directory]::CreateDirectory($nodeRoot)
  [void][IO.Directory]::CreateDirectory($netRoot)

  $alphaPath = Join-Path $nodeRoot "node-alpha.json"
  $betaPath = Join-Path $nodeRoot "node-beta.json"
  $netPath = Join-Path $netRoot "courier-internal-net-v1.json"

  if(-not (Test-Path -LiteralPath $alphaPath -PathType Leaf)){
    $alpha = [ordered]@{
      schema = "courier.node_registry.v1"
      node_id = "node-alpha"
      node_name = "Node Alpha"
      node_role = "sender"
      principal = "courier-local@covenant"
      status = "active"
      created_utc = (Get-Date).ToUniversalTime().ToString("o")
      last_seen_utc = $null
      allowed_namespaces = @("courier/message")
      tags = @("release-demo")
    }
    [IO.File]::WriteAllText($alphaPath, (($alpha | ConvertTo-Json -Depth 20 -Compress) + [string][char]10), [Text.UTF8Encoding]::new($false))
    Write-Host ("VTP_DEMO_REGISTRY_NODE_OK: " + $alphaPath)
  }

  if(-not (Test-Path -LiteralPath $betaPath -PathType Leaf)){
    $beta = [ordered]@{
      schema = "courier.node_registry.v1"
      node_id = "node-beta"
      node_name = "Node Beta"
      node_role = "receiver"
      principal = "courier-local@covenant"
      status = "active"
      created_utc = (Get-Date).ToUniversalTime().ToString("o")
      last_seen_utc = $null
      allowed_namespaces = @("courier/message")
      tags = @("release-demo")
    }
    [IO.File]::WriteAllText($betaPath, (($beta | ConvertTo-Json -Depth 20 -Compress) + [string][char]10), [Text.UTF8Encoding]::new($false))
    Write-Host ("VTP_DEMO_REGISTRY_NODE_OK: " + $betaPath)
  }

  if(-not (Test-Path -LiteralPath $netPath -PathType Leaf)){
    $net = [ordered]@{
      schema = "courier.network_registry.v1"
      network_id = "courier-internal-net-v1"
      network_name = "Courier Internal Net"
      transport_kind = "filesystem-drop"
      listener_port = 47151
      binding_mode = "dedicated"
      visibility = "private"
      status = "active"
      allowed_nodes = @("node-alpha","node-beta")
      created_utc = (Get-Date).ToUniversalTime().ToString("o")
    }
    [IO.File]::WriteAllText($netPath, (($net | ConvertTo-Json -Depth 20 -Compress) + [string][char]10), [Text.UTF8Encoding]::new($false))
    Write-Host ("VTP_DEMO_REGISTRY_NETWORK_OK: " + $netPath)
  }
  Run-PS (Join-Path $Scripts "courier_open_session_v1.ps1") @(
    "-RepoRoot",$RepoRoot,
    "-SessionId","session-alpha-beta-001",
    "-SenderNodeId","node-alpha",
    "-RecipientNodeId",$To,
    "-NetworkId","courier-internal-net-v1",
    "-SessionRole","message-delivery"
  )

  Run-PS (Join-Path $Scripts "courier_transport_send_v1.ps1") @(
    "-RepoRoot",$RepoRoot,
    "-MessagePath",$messagePath,
    "-SenderIdentity","courier-local@covenant",
    "-RecipientIdentity","courier-local@covenant",
    "-SenderNodeId","node-alpha",
    "-RecipientNodeId",$To,
    "-NetworkId","courier-internal-net-v1",
    "-SessionId","session-alpha-beta-001",
    "-SenderRole","message-delivery",
    "-DropRoot",("runtime\nodes\" + $To + "\inbox\drop")
  )

  Write-Host "VTP_SEND_OK"
  exit 0
}

if($Command -eq "transmit"){
  $sendText = Run-PS $PSCommandPath @("send","-RepoRoot",$RepoRoot,"-NodeId",$NodeId,"-To",$To)

  $frameId = ""
  foreach($line in ($sendText -split "`n")){
    if($line -match "COURIER_TRANSPORT_SEND_OK:\s+(.+)$"){
      $sendRel = $Matches[1].Trim()
      $frameId = Split-Path -Leaf $sendRel
    }
  }

  if([string]::IsNullOrWhiteSpace($frameId)){
    throw "VTP_TRANSMIT_FAIL:FRAME_ID_NOT_FOUND"
  }

  $acceptedPath = Join-Path $RepoRoot ("runtime\nodes\" + $To + "\accepted\" + $frameId)
  $dropPath = Join-Path $RepoRoot ("runtime\nodes\" + $To + "\inbox\drop\" + $frameId)
  $rejectedPath = Join-Path $RepoRoot ("runtime\nodes\" + $To + "\rejected\" + $frameId)

  $maxAttempts = 8
  $attempt = 0

  while($attempt -lt $maxAttempts){
    if(Test-Path -LiteralPath $acceptedPath -PathType Container){
      break
    }

    if(Test-Path -LiteralPath $rejectedPath -PathType Container){
      break
    }

    Run-PS $PSCommandPath @("node-loop","-RepoRoot",$RepoRoot,"-NodeId",$To)

    if(Test-Path -LiteralPath $acceptedPath -PathType Container){
      break
    }

    if(Test-Path -LiteralPath $rejectedPath -PathType Container){
      break
    }

    Start-Sleep -Milliseconds 250
    $attempt++
  }

  if(-not (Test-Path -LiteralPath $acceptedPath -PathType Container)){
    Write-Host ("VTP_TRANSMIT_FRAME: " + $frameId)
    Write-Host ("VTP_TRANSMIT_ATTEMPTS: " + $attempt)
    Write-Host ("VTP_TRANSMIT_ACCEPTED_EXISTS: " + (Test-Path -LiteralPath $acceptedPath))
    Write-Host ("VTP_TRANSMIT_DROP_EXISTS: " + (Test-Path -LiteralPath $dropPath))
    Write-Host ("VTP_TRANSMIT_REJECTED_EXISTS: " + (Test-Path -LiteralPath $rejectedPath))

    if(Test-Path -LiteralPath $rejectedPath -PathType Container){
      throw ("VTP_TRANSMIT_FAIL:FRAME_REJECTED:" + $frameId)
    }

    throw ("VTP_TRANSMIT_FAIL:FRAME_NOT_ACCEPTED:" + $frameId)
  }

  Run-PS $PSCommandPath @("status","-RepoRoot",$RepoRoot,"-NodeId",$To)

  Write-Host ("VTP_TRANSMIT_LATEST_ACCEPTED: " + $frameId)
  Write-Host "VTP_TRANSMIT_OK"
  exit 0
}

if($Command -eq "dlp-test"){
  Run-PS (Join-Path $Scripts "_selftest_vtp_dlp_negative_v1.ps1") @("-RepoRoot",$RepoRoot,"-NodeId",$NodeId)
  Write-Host "VTP_DLP_TEST_OK"
  exit 0
}

if($Command -eq "full-green"){
  Run-PS (Join-Path $RepoRoot "vtp_full_green.ps1") @("-RepoRoot",$RepoRoot,"-NodeId",$NodeId,"-To",$To)
  Write-Host "VTP_CLI_FULL_GREEN_OK"
  exit 0
}

if($Command -eq "dev-fast"){
  Run-PS (Join-Path $Scripts "_RUN_vtp_dev_fast_v1.ps1") @("-RepoRoot",$RepoRoot)
  exit 0
}

if($Command -eq "conformance"){
  Run-PS (Join-Path $Scripts "_RUN_vtp_conformance_v1.ps1") @("-RepoRoot",$RepoRoot)
  exit 0
}


if($Command -eq "wire-smoke"){
 Run-PS (Join-Path $Scripts "_selftest_vtp_udp_wire_v1.ps1") @("-RepoRoot",$RepoRoot,"-To",$To)
 Write-Host "VTP_WIRE_SMOKE_OK"
 exit 0
}

if($Command -eq "wire-ingest"){
  Run-PS (Join-Path $Scripts "_selftest_vtp_udp_wire_ingest_v1.ps1") @("-RepoRoot",$RepoRoot,"-To",$To)
  Write-Host "VTP_WIRE_INGEST_OK"
  exit 0
}

if($Command -eq "wire-key-test"){
  Run-PS (Join-Path $Scripts "_selftest_vtp_wire_key_envelope_v1.ps1") @("-RepoRoot",$RepoRoot,"-To",$To)
  Write-Host "VTP_WIRE_KEY_TEST_OK"
  exit 0
}

if($Command -eq "receipts"){
  Run-PS (Join-Path $Scripts "vtp_receipts_latest_v1.ps1") @("-RepoRoot",$RepoRoot,"-NodeId",$NodeId)
  exit 0
}

if($Command -eq "verify"){
  Run-PS (Join-Path $RepoRoot "vtp_verify_all.ps1") @("-RepoRoot",$RepoRoot,"-NodeId",$NodeId,"-To",$To)
  exit 0
}

if($Command -eq "wire-negative"){
  Run-PS (Join-Path $Scripts "_selftest_vtp_udp_wire_negative_v1.ps1") @("-RepoRoot",$RepoRoot,"-To",$To)
  Write-Host "VTP_WIRE_NEGATIVE_OK"
  exit 0
}
throw "UNKNOWN_VTP_COMMAND:$Command"
