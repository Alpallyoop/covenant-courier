Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Dir([string]$Path){
  if(-not (Test-Path -LiteralPath $Path)){
    [void][System.IO.Directory]::CreateDirectory($Path)
  }
}

function Write-Utf8NoBomLf([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path
  if([string]::IsNullOrWhiteSpace($dir) -eq $false){
    Ensure-Dir $dir
  }

  $t = $Text.Replace("`r`n","`n").Replace("`r","`n")
  if(-not $t.EndsWith("`n")){ $t += "`n" }

  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path,$t,$enc)
}

function Read-Json([string]$Path){
  if(-not (Test-Path -LiteralPath $Path)){
    throw ("MISSING_JSON_FILE: " + $Path)
  }
  return (Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json)
}

function ConvertTo-StableObject([object]$Value){
  if($null -eq $Value){ return $null }

  if($Value -is [System.Collections.IDictionary]){
    $ordered = [ordered]@{}
    $keys = @($Value.get_Keys() | Sort-Object)
    foreach($k in $keys){
      $ordered[$k] = ConvertTo-StableObject $Value[$k]
    }
    return $ordered
  }

  if($Value -is [System.Management.Automation.PSCustomObject]){
    $ordered = [ordered]@{}
    $props = @($Value.PSObject.Properties.Name | Sort-Object)
    foreach($p in $props){
      $ordered[$p] = ConvertTo-StableObject $Value.$p
    }
    return $ordered
  }

  if(($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])){
    $arr = New-Object System.Collections.Generic.List[object]
    foreach($item in $Value){
      [void]$arr.Add((ConvertTo-StableObject $item))
    }
    return @($arr.ToArray())
  }

  return $Value
}

function Write-JsonCanonical([string]$Path,[object]$Obj){
  $stable = ConvertTo-StableObject $Obj
  $json = $stable | ConvertTo-Json -Depth 100 -Compress
  Write-Utf8NoBomLf $Path $json
}

function Sha256Hex([string]$Text){
  $norm = $Text.Replace("`r`n","`n").Replace("`r","`n")
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($norm)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join "")
  }
  finally {
    $sha.Dispose()
  }
}

function Append-Receipt([string]$RepoRoot,[object]$Receipt){
  $path = Join-Path $RepoRoot "proofs\receipts\courier.ndjson"
  $dir  = Split-Path -Parent $path
  Ensure-Dir $dir

  $stable = ConvertTo-StableObject $Receipt
  $json = $stable | ConvertTo-Json -Depth 100 -Compress

  $enc = New-Object System.Text.UTF8Encoding($false)
  $line = $json.Replace("`r`n","`n").Replace("`r","`n")
  if(-not $line.EndsWith("`n")){ $line += "`n" }
  [System.IO.File]::AppendAllText($path,$line,$enc)
}