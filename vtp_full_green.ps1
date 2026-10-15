param(
  [string]$RepoRoot = ".",
  [string]$NodeId = "node-beta",
  [string]$To = "node-beta"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path $RepoRoot).Path
$Vtp = Join-Path $RepoRoot "vtp.ps1"

if(-not (Test-Path -LiteralPath $Vtp -PathType Leaf)){
  throw "VTP_FULL_GREEN_FAIL:MISSING_VTP"
}

function Run-Vtp {
  param([string[]]$ChildArgs)

  $ps = ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
  $out = & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Vtp @ChildArgs 2>&1
  $code = $LASTEXITCODE
  $text = ($out | Out-String)

  Write-Host $text.Trim()

  if($code -ne 0){
    throw ("VTP_FULL_GREEN_FAIL:CHILD_EXIT:" + $code + ":" + ($ChildArgs -join " "))
  }

  return $text
}

Run-Vtp @("smoke","-RepoRoot",$RepoRoot)
Run-Vtp @("dlp-test","-RepoRoot",$RepoRoot,"-NodeId",$NodeId)

$sendText = Run-Vtp @("send","-RepoRoot",$RepoRoot,"-To",$To)

$frameId = ""
foreach($line in ($sendText -split "`n")){
  if($line -match 'COURIER_TRANSPORT_SEND_OK:\s+(.+)$'){
    $sendRel = $Matches[1].Trim()
    $frameId = Split-Path -Leaf $sendRel
  }
}

if([string]::IsNullOrWhiteSpace($frameId)){
  throw "VTP_FULL_GREEN_FAIL:FRAME_ID_NOT_FOUND"
}

Run-Vtp @("node-loop","-RepoRoot",$RepoRoot,"-NodeId",$NodeId)

$acceptedPath = Join-Path $RepoRoot ("runtime\nodes\" + $NodeId + "\accepted\" + $frameId)
$dropPath = Join-Path $RepoRoot ("runtime\nodes\" + $NodeId + "\inbox\drop\" + $frameId)
$rejectedPath = Join-Path $RepoRoot ("runtime\nodes\" + $NodeId + "\rejected\" + $frameId)
$processingRoot = Join-Path $RepoRoot ("runtime\nodes\" + $NodeId + "\processing")

if(-not (Test-Path -LiteralPath $acceptedPath -PathType Container)){
  Write-Host ("VTP_FULL_GREEN_FRAME: " + $frameId)
  Write-Host ("VTP_FULL_GREEN_ACCEPTED_EXISTS: " + (Test-Path -LiteralPath $acceptedPath))
  Write-Host ("VTP_FULL_GREEN_DROP_EXISTS: " + (Test-Path -LiteralPath $dropPath))
  Write-Host ("VTP_FULL_GREEN_REJECTED_EXISTS: " + (Test-Path -LiteralPath $rejectedPath))

  if(Test-Path -LiteralPath $processingRoot -PathType Container){
    Write-Host "VTP_FULL_GREEN_PROCESSING_LIST_BEGIN"
    Get-ChildItem -LiteralPath $processingRoot -Directory -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending |
      Select-Object -First 10 |
      ForEach-Object { Write-Host $_.FullName }
    Write-Host "VTP_FULL_GREEN_PROCESSING_LIST_END"
  }

  throw ("VTP_FULL_GREEN_FAIL:FRAME_NOT_ACCEPTED:" + $frameId)
}

Run-Vtp @("status","-RepoRoot",$RepoRoot,"-NodeId",$NodeId)

Write-Host ("VTP_FULL_GREEN_LATEST_ACCEPTED: " + $frameId)
Write-Host "VTP_FULL_GREEN_OK"
