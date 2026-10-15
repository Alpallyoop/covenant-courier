param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PSExe = ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)

$RegistrySelftest  = Join-Path $PSScriptRoot "_selftest_courier_registry_v1.ps1"
$NodePositive      = Join-Path $PSScriptRoot "_selftest_courier_node_to_node_positive_v1.ps1"
$NodeNegClosed     = Join-Path $PSScriptRoot "_selftest_courier_node_to_node_negative_closed_session_v1.ps1"
$ReceiptSelftest   = Join-Path $PSScriptRoot "_selftest_courier_transport_receipts_v1.ps1"
$VectorRunner      = Join-Path $PSScriptRoot "_RUN_courier_vectors_v1.ps1"

$RunId = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$RunRoot = Join-Path $RepoRoot ("proofs\full_green\vtp_full_green_" + $RunId)
$StdoutPath = Join-Path $RunRoot "stdout.log"
$StderrPath = Join-Path $RunRoot "stderr.log"
$MetaPath   = Join-Path $RunRoot "meta.json"
$ShaPath    = Join-Path $RunRoot "sha256sums.txt"

function Ensure-Dir([string]$Path){
  if(-not (Test-Path -LiteralPath $Path)){
    [void][System.IO.Directory]::CreateDirectory($Path)
  }
}

function Get-Sha256Hex([string]$Path){
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $fs  = [System.IO.File]::OpenRead($Path)
  try { $hash = $sha.ComputeHash($fs) }
  finally { $fs.Dispose(); $sha.Dispose() }
  return (($hash | ForEach-Object { $_.ToString("x2") }) -join "")
}

function Get-RelPath([string]$Root,[string]$Path){
  $rel = $Path.Substring($Root.Length).TrimStart('\','/')
  return $rel.Replace('\','/')
}

function Run-Step {
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][string]$Script
  )

  $out = Join-Path $RunRoot ($Name + ".stdout.tmp")
  $err = Join-Path $RunRoot ($Name + ".stderr.tmp")
  if(Test-Path -LiteralPath $out){ Remove-Item -LiteralPath $out -Force }
  if(Test-Path -LiteralPath $err){ Remove-Item -LiteralPath $err -Force }

  $p = Start-Process -FilePath $PSExe -ArgumentList @(
    "-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass",
    "-File",$Script,
    "-RepoRoot",$RepoRoot
  ) -RedirectStandardOutput $out -RedirectStandardError $err -Wait -PassThru

  $stdout = ""
  $stderr = ""
  if(Test-Path -LiteralPath $out){ $stdout = Get-Content -LiteralPath $out -Raw }
  if(Test-Path -LiteralPath $err){ $stderr = Get-Content -LiteralPath $err -Raw }

  Add-Content -LiteralPath $StdoutPath -Value ("===== " + $Name + " =====`n" + $stdout)
  Add-Content -LiteralPath $StderrPath -Value ("===== " + $Name + " =====`n" + $stderr)

  if($p.ExitCode -ne 0){
    throw ("VTP_FULL_GREEN_FAIL:" + $Name + "_EXIT_" + $p.ExitCode)
  }
}

Ensure-Dir $RunRoot
New-Item -ItemType File -Path $StdoutPath -Force | Out-Null
New-Item -ItemType File -Path $StderrPath -Force | Out-Null

Run-Step -Name "registry_selftest" -Script $RegistrySelftest
Run-Step -Name "node_to_node_positive" -Script $NodePositive
Run-Step -Name "node_to_node_negative_closed" -Script $NodeNegClosed
Run-Step -Name "transport_receipts" -Script $ReceiptSelftest
Run-Step -Name "vectors" -Script $VectorRunner

$meta = [ordered]@{
  schema = "vtp.full_green.run.v1"
  run_id = $RunId
  created_utc = (Get-Date).ToUniversalTime().ToString("o")
  implementation = "Courier Reference Engine"
  protocol_name = "Verifiable Transport Protocol"
  protocol_version = "v1"
  required_tokens = @(
    "COURIER_REGISTRY_SELFTEST_OK",
    "COURIER_NODE_TO_NODE_POSITIVE_OK",
    "COURIER_NODE_TO_NODE_NEGATIVE_CLOSED_SESSION_OK",
    "COURIER_RECEIPT_SELFTEST_OK",
    "COURIER_VECTORS_ALL_GREEN"
  )
  final_token = "VTP_FULL_GREEN"
}

$enc = New-Object System.Text.UTF8Encoding($false)
$metaJson = $meta | ConvertTo-Json -Depth 20 -Compress
[System.IO.File]::WriteAllText($MetaPath, ($metaJson + "`n"), $enc)

$files = @(Get-ChildItem -LiteralPath $RunRoot -Recurse -File | Where-Object {
  $_.FullName -ne $ShaPath
} | Sort-Object FullName)

$lines = New-Object System.Collections.Generic.List[string]
foreach($f in $files){
  $hash = Get-Sha256Hex $f.FullName
  $rel = Get-RelPath $RunRoot $f.FullName
  [void]$lines.Add("$hash  $rel")
}
[System.IO.File]::WriteAllText($ShaPath, ((($lines.ToArray()) -join "`n") + "`n"), $enc)

Write-Host ("RUN_ROOT: " + $RunRoot)
Write-Host ("SHA256SUMS_OK: " + $ShaPath)
Write-Host "VTP_FULL_GREEN"
