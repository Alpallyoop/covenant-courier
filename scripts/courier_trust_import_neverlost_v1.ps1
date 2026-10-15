param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$TrustBundlePath,
  # SHA-256 of the trust bundle file as NeverLost reports it (verify_trust_bundle_v1.ps1 prints
  # TRUST_BUNDLE_SHA256=...). Compared out of band: Courier does not trust a bundle it was not told to.
  [Parameter(Mandatory=$true)][string]$ExpectedSha256,
  # Optional NeverLost checkout: when given, pubkey_sha256 is recomputed over the key files exactly
  # as NeverLost does (bytes of pubkey_path) and the key text is compared.
  [string]$NeverLostRoot
)

# Imports signer identities from a NeverLost neverlost.trust_bundle.v1 (principals form) into
# Courier's third trust root, proofs/trust/neverlost/allowed_signers. The verifier
# (courier_verify_signature_v1.ps1) accepts a signature that verifies against any trust root for
# the expected identity and namespace. The allowed_signers text is derived the same way NeverLost
# derives its own (principal namespaces="<ordinal-sorted>" <type> <base64>, lines sorted ordinally).
# Every import, refused or not, writes a constellation.integration.receipt.v1
# (covenant-courier > neverlost, contract neverlost.trust_bundle.v1).

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_lib_covenant_courier_product_v1.ps1")
. (Join-Path $PSScriptRoot "_lib_constellation_integration_receipt_v1.ps1")

$RepoRoot = (Resolve-Path $RepoRoot).Path
$OutDir = Join-Path $RepoRoot "proofs\trust\neverlost"
$Contract = "neverlost.trust_bundle.v1"

function Refuse([string]$Outcome,[string]$Token,$ResponseSha){
  [void](Write-ConstellationIntegrationReceipt -RepoRoot $RepoRoot -Consumer "covenant-courier" -Provider "neverlost" -Contract $Contract -RequestSha256 $null -ResponseSha256 $ResponseSha -Outcome $Outcome -ErrorToken $Token)
  throw ("COURIER_TRUST_IMPORT_FAIL:" + $Token)
}

if(-not (Test-Path -LiteralPath $TrustBundlePath -PathType Leaf)){ Refuse "unavailable" "TRUST_BUNDLE_MISSING" $null }
$bundleSha = CC-Sha256File $TrustBundlePath
if($ExpectedSha256.ToLowerInvariant() -cne $bundleSha){ Refuse "refused" "TRUST_BUNDLE_PIN_MISMATCH" $bundleSha }

$lines = New-Object System.Collections.Generic.List[string]
try {
  $b = CC-ReadJsonFile $TrustBundlePath
  CC-RequireExactProps $b @("schema","principals") @("created_utc") "BUNDLE"
  if([string]$b.schema -cne "neverlost.trust_bundle.v1"){ throw "BUNDLE_BAD_SCHEMA" }
  $principals = @($b.principals)
  if($principals.Count -lt 1){ throw "BUNDLE_NO_PRINCIPALS" }
  $seenKeys = @{}
  foreach($p in $principals){
    CC-RequireExactProps $p @("principal","keys") @("namespaces") "PRINCIPAL"
    $principal = [string]$p.principal
    if($principal -cnotmatch '^single-tenant/(owner|org_admin|device_admin|operator|auditor|device_agent|watchtower_authority)/.+\z'){ throw "PRINCIPAL_INVALID" }
    # allowed_signers treats , * ? ! as pattern-list syntax: a principal or namespace containing them
    # could match identities it was never issued for.
    if($principal -match '[\s",*?!]'){ throw "PRINCIPAL_INVALID" }
    $pns = @(); if(CC-HasProp $p "namespaces"){ $pns = @($p.namespaces | ForEach-Object { [string]$_ }) }
    $keys = @($p.keys)
    if($keys.Count -lt 1){ throw "KEYS_EMPTY" }
    foreach($k in $keys){
      CC-RequireExactProps $k @("key_id","alg","pubkey_path","pubkey_sha256","pubkey") @("namespaces") "KEY"
      if([string]$k.alg -cne "ssh-ed25519"){ throw "ALG_UNSUPPORTED" }
      if($seenKeys.ContainsKey([string]$k.key_id)){ throw "KEY_ID_DUPLICATE" }
      $seenKeys[[string]$k.key_id] = $true
      if([string]$k.pubkey_sha256 -cnotmatch '^[a-f0-9]{64}$'){ throw "PUBKEY_SHA256_INVALID" }
      $parts = @(([string]$k.pubkey).Trim() -split '\s+')
      if($parts.Count -lt 2 -or $parts[0] -cne "ssh-ed25519" -or $parts[1] -cnotmatch '^[A-Za-z0-9+/]+={0,2}$'){ throw "PUBKEY_INVALID" }
      $core = $parts[0] + " " + $parts[1]
      if(-not [string]::IsNullOrWhiteSpace($NeverLostRoot)){
        $kp = Join-Path $NeverLostRoot ([string]$k.pubkey_path)
        if(-not (Test-Path -LiteralPath $kp -PathType Leaf)){ throw "PUBKEY_FILE_MISSING" }
        if((CC-Sha256File $kp) -cne [string]$k.pubkey_sha256){ throw "PUBKEY_SHA256_MISMATCH" }
        $fileParts = @(([System.IO.File]::ReadAllText($kp)).Trim() -split '\s+')
        if(($fileParts[0] + " " + $fileParts[1]) -cne $core){ throw "PUBKEY_FILE_MISMATCH" }
      }
      $kns = @(); if(CC-HasProp $k "namespaces"){ $kns = @($k.namespaces | ForEach-Object { [string]$_ }) }
      $all = @{}
      foreach($n in @($pns) + @($kns)){ if(-not [string]::IsNullOrWhiteSpace($n)){ if($n -match '[\s",*?!]'){ throw "NAMESPACE_INVALID" }; $all[$n] = $true } }
      if($all.Count -lt 1){ throw "NAMESPACES_MISSING" }
      $ns = [string[]]@($all.get_Keys()); [Array]::Sort($ns,[StringComparer]::Ordinal)
      $lines.Add($principal + ' namespaces="' + ($ns -join ",") + '" ' + $core)
    }
  }
} catch {
  $tok = ([string]$_.Exception.Message).ToUpperInvariant() -creplace '[^A-Z0-9_]','_'
  Refuse "refused" ("TRUST_BUNDLE_INVALID_" + $tok) $bundleSha
}

$arr = [string[]]$lines.ToArray(); [Array]::Sort($arr,[StringComparer]::Ordinal)
$text = (($arr -join "`n") + "`n")
CC-EnsureDir $OutDir
CC-WriteTextFile (Join-Path $OutDir "allowed_signers") $text
[System.IO.File]::Copy($TrustBundlePath,(Join-Path $OutDir "trust_bundle.json"),$true)
$record = [ordered]@{
  schema = "covenant_courier.trust_import.v1"
  source = "neverlost"
  contract = $Contract
  trust_bundle_sha256 = $bundleSha
  allowed_signers_sha256 = (CC-Sha256Text $text)
  signer_lines = [int64]$arr.Length
  key_files_checked = (-not [string]::IsNullOrWhiteSpace($NeverLostRoot))
  imported_utc = (CC-UtcNow)
}
[void](CC-WriteDocument (Join-Path $OutDir "import.json") $record)
$rc = Write-ConstellationIntegrationReceipt -RepoRoot $RepoRoot -Consumer "covenant-courier" -Provider "neverlost" -Contract $Contract -RequestSha256 $null -ResponseSha256 $bundleSha -Outcome "ok" -ErrorToken $null

Write-Host ("COURIER_TRUST_IMPORT_SIGNERS: " + $arr.Length)
Write-Host ("COURIER_TRUST_IMPORT_ALLOWED_SIGNERS: " + (Join-Path $OutDir "allowed_signers"))
Write-Host ("COURIER_TRUST_IMPORT_INTEGRATION_RECEIPT: " + $rc.Sha256)
Write-Host "COURIER_TRUST_IMPORT_OK"
