# Covenant Courier product library (v1).
#
# Deterministic JSON writer, hashing and file helpers shared by the product delivery path,
# the Constellation integration-receipt emitter and the Covenant Gate / NeverLost adapters.
# Works identically on Windows PowerShell 5.1 and PowerShell 7+: documents are serialised by
# CC-ToJson below, never by ConvertTo-Json (whose escaping and date handling differ by host).

Set-StrictMode -Version Latest

function CC-Fail([string]$Code){ throw $Code }

function CC-EnsureDir([string]$Path){
  if(-not (Test-Path -LiteralPath $Path -PathType Container)){ [void][System.IO.Directory]::CreateDirectory($Path) }
}

function CC-Utf8NoBom(){ return (New-Object System.Text.UTF8Encoding($false)) }

function CC-Sha256Bytes([byte[]]$Bytes){
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { return (($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString("x2") }) -join "") } finally { $sha.Dispose() }
}

function CC-Sha256Text([string]$Text){ return (CC-Sha256Bytes ((CC-Utf8NoBom).GetBytes($Text))) }

function CC-Sha256File([string]$Path){
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ CC-Fail ("CC_HASH_FAIL:MISSING_FILE:" + $Path) }
  return (CC-Sha256Bytes ([System.IO.File]::ReadAllBytes($Path)))
}

function CC-UtcNow(){ return [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ",[System.Globalization.CultureInfo]::InvariantCulture) }
function CC-UtcStampId(){ return [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssfffZ",[System.Globalization.CultureInfo]::InvariantCulture) }

function CC-JsonString([string]$s){
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('"')
  foreach($ch in $s.ToCharArray()){
    $c = [int]$ch
    switch($c){
      34 { [void]$sb.Append('\"') }
      92 { [void]$sb.Append('\\') }
      8  { [void]$sb.Append('\b') }
      12 { [void]$sb.Append('\f') }
      10 { [void]$sb.Append('\n') }
      13 { [void]$sb.Append('\r') }
      9  { [void]$sb.Append('\t') }
      default {
        if($c -lt 32){ [void]$sb.Append(('\u{0:x4}' -f $c)) } else { [void]$sb.Append($ch) }
      }
    }
  }
  [void]$sb.Append('"')
  return $sb.ToString()
}

# Compact JSON. -Sort orders object keys ordinally (canonical form); without it ordered
# dictionaries keep their insertion order (used where a contract fixes the key order).
function CC-ToJson($Value,[switch]$Sort){
  if($null -eq $Value){ return "null" }
  if($Value -is [bool]){ if($Value){ return "true" } else { return "false" } }
  if($Value -is [string]){ return (CC-JsonString $Value) }
  if($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [byte] -or $Value -is [uint32] -or $Value -is [uint64]){
    return ([string]::Format([System.Globalization.CultureInfo]::InvariantCulture,"{0}",$Value))
  }
  if($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]){ CC-Fail "CC_JSON_FAIL:FLOAT_NOT_ALLOWED" }
  if($Value -is [DateTime] -or $Value -is [DateTimeOffset]){ CC-Fail "CC_JSON_FAIL:DATETIME_VALUE_NOT_ALLOWED" }
  if($Value -is [System.Collections.IDictionary]){
    $keys = @($Value.get_Keys() | ForEach-Object { [string]$_ })
    if($Sort){ return (CC-ToJsonOrdinal $Value) }
    $parts = New-Object System.Collections.Generic.List[string]
    foreach($k in $keys){ $parts.Add((CC-JsonString $k) + ":" + (CC-ToJson $Value[$k])) }
    return ("{" + ($parts -join ",") + "}")
  }
  if($Value -is [System.Management.Automation.PSCustomObject]){
    $keys = @($Value.PSObject.Properties | ForEach-Object { [string]$_.Name })
    if($Sort){ return (CC-ToJsonOrdinal $Value) }
    $parts = New-Object System.Collections.Generic.List[string]
    foreach($k in $keys){ $parts.Add((CC-JsonString $k) + ":" + (CC-ToJson $Value.$k)) }
    return ("{" + ($parts -join ",") + "}")
  }
  if($Value -is [System.Collections.IEnumerable]){
    if($Sort){ return (CC-ToJsonOrdinal $Value) }
    $parts = New-Object System.Collections.Generic.List[string]
    foreach($item in $Value){ $parts.Add((CC-ToJson $item)) }
    return ("[" + ($parts -join ",") + "]")
  }
  CC-Fail ("CC_JSON_FAIL:UNSUPPORTED_TYPE:" + $Value.GetType().FullName)
}

# Sorted-key compact JSON with an ordinal sort (PowerShell's Sort-Object is culture-aware).
function CC-ToCanonicalJson($Value){
  return (CC-ToJsonOrdinal $Value)
}
function CC-ToJsonOrdinal($Value){
  # Scalars first: Windows PowerShell 5.1 can wrap strings in PSObject, which then also test as
  # PSCustomObject.
  if($null -eq $Value -or $Value -is [string] -or $Value -is [System.ValueType]){ return (CC-ToJson $Value) }
  if($Value -is [System.Collections.IDictionary]){
    $arr = [string[]]@($Value.get_Keys() | ForEach-Object { [string]$_ }); [Array]::Sort($arr,[StringComparer]::Ordinal)
    $parts = New-Object System.Collections.Generic.List[string]
    foreach($k in $arr){ $parts.Add((CC-JsonString $k) + ":" + (CC-ToJsonOrdinal $Value[$k])) }
    return ("{" + ($parts -join ",") + "}")
  }
  if($Value -is [System.Management.Automation.PSCustomObject]){
    $arr = [string[]]@($Value.PSObject.Properties | ForEach-Object { [string]$_.Name }); [Array]::Sort($arr,[StringComparer]::Ordinal)
    $parts = New-Object System.Collections.Generic.List[string]
    foreach($k in $arr){ $parts.Add((CC-JsonString $k) + ":" + (CC-ToJsonOrdinal $Value.$k)) }
    return ("{" + ($parts -join ",") + "}")
  }
  if(($Value -isnot [string]) -and ($Value -is [System.Collections.IEnumerable])){
    $parts = New-Object System.Collections.Generic.List[string]
    foreach($item in $Value){ $parts.Add((CC-ToJsonOrdinal $item)) }
    return ("[" + ($parts -join ",") + "]")
  }
  return (CC-ToJson $Value)
}

function CC-WriteTextFile([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path
  if($dir){ CC-EnsureDir $dir }
  $tmp = $Path + "." + [guid]::NewGuid().ToString("N") + ".tmp"
  [System.IO.File]::WriteAllBytes($tmp,(CC-Utf8NoBom).GetBytes($Text))
  if(Test-Path -LiteralPath $Path){ Remove-Item -LiteralPath $Path -Force }
  [System.IO.File]::Move($tmp,$Path)
}

# Writes one document: canonical (sorted) compact JSON + LF. Returns the SHA-256 of the file bytes.
function CC-WriteDocument([string]$Path,$Value){
  $text = (CC-ToCanonicalJson $Value) + "`n"
  CC-WriteTextFile $Path $text
  return (CC-Sha256Bytes ((CC-Utf8NoBom).GetBytes($text)))
}

function CC-AppendLine([string]$Path,[string]$Line){
  if($Line.Contains("`n") -or $Line.Contains("`r")){ CC-Fail "CC_APPEND_FAIL:MULTILINE" }
  $dir = Split-Path -Parent $Path
  if($dir){ CC-EnsureDir $dir }
  $bytes = (CC-Utf8NoBom).GetBytes($Line + "`n")
  $fs = [System.IO.File]::Open($Path,[System.IO.FileMode]::Append,[System.IO.FileAccess]::Write,[System.IO.FileShare]::Read)
  try { $fs.Write($bytes,0,$bytes.Length); $fs.Flush($true) } finally { $fs.Dispose() }
}

# PowerShell 7's ConvertFrom-Json turns ISO-8601 strings into DateTime values (and loses their exact
# text); Windows PowerShell 5.1 keeps strings. To read every document the same way on both hosts,
# date-like strings are prefixed with U+E000 before parsing (so they are not recognised) and the
# prefix is removed again afterwards. Values are returned exactly as written in the file.
$script:CC_Shield = [string][char]0xE000
function CC-Unshield($Value){
  if($null -eq $Value){ return $null }
  if($Value -is [string]){ if($Value.StartsWith($script:CC_Shield)){ return $Value.Substring(1) } ; return $Value }
  if($Value -is [System.Management.Automation.PSCustomObject]){
    foreach($p in @($Value.PSObject.Properties)){ $p.Value = (CC-Unshield $p.Value) }
    return $Value
  }
  if(($Value -isnot [string]) -and ($Value -is [System.Collections.IList])){
    for($i=0; $i -lt $Value.Count; $i++){ $Value[$i] = (CC-Unshield $Value[$i]) }
    return ,$Value
  }
  return $Value
}
function CC-ParseJson([string]$Raw){
  # Only whole string values (after : , or [, not followed by :) are shielded; never keys and never
  # text inside another string.
  $shielded = [regex]::Replace($Raw,'(?<=[:,\[]\s*)"(\d{4}-\d{2}-\d{2}T[^"\\]*)"(?!\s*:)',('"' + $script:CC_Shield + '$1"'))
  try { $o = ($shielded | ConvertFrom-Json -ErrorAction Stop) } catch { CC-Fail "CC_READ_FAIL:INVALID_JSON" }
  return (CC-Unshield $o)
}
function CC-ReadJsonFile([string]$Path,[int]$MaxBytes = 1048576){
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ CC-Fail ("CC_READ_FAIL:MISSING:" + $Path) }
  if((Get-Item -LiteralPath $Path).Length -gt $MaxBytes){ CC-Fail "CC_READ_FAIL:TOO_LARGE" }
  $raw = [System.IO.File]::ReadAllText($Path,(CC-Utf8NoBom))
  return (CC-ParseJson $raw)
}

# Converts a parsed document into ordered dictionaries/arrays/scalars for CC-ToJson.
function CC-ToOrderedTree($Value){
  if($null -eq $Value){ return $null }
  if($Value -is [System.Management.Automation.PSCustomObject]){
    $d = [ordered]@{}
    foreach($p in @($Value.PSObject.Properties)){ $d[$p.Name] = (CC-ToOrderedTree $p.Value) }
    return $d
  }
  if(($Value -isnot [string]) -and ($Value -is [System.Collections.IEnumerable]) -and ($Value -isnot [System.Collections.IDictionary])){
    $l = New-Object System.Collections.Generic.List[object]
    foreach($x in $Value){ $l.Add((CC-ToOrderedTree $x)) }
    return ,($l.ToArray())
  }
  return $Value
}

function CC-HasProp($Obj,[string]$Name){ return ($null -ne $Obj) -and ($null -ne $Obj.PSObject.Properties[$Name]) }

# A string field that ConvertFrom-Json may have turned into DateTime on PowerShell 7.
function CC-StringField($Obj,[string]$Name){
  if(-not (CC-HasProp $Obj $Name)){ return $null }
  $v = $Obj.$Name
  if($null -eq $v){ return $null }
  if($v -is [DateTime]){ return $v.ToUniversalTime().ToString("o",[System.Globalization.CultureInfo]::InvariantCulture) }
  return [string]$v
}

function CC-RequireExactProps($Obj,[string[]]$Required,[string[]]$Optional,[string]$FailPrefix){
  if($null -eq $Obj -or $Obj -isnot [System.Management.Automation.PSCustomObject]){ CC-Fail ($FailPrefix + ":NOT_AN_OBJECT") }
  $names = @($Obj.PSObject.Properties | ForEach-Object { $_.Name })
  foreach($r in $Required){ if($names -notcontains $r){ CC-Fail ($FailPrefix + ":MISSING_FIELD:" + $r) } }
  foreach($n in $names){ if(($Required -notcontains $n) -and ($Optional -notcontains $n)){ CC-Fail ($FailPrefix + ":UNKNOWN_FIELD:" + $n) } }
}

function CC-HostExe(){ return ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) }
