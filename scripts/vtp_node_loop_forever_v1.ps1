param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [string]$NodeId = "node-beta",
  [int]$IntervalSeconds = 30,
  [switch]$VerboseTick
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path $RepoRoot).Path
$Vtp = Join-Path $RepoRoot "vtp.ps1"
$LogDir = Join-Path $RepoRoot "proofs\runtime_logs"
$LogPath = Join-Path $LogDir ("vtp_node_loop_forever_" + $NodeId + ".log")

if(-not (Test-Path -LiteralPath $LogDir)){
  [void][IO.Directory]::CreateDirectory($LogDir)
}

while($true){
  $stdout = ""
  $stderr = ""
  try {
    $out = & ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Vtp node-loop -RepoRoot $RepoRoot -NodeId $NodeId 2>&1
    $stdout = ($out | Out-String).Trim()

    if($LASTEXITCODE -ne 0){
      $line = ("VTP_NODE_LOOP_FOREVER_CHILD_EXIT:" + $LASTEXITCODE + ":" + $stdout)
      [IO.File]::AppendAllText($LogPath, ($line + "`n"), [Text.UTF8Encoding]::new($false))
      Write-Host $line
    } elseif($VerboseTick){
      Write-Host ("VTP_NODE_LOOP_FOREVER_TICK_OK: " + (Get-Date).ToUniversalTime().ToString("o"))
    }
  } catch {
    $line = ("VTP_NODE_LOOP_FOREVER_ERROR:" + $_.Exception.Message)
    [IO.File]::AppendAllText($LogPath, ($line + "`n"), [Text.UTF8Encoding]::new($false))
    Write-Host $line
  }

  Start-Sleep -Seconds $IntervalSeconds
}