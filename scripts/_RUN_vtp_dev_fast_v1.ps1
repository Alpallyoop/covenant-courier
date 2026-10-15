param([Parameter(Mandatory=$true)][string]$RepoRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$steps = @(
  @("_selftest_vtp_node_loop_v1.ps1","VTP_NODE_LOOP_SELFTEST_OK"),
  @("_selftest_vtp_session_key_upgrade_v1.ps1","VTP_SESSION_KEY_UPGRADE_SELFTEST_OK"),
  @("_selftest_vtp_replay_guard_v1.ps1","VTP_REPLAY_GUARD_SELFTEST_OK")
)

foreach($s in $steps){
  $script = Join-Path $PSScriptRoot $s[0]
  $out = & ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script -RepoRoot $RepoRoot 2>&1
  $text = ($out | Out-String)
  if($LASTEXITCODE -ne 0){ throw "VTP_DEV_FAST_FAIL:$($s[0])" }
  if($text -notmatch [regex]::Escape($s[1])){ throw "VTP_DEV_FAST_MISSING_TOKEN:$($s[1])" }
  Write-Host "DEV_FAST_OK: $($s[0])"
}

Write-Host "VTP_DEV_FAST_PASS"
