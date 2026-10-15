param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

# NeverLost trust-bundle import (courier_trust_import_neverlost_v1.ps1) in a sandbox root:
# pinned import, signature acceptance through the imported trust root, and refusals that still
# write a constellation.integration.receipt.v1.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_lib_constellation_integration_receipt_v1.ps1")

$RepoRoot = (Resolve-Path $RepoRoot).Path
$PS = CC-HostExe
$Run = Join-Path $RepoRoot ("runtime\selftest_trust_import\" + (CC-UtcStampId))
$Sandbox = Join-Path $Run "repo"
$NL = Join-Path $Run "neverlost"
CC-EnsureDir $Sandbox; CC-EnsureDir (Join-Path $NL "proofs\keys")
$Import = Join-Path $PSScriptRoot "courier_trust_import_neverlost_v1.ps1"
$Verify = Join-Path $PSScriptRoot "courier_verify_signature_v1.ps1"
$Cases = 0
function Must([bool]$c,[string]$code){ if(-not $c){ throw ("COURIER_TRUST_IMPORT_SELFTEST_FAIL:" + $code) } }
function Child([string]$Script,[string[]]$A){ $o = & $PS -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Script @A 2>&1; return @{ Code = $LASTEXITCODE; Text = ($o | Out-String) } }

$keygen = (Get-Command ssh-keygen -ErrorAction Stop).Source
if($env:WINDIR -and (Test-Path -LiteralPath (Join-Path $env:WINDIR "System32\OpenSSH\ssh-keygen.exe"))){ $keygen = Join-Path $env:WINDIR "System32\OpenSSH\ssh-keygen.exe" }
$key = Join-Path $NL "proofs\keys\courier_node_test_ed25519"
# Empty passphrase passed through an argument string: works the same on PowerShell 5.1 and 7.
$kp = Start-Process -FilePath $keygen -ArgumentList ('-q -t ed25519 -N "" -C "courier-node-test" -f "' + $key + '"') -Wait -PassThru -NoNewWindow
Must ($kp.ExitCode -eq 0) "KEYGEN_EXIT"
Must (Test-Path -LiteralPath ($key + ".pub")) "KEYGEN"
$pub = ([IO.File]::ReadAllText($key + ".pub")).Trim()
$principal = "single-tenant/device_agent/courier/node-test"

function Write-Bundle([string]$Path,[string]$Principal,[string]$PubSha){
  $b = [ordered]@{
    schema = "neverlost.trust_bundle.v1"; created_utc = "2026-10-15T00:00:00Z"
    principals = @([ordered]@{ principal = $Principal; keys = @([ordered]@{ key_id = "courier-node-test-ed25519"; alg = "ssh-ed25519"; pubkey_path = "proofs/keys/courier_node_test_ed25519.pub"; pubkey_sha256 = $PubSha; pubkey = $pub; namespaces = @("courier/message","covenant-gate/decision") }) })
  }
  [void](CC-WriteDocument $Path $b)
  return (CC-Sha256File $Path)
}
$pubSha = CC-Sha256File ($key + ".pub")
$bundle = Join-Path $NL "trust_bundle.json"
$bundleSha = Write-Bundle $bundle $principal $pubSha
$cir = Join-Path $Sandbox "proofs\integration_receipts\covenant-courier__neverlost\receipts.ndjson"

# Refusals first (nothing imported yet).
$r = Child $Import @("-RepoRoot",$Sandbox,"-TrustBundlePath",$bundle,"-ExpectedSha256",("0"*64))
Must ($r.Code -ne 0 -and $r.Text -match "TRUST_BUNDLE_PIN_MISMATCH") "PIN_MISMATCH"
Must (-not (Test-Path -LiteralPath (Join-Path $Sandbox "proofs\trust\neverlost\allowed_signers"))) "NOTHING_IMPORTED_ON_REFUSAL"
$last = @(Get-Content -LiteralPath $cir)[-1] | ConvertFrom-Json
Must ([string]$last.outcome -eq "refused" -and [string]$last.error_token -eq "TRUST_BUNDLE_PIN_MISMATCH" -and [string]$last.response_sha256 -eq $bundleSha) "PIN_MISMATCH_RECEIPT"
$Cases++; Write-Host "COURIER_TRUST_IMPORT_CASE_OK: pin-mismatch -> refused + integration receipt"

$badBundle = Join-Path $NL "bad_principal.json"
$badSha = Write-Bundle $badBundle "courier-local@covenant" $pubSha
$r = Child $Import @("-RepoRoot",$Sandbox,"-TrustBundlePath",$badBundle,"-ExpectedSha256",$badSha)
Must ($r.Code -ne 0 -and $r.Text -match "TRUST_BUNDLE_INVALID_PRINCIPAL_INVALID") "BAD_PRINCIPAL"
$Cases++; Write-Host "COURIER_TRUST_IMPORT_CASE_OK: principal-outside-neverlost-roles -> refused"

$wild = Join-Path $NL "wildcard_principal.json"
$wSha0 = Write-Bundle $wild "single-tenant/owner/x,*" $pubSha
$r = Child $Import @("-RepoRoot",$Sandbox,"-TrustBundlePath",$wild,"-ExpectedSha256",$wSha0)
Must ($r.Code -ne 0 -and $r.Text -match "TRUST_BUNDLE_INVALID_PRINCIPAL_INVALID") "WILDCARD_PRINCIPAL"
$Cases++; Write-Host "COURIER_TRUST_IMPORT_CASE_OK: wildcard-principal -> refused"

$wrongKeySha = Join-Path $NL "wrong_keysha.json"
$wSha = Write-Bundle $wrongKeySha $principal ("f"*64)
$r = Child $Import @("-RepoRoot",$Sandbox,"-TrustBundlePath",$wrongKeySha,"-ExpectedSha256",$wSha,"-NeverLostRoot",$NL)
Must ($r.Code -ne 0 -and $r.Text -match "PUBKEY_SHA256_MISMATCH") "KEY_FILE_HASH"
$Cases++; Write-Host "COURIER_TRUST_IMPORT_CASE_OK: key-file-hash-mismatch -> refused"

$r = Child $Import @("-RepoRoot",$Sandbox,"-TrustBundlePath",(Join-Path $NL "missing.json"),"-ExpectedSha256",$bundleSha)
Must ($r.Code -ne 0 -and $r.Text -match "TRUST_BUNDLE_MISSING") "MISSING_BUNDLE"
$last = @(Get-Content -LiteralPath $cir)[-1] | ConvertFrom-Json
Must ([string]$last.outcome -eq "unavailable") "MISSING_BUNDLE_RECEIPT"
$Cases++; Write-Host "COURIER_TRUST_IMPORT_CASE_OK: bundle-missing -> unavailable + integration receipt"

# Positive.
$r = Child $Import @("-RepoRoot",$Sandbox,"-TrustBundlePath",$bundle,"-ExpectedSha256",$bundleSha,"-NeverLostRoot",$NL)
Must ($r.Code -eq 0 -and $r.Text -match "COURIER_TRUST_IMPORT_OK") ("IMPORT:" + $r.Text)
$as = [IO.File]::ReadAllText((Join-Path $Sandbox "proofs\trust\neverlost\allowed_signers"))
$core = (($pub -split '\s+')[0..1] -join " ")
Must ($as -ceq ($principal + ' namespaces="courier/message,covenant-gate/decision" ' + $core + "`n")) "ALLOWED_SIGNERS_TEXT"
$Cases++; Write-Host "COURIER_TRUST_IMPORT_CASE_OK: pinned-import -> allowed_signers derived like NeverLost"

# A signature by the imported key verifies through the imported trust root, for that principal only.
$doc = Join-Path $Run "signed.json"
[IO.File]::WriteAllText($doc,'{"hello":"courier"}')
& $keygen -Y sign -f $key -n "courier/message" $doc 2>&1 | Out-Null
Must (Test-Path -LiteralPath ($doc + ".sig")) "SIGN"
$r = Child $Verify @("-RepoRoot",$Sandbox,"-MessagePath",$doc,"-SignerIdentity",$principal,"-Namespace","courier/message")
Must ($r.Code -eq 0 -and $r.Text -match "COURIER_SIGNATURE_VERIFY_OK") ("VERIFY_IMPORTED:" + $r.Text)
$r = Child $Verify @("-RepoRoot",$Sandbox,"-MessagePath",$doc,"-SignerIdentity","single-tenant/device_agent/courier/other","-Namespace","courier/message")
Must ($r.Code -ne 0 -and $r.Text -match "UNTRUSTED_SIGNER") "OTHER_PRINCIPAL_REFUSED"
$r = Child $Verify @("-RepoRoot",$Sandbox,"-MessagePath",$doc,"-SignerIdentity",$principal,"-Namespace","watchtower")
Must ($r.Code -ne 0) "WRONG_NAMESPACE_REFUSED"
$Cases++; Write-Host "COURIER_TRUST_IMPORT_CASE_OK: imported-signer-verifies; other principal and namespace refused"

$v = Test-ConstellationIntegrationReceiptFile -Path $cir
Must ($v.Count -eq 6) ("RECEIPT_COUNT:" + $v.Count)
Write-Host ("COURIER_TRUST_IMPORT_SELFTEST_CASES: " + $Cases)
Write-Host "COURIER_TRUST_IMPORT_SELFTEST_OK"
