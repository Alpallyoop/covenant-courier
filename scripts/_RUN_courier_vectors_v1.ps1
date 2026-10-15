param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [string]$FreezeDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path $RepoRoot).Path
if([string]::IsNullOrWhiteSpace($FreezeDir)){
  $FreezeDir = Join-Path $RepoRoot "proofs\freeze\transport_hardening_20260409T220543Z"
}

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

$PositiveSource = Join-Path $RepoRoot "test_vectors\courier_v1\transport\accepted"
$NegativeSource = Join-Path $FreezeDir "transport_hardening\rejected"

if(-not (Test-Path -LiteralPath $PositiveSource -PathType Container)){
  throw ("COURIER_VECTORS_FAIL:MISSING_POSITIVE_SOURCE:" + $PositiveSource)
}
if(-not (Test-Path -LiteralPath $NegativeSource -PathType Container)){
  throw ("COURIER_VECTORS_FAIL:MISSING_NEGATIVE_SOURCE:" + $NegativeSource)
}

$positiveDirs = @(Get-ChildItem -LiteralPath $PositiveSource -Directory -ErrorAction SilentlyContinue)
$negativeDirs = @(Get-ChildItem -LiteralPath $NegativeSource -Directory -ErrorAction SilentlyContinue)

if($positiveDirs.Count -lt 1){
  throw "COURIER_VECTORS_FAIL:NO_ACCEPTED_VECTOR"
}
if($negativeDirs.Count -lt 1){
  throw "COURIER_VECTORS_FAIL:NO_REJECTED_VECTOR"
}

$VectorRoot   = Join-Path $RepoRoot "test_vectors\courier_v1\golden"
$PositiveRoot = Join-Path $VectorRoot "positive"
$NegativeRoot = Join-Path $VectorRoot "negative"
$ProofRoot    = Join-Path $RepoRoot "proofs\vectors"
$RunId        = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$RunDir       = Join-Path $ProofRoot ("courier_vectors_" + $RunId)
$MetaPath     = Join-Path $RunDir "meta.json"
$ShaPath      = Join-Path $RunDir "sha256sums.txt"

Ensure-Dir $PositiveRoot
Ensure-Dir $NegativeRoot
Ensure-Dir $RunDir

$posDir = Join-Path $PositiveRoot "transport_accept"
$negDir = Join-Path $NegativeRoot "wrong_signer_boundary"

foreach($d in @($posDir,$negDir)){
  if(Test-Path -LiteralPath $d){
    Remove-Item -LiteralPath $d -Recurse -Force
  }
}

$posLatest = $positiveDirs | Sort-Object Name | Select-Object -First 1
$negLatest = $negativeDirs | Sort-Object Name | Select-Object -Last 1

Copy-Item -LiteralPath $posLatest.FullName -Destination $posDir -Recurse -Force
Copy-Item -LiteralPath $negLatest.FullName -Destination $negDir -Recurse -Force

$meta = [ordered]@{
  schema = "courier.vectors.run.v1"
  run_id = $RunId
  created_utc = (Get-Date).ToUniversalTime().ToString("o")
  positive_source = $PositiveSource
  negative_source = $NegativeSource
  positive_vector = "transport_accept"
  negative_vectors = @("wrong_signer_boundary")
  success_token = "COURIER_TRANSPORT_SUITE_ALL_GREEN"
}

$enc = New-Object System.Text.UTF8Encoding($false)
$metaJson = $meta | ConvertTo-Json -Depth 20 -Compress
[System.IO.File]::WriteAllText($MetaPath, ($metaJson + "`n"), $enc)

$files = @(Get-ChildItem -LiteralPath $RunDir -Recurse -File | Where-Object {
  $_.FullName -ne $ShaPath
} | Sort-Object FullName)

$lines = New-Object System.Collections.Generic.List[string]
foreach($f in $files){
  $hash = Get-Sha256Hex $f.FullName
  $rel = Get-RelPath $RunDir $f.FullName
  [void]$lines.Add("$hash  $rel")
}
[System.IO.File]::WriteAllText($ShaPath, ((($lines.ToArray()) -join "`n") + "`n"), $enc)

Write-Host ("RUN_DIR: " + $RunDir)
Write-Host ("SHA256SUMS_OK: " + $ShaPath)
Write-Host "COURIER_VECTORS_ALL_GREEN"
