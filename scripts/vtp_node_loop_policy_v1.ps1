param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [string]$NodeId = "node-beta",
  [switch]$Once
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path $RepoRoot).Path
$Drop = Join-Path $RepoRoot ("runtime\nodes\" + $NodeId + "\inbox\drop")
$Processing = Join-Path $RepoRoot ("runtime\nodes\" + $NodeId + "\processing")
$Rejected = Join-Path $RepoRoot ("runtime\nodes\" + $NodeId + "\rejected")
$PolicyGate = Join-Path $RepoRoot "scripts\vtp_policy_gate_v1.ps1"
$BaseLoop = Join-Path $RepoRoot "scripts\vtp_node_loop_v1.ps1"

if(-not (Test-Path -LiteralPath $PolicyGate -PathType Leaf)){ throw "VTP_NODE_LOOP_POLICY_FAIL:MISSING_POLICY_GATE" }
if(-not (Test-Path -LiteralPath $BaseLoop -PathType Leaf)){ throw "VTP_NODE_LOOP_POLICY_FAIL:MISSING_BASE_LOOP" }

foreach($dir in @($Drop,$Processing,$Rejected)){
  if(-not (Test-Path -LiteralPath $dir)){ [void][IO.Directory]::CreateDirectory($dir) }
}

$frames = @(Get-ChildItem -LiteralPath $Drop -Directory -ErrorAction SilentlyContinue | Sort-Object FullName)
$allowCount = 0
$rejectCount = 0
$skipCount = 0

foreach($frame in $frames){
  if(-not (Test-Path -LiteralPath $frame.FullName -PathType Container)){
    $skipCount++
    continue
  }

  $claimName = $frame.Name + ".locked-by-" + $NodeId
  $claimPath = Join-Path $Processing $claimName
  if(Test-Path -LiteralPath $claimPath){
    $claimPath = Join-Path $Processing ($claimName + "." + [guid]::NewGuid().ToString("N"))
  }

  try {
    Move-Item -LiteralPath $frame.FullName -Destination $claimPath -ErrorAction Stop
  } catch {
    if(-not (Test-Path -LiteralPath $frame.FullName -PathType Container)){
      $skipCount++
      continue
    }
    throw
  }

  $out = & ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $PolicyGate -RepoRoot $RepoRoot -FrameDir $claimPath 2>&1
  $text = ($out | Out-String).Trim()
  $code = $LASTEXITCODE

  if($code -eq 42){
    $dest = Join-Path $Rejected $frame.Name
    if(Test-Path -LiteralPath $dest){ Remove-Item -LiteralPath $dest -Recurse -Force }
    Move-Item -LiteralPath $claimPath -Destination $dest -ErrorAction Stop
    [IO.File]::WriteAllText((Join-Path $dest "reject_reason.txt"), ($text + [string][char]10), [Text.UTF8Encoding]::new($false))
    Write-Host ("VTP_POLICY_REJECT_OK: " + $dest)
    $rejectCount++
    continue
  }

  if($code -ne 0){
    throw ("VTP_NODE_LOOP_POLICY_FAIL:POLICY_GATE_EXIT_" + $code + ":" + $text)
  }

  $returnPath = Join-Path $Drop $frame.Name
  if(Test-Path -LiteralPath $returnPath){
    $skipCount++
    Remove-Item -LiteralPath $claimPath -Recurse -Force
    continue
  }
  Move-Item -LiteralPath $claimPath -Destination $returnPath -ErrorAction Stop
  Write-Host ("VTP_POLICY_ALLOW_OK: " + $returnPath)
  $allowCount++
}

& ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $BaseLoop -RepoRoot $RepoRoot -NodeId $NodeId -Once
if($LASTEXITCODE -ne 0){ throw "VTP_NODE_LOOP_POLICY_FAIL:BASE_LOOP_FAILED" }

Write-Host ("VTP_NODE_LOOP_POLICY_CLAIMS: allow=" + $allowCount + " reject=" + $rejectCount + " skip=" + $skipCount)
Write-Host ("VTP_NODE_LOOP_POLICY_OK: " + $NodeId)
