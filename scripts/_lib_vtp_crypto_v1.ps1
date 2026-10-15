Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Dir([string]$Path){
  if(-not (Test-Path -LiteralPath $Path)){ [void][System.IO.Directory]::CreateDirectory($Path) }
}

function Write-Utf8NoBomLf([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path
  if($dir){ Ensure-Dir $dir }
  $t = ($Text -replace "`r`n","`n") -replace "`r","`n"
  if(-not $t.EndsWith("`n")){ $t += "`n" }
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path,$t,$enc)
}

function Get-Sha256HexBytes([byte[]]$Bytes){
  $sha=[System.Security.Cryptography.SHA256]::Create()
  try { $h=$sha.ComputeHash($Bytes) } finally { $sha.Dispose() }
  return (($h | ForEach-Object { $_.ToString("x2") }) -join "")
}

function Get-Sha256HexFile([string]$Path){
  $sha=[System.Security.Cryptography.SHA256]::Create()
  $fs=[System.IO.File]::OpenRead($Path)
  try { $h=$sha.ComputeHash($fs) } finally { $fs.Dispose(); $sha.Dispose() }
  return (($h | ForEach-Object { $_.ToString("x2") }) -join "")
}

function New-RandomBytes([int]$Count){
  $b = New-Object byte[] $Count
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  try { $rng.GetBytes($b) } finally { $rng.Dispose() }
  return $b
}

function Derive-KeyFromJoinCode([string]$JoinCode,[byte[]]$Salt){
  if([string]::IsNullOrWhiteSpace($JoinCode)){ throw "VTP_KDF_FAIL:MISSING_SECRET" }
  if($null -eq $Salt -or $Salt.Length -lt 16){ throw "VTP_KDF_FAIL:SALT_TOO_SHORT" }
  # Select SHA-256 explicitly. The three-argument constructor silently uses
  # PBKDF2-HMAC-SHA1 on Windows PowerShell/.NET Framework.
  $kdf = [System.Security.Cryptography.Rfc2898DeriveBytes]::new(
    $JoinCode,
    $Salt,
    200000,
    [System.Security.Cryptography.HashAlgorithmName]::SHA256
  )
  try { return $kdf.GetBytes(64) } finally { $kdf.Dispose() }
}

function Protect-BytesAesCbcHmacSha256([byte[]]$Plain,[byte[]]$Key,[byte[]]$Iv,[byte[]]$Aad){
  if($null -eq $Key -or $Key.Length -ne 64){ throw "VTP_CRYPTO_FAIL:KEY_MUST_BE_64_BYTES" }
  if($null -eq $Iv -or $Iv.Length -ne 16){ throw "VTP_CRYPTO_FAIL:IV_MUST_BE_16_BYTES" }
  if($null -eq $Aad){ $Aad = New-Object byte[] 0 }
  $encKey = New-Object byte[] 32
  $macKey = New-Object byte[] 32
  [Array]::Copy($Key,0,$encKey,0,32)
  [Array]::Copy($Key,32,$macKey,0,32)

  $aes = [System.Security.Cryptography.Aes]::Create()
  $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
  $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
  $aes.KeySize = 256
  $aes.Key = $encKey
  $aes.IV = $Iv

  try {
    $encryptor = $aes.CreateEncryptor()
    try {
      $cipher = $encryptor.TransformFinalBlock($Plain,0,$Plain.Length)
    }
    finally { $encryptor.Dispose() }
  }
  finally { $aes.Dispose() }

  $macInput = New-Object byte[] ($Aad.Length + $Iv.Length + $cipher.Length)
  [Array]::Copy($Aad,0,$macInput,0,$Aad.Length)
  [Array]::Copy($Iv,0,$macInput,$Aad.Length,$Iv.Length)
  [Array]::Copy($cipher,0,$macInput,($Aad.Length+$Iv.Length),$cipher.Length)

  $hmac = [System.Security.Cryptography.HMACSHA256]::new($macKey)
  try { $tag = $hmac.ComputeHash($macInput) } finally { $hmac.Dispose() }

  return @{ cipher=$cipher; tag=$tag }
}

function Unprotect-BytesAesCbcHmacSha256([byte[]]$Cipher,[byte[]]$Key,[byte[]]$Iv,[byte[]]$Tag,[byte[]]$Aad){
  if($null -eq $Key -or $Key.Length -ne 64){ throw "VTP_CRYPTO_FAIL:KEY_MUST_BE_64_BYTES" }
  if($null -eq $Iv -or $Iv.Length -ne 16){ throw "VTP_CRYPTO_FAIL:IV_MUST_BE_16_BYTES" }
  if($null -eq $Tag -or $Tag.Length -ne 32){ throw "AUTH_TAG_MISMATCH" }
  if($null -eq $Aad){ $Aad = New-Object byte[] 0 }
  $encKey = New-Object byte[] 32
  $macKey = New-Object byte[] 32
  [Array]::Copy($Key,0,$encKey,0,32)
  [Array]::Copy($Key,32,$macKey,0,32)

  $macInput = New-Object byte[] ($Aad.Length + $Iv.Length + $Cipher.Length)
  [Array]::Copy($Aad,0,$macInput,0,$Aad.Length)
  [Array]::Copy($Iv,0,$macInput,$Aad.Length,$Iv.Length)
  [Array]::Copy($Cipher,0,$macInput,($Aad.Length+$Iv.Length),$Cipher.Length)

  $hmac = [System.Security.Cryptography.HMACSHA256]::new($macKey)
  try { $actualTag = $hmac.ComputeHash($macInput) } finally { $hmac.Dispose() }

  if($actualTag.Length -ne $Tag.Length){ throw "AUTH_TAG_MISMATCH" }
  $diff = 0
  for($i=0; $i -lt $actualTag.Length; $i++){
    $diff = $diff -bor ($actualTag[$i] -bxor $Tag[$i])
  }
  if($diff -ne 0){ throw "AUTH_TAG_MISMATCH" }

  $aes = [System.Security.Cryptography.Aes]::Create()
  $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
  $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
  $aes.KeySize = 256
  $aes.Key = $encKey
  $aes.IV = $Iv

  try {
    $decryptor = $aes.CreateDecryptor()
    try {
      return $decryptor.TransformFinalBlock($Cipher,0,$Cipher.Length)
    }
    finally { $decryptor.Dispose() }
  }
  finally { $aes.Dispose() }
}

# Compatibility wrappers for existing callers. These names are deprecated and
# intentionally route to the accurately named construction above.
function Protect-BytesAesGcm([byte[]]$Plain,[byte[]]$Key,[byte[]]$Nonce,[byte[]]$Aad){
  return Protect-BytesAesCbcHmacSha256 $Plain $Key $Nonce $Aad
}
function Unprotect-BytesAesGcm([byte[]]$Cipher,[byte[]]$Key,[byte[]]$Nonce,[byte[]]$Tag,[byte[]]$Aad){
  return Unprotect-BytesAesCbcHmacSha256 $Cipher $Key $Nonce $Tag $Aad
}
