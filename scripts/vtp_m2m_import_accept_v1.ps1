param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$BundleRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Listen = Join-Path $PSScriptRoot "courier_transport_listen_v1.ps1"

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

$ShaPath = Join-Path $BundleRoot "sha256sums.txt"
if(-not (Test-Path -LiteralPath $ShaPath -PathType Leaf)){
  Fail "VTP_M2M_IMPORT_FAIL:MISSING_SHA256SUMS"
}

$lines = @(Get-Content -LiteralPath $ShaPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
foreach($line in $lines){
  if($line -notmatch '^([0-9a-f]{64})\s{2}(.+)$'){
    Fail ("VTP_M2M_IMPORT_FAIL:BAD_SHA_LINE:" + $line)
  }
  $expected = $matches[1]
  $rel = $matches[2]
  $path = Join-Path $BundleRoot ($rel.Replace('/','\'))
  if(-not (Test-Path -LiteralPath $path -PathType Leaf)){
    Fail ("VTP_M2M_IMPORT_FAIL:MISSING_HASHED_FILE:" + $rel)
  }
  $actual = Get-Sha256Hex $path
  if($actual -ne $expected){
    Fail ("VTP_M2M_IMPORT_FAIL:HASH_MISMATCH:" + $rel)
  }
}

$ManifestPath = Join-Path $BundleRoot "m2m_manifest.json"
if(-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)){
  Fail "VTP_M2M_IMPORT_FAIL:MISSING_MANIFEST"
}
$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json

$FrameSource = Join-Path $BundleRoot (([string]$manifest.frame_dir).Replace('/','\'))
if(-not (Test-Path -LiteralPath $FrameSource -PathType Container)){
  Fail "VTP_M2M_IMPORT_FAIL:MISSING_FRAME_DIR"
}

$ImportRoot = Join-Path $RepoRoot "proofs\m2m_import\vtp_m2m_import_v1"
$Drop = Join-Path $ImportRoot "node-beta\inbox\drop"
$Accepted = Join-Path $ImportRoot "node-beta\accepted"
$Rejected = Join-Path $ImportRoot "node-beta\rejected"
$ConfigPath = Join-Path $ImportRoot "node-beta\listener.config.json"

Reset-Dir $ImportRoot
Ensure-Dir $Drop
Ensure-Dir $Accepted
Ensure-Dir $Rejected

$DestFrame = Join-Path $Drop ([System.IO.Path]::GetFileName($FrameSource))
Copy-Item -LiteralPath $FrameSource -Destination $DestFrame -Recurse -Force

$cfg = [ordered]@{
  drop_root = ($Drop.Substring($RepoRoot.Length).TrimStart('\','/')).Replace('\','/')
  accepted_root = ($Accepted.Substring($RepoRoot.Length).TrimStart('\','/')).Replace('\','/')
  rejected_root = ($Rejected.Substring($RepoRoot.Length).TrimStart('\','/')).Replace('\','/')
}
Write-Utf8NoBomLf $ConfigPath (($cfg | ConvertTo-Json -Depth 10 -Compress))

try {
  & $Listen -RepoRoot $RepoRoot -ConfigPath $ConfigPath
}
catch {
  Fail ("VTP_M2M_IMPORT_FAIL:LISTEN:" + $_.ToString())
}

$accepted = @(Get-ChildItem -LiteralPath $Accepted -Directory -ErrorAction SilentlyContinue)
$rejected = @(Get-ChildItem -LiteralPath $Rejected -Directory -ErrorAction SilentlyContinue)

if($accepted.Count -ne 1){
  Fail ("VTP_M2M_IMPORT_FAIL:EXPECTED_ONE_ACCEPTED:COUNT_" + $accepted.Count)
}
if($rejected.Count -ne 0){
  Fail ("VTP_M2M_IMPORT_FAIL:UNEXPECTED_REJECTED:COUNT_" + $rejected.Count)
}

Write-Host ("M2M_IMPORT_ROOT: " + $ImportRoot)
Write-Host ("M2M_ACCEPTED_FRAME: " + $accepted[0].FullName)
Write-Host "VTP_M2M_IMPORT_ACCEPT_OK"
Write-Host "VTP_MACHINE_TO_MACHINE_OK"
