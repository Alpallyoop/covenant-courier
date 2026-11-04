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
# Allowed frames go to a folder only this node writes; the listener reads from there, never from drop.
$ApprovedDir = Join-Path $RepoRoot ("runtime\nodes\" + $NodeId + "\approved")
if($NodeId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z' -or $NodeId.Contains("..")){ throw "VTP_NODE_LOOP_POLICY_FAIL:BAD_NODE_ID" }
function Test-Link([string]$Path){ return ((Test-Path -LiteralPath $Path) -and (((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) }
$PolicyGate = Join-Path $PSScriptRoot "vtp_policy_gate_v1.ps1"
$BaseLoop = Join-Path $PSScriptRoot "vtp_node_loop_v1.ps1"

if(-not (Test-Path -LiteralPath $PolicyGate -PathType Leaf)){ throw "VTP_NODE_LOOP_POLICY_FAIL:MISSING_POLICY_GATE" }
if(-not (Test-Path -LiteralPath $BaseLoop -PathType Leaf)){ throw "VTP_NODE_LOOP_POLICY_FAIL:MISSING_BASE_LOOP" }

foreach($dir in @($Drop,$Processing,$Rejected,$ApprovedDir)){
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
  # A link in the drop folder is never claimed or deleted through (it could point anywhere).
  if(Test-Link $frame.FullName){ $skipCount++; Write-Host ("VTP_POLICY_SKIP_LINK: " + $frame.Name); continue }

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

  $eapPrev = $ErrorActionPreference; $ErrorActionPreference = "Continue"; $out = & ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $PolicyGate -RepoRoot $RepoRoot -FrameDir $claimPath 2>&1; $ErrorActionPreference = $eapPrev
  $text = ($out | Out-String).Trim()
  $code = $LASTEXITCODE

  if($code -eq 42){
    $dest = Join-Path $Rejected $frame.Name
    # Rejected evidence is never deleted to make room: a second frame of that name gets its own folder.
    if(Test-Path -LiteralPath $dest){ $dest = $dest + "-dup-" + [guid]::NewGuid().ToString("N").Substring(0,8) }
    Move-Item -LiteralPath $claimPath -Destination $dest -ErrorAction Stop
    [IO.File]::WriteAllText((Join-Path $dest "reject_reason.txt"), ($text + [string][char]10), [Text.UTF8Encoding]::new($false))
    Write-Host ("VTP_POLICY_REJECT_OK: " + $dest)
    $rejectCount++
    continue
  }

  if($code -ne 0){
    throw ("VTP_NODE_LOOP_POLICY_FAIL:POLICY_GATE_EXIT_" + $code + ":" + $text)
  }

  $returnPath = Join-Path $ApprovedDir $frame.Name
  if(Test-Path -LiteralPath $returnPath){
    # Same frame name already approved: keep this one as rejected evidence instead of deleting it.
    $dup = Join-Path $Rejected ($frame.Name + "-dup-" + [guid]::NewGuid().ToString("N").Substring(0,8))
    Move-Item -LiteralPath $claimPath -Destination $dup -ErrorAction Stop
    [IO.File]::WriteAllText((Join-Path $dup "reject_reason.txt"), ("VTP_POLICY_DENY:DUPLICATE_FRAME_NAME" + [string][char]10), [Text.UTF8Encoding]::new($false))
    $skipCount++
    continue
  }
  Move-Item -LiteralPath $claimPath -Destination $returnPath -ErrorAction Stop
  Write-Host ("VTP_POLICY_ALLOW_OK: " + $returnPath)
  $allowCount++
}

& ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $BaseLoop -RepoRoot $RepoRoot -NodeId $NodeId -Once -Approved
if($LASTEXITCODE -ne 0){ throw "VTP_NODE_LOOP_POLICY_FAIL:BASE_LOOP_FAILED" }

Write-Host ("VTP_NODE_LOOP_POLICY_CLAIMS: allow=" + $allowCount + " reject=" + $rejectCount + " skip=" + $skipCount)
Write-Host ("VTP_NODE_LOOP_POLICY_OK: " + $NodeId)
