param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

# constellation.integration.receipt.v1 emitter/verifier (Constellation proposal 0013).
# Runs in a sandbox root so no test receipt reaches this machine's real evidence.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_lib_constellation_integration_receipt_v1.ps1")

$RepoRoot = (Resolve-Path $RepoRoot).Path
$Sandbox = Join-Path $RepoRoot ("runtime\selftest_integration_receipts\" + (CC-UtcStampId))
CC-EnsureDir $Sandbox
$Cases = 0
function Must([bool]$c,[string]$code){ if(-not $c){ throw ("CIR_SELFTEST_FAIL:" + $code) } }
function MustThrow([scriptblock]$b,[string]$like,[string]$name){
  $msg = $null
  try { & $b } catch { $msg = [string]$_.Exception.Message }
  if($null -eq $msg -or $msg -notlike $like){ throw ("CIR_SELFTEST_FAIL:" + $name + ":" + $msg) }
  $script:Cases++; Write-Host ("CIR_SELFTEST_CASE_OK: " + $name + " -> " + $msg)
}

$req = CC-Sha256Text "request"
$resp = CC-Sha256Text "response"

# Positive: ok, failed and carried receipts chain and verify.
$a = Write-ConstellationIntegrationReceipt -RepoRoot $Sandbox -Consumer "covenant-courier" -Provider "covenant-gate" -Contract "covenantgate.eval_output.v1" -RequestSha256 $req -ResponseSha256 $resp -Outcome "ok"
$b = Write-ConstellationIntegrationReceipt -RepoRoot $Sandbox -Consumer "covenant-courier" -Provider "covenant-gate" -Contract "covenantgate.eval_output.v1" -RequestSha256 $req -Outcome "unavailable" -ErrorToken "COVENANT_GATE_UNAVAILABLE"
$c = Write-ConstellationIntegrationReceipt -RepoRoot $Sandbox -Consumer "covenant-courier" -Provider "covenant-gate" -Contract "covenantgate.eval_output.v1" -RequestSha256 $req -ResponseSha256 $resp -Carried @([ordered]@{ contract = "policy.decision.v1"; sha256 = $resp }) -Outcome "refused" -ErrorToken "CG_INPUT_HASH_MISMATCH"

$expected0 = '{"schema":"constellation.integration.receipt.v1","consumer":"covenant-courier","provider":"covenant-gate","emitted_by":"consumer","contract":"covenantgate.eval_output.v1","request_sha256":"' + $req + '","response_sha256":"' + $resp + '","carried":[],"outcome":"ok","error_token":null,"prev_sha256":"' + ("0"*64) + '"}'
Must ($a.Line -ceq $expected0) "EXACT_FIRST_LINE"
Must ($a.Sha256 -ceq (CC-Sha256Text $expected0)) "HASH_IS_LINE_WITHOUT_LF"
Must ($b.Line.Contains('"prev_sha256":"' + $a.Sha256 + '"')) "CHAIN_LINK_1"
Must ($c.Line.Contains('"prev_sha256":"' + $b.Sha256 + '"')) "CHAIN_LINK_2"
Must ($a.Label -ceq "constellation.integration.receipt.v1:covenant-courier>covenant-gate") "NFL_LABEL"
$v = Test-ConstellationIntegrationReceiptFile -Path $a.Path
Must ($v.Count -eq 3 -and $v.Head -ceq $c.Sha256) "VERIFY_CLEAN"
$Cases++; Write-Host "CIR_SELFTEST_CASE_OK: write-ok-failed-carried -> chain verified"

# Emission refuses to write an invalid receipt.
MustThrow { Write-ConstellationIntegrationReceipt -RepoRoot $Sandbox -Consumer "covenant-courier" -Provider "x" -Contract "c.v1" -Outcome "ok" -ErrorToken "SHOULD_BE_NULL" } "CIR_INVALID:error_token_must_be_null_when_ok" "ok-with-token"
MustThrow { Write-ConstellationIntegrationReceipt -RepoRoot $Sandbox -Consumer "covenant-courier" -Provider "x" -Contract "c.v1" -Outcome "failed" } "CIR_INVALID:error_token" "failed-without-token"
MustThrow { Write-ConstellationIntegrationReceipt -RepoRoot $Sandbox -Consumer "covenant-courier" -Provider "x" -Contract "c.v1" -Outcome "failed" -ErrorToken "lower_case" } "CIR_INVALID:error_token" "bad-token-pattern"
MustThrow { Write-ConstellationIntegrationReceipt -RepoRoot $Sandbox -Consumer "Covenant-Courier" -Provider "x" -Contract "c.v1" -Outcome "ok" } "CIR_INVALID:consumer" "bad-service-id"
MustThrow { Write-ConstellationIntegrationReceipt -RepoRoot $Sandbox -Consumer "covenant-courier" -Provider "x" -Contract "unversioned" -Outcome "ok" } "CIR_INVALID:contract" "unversioned-contract"
MustThrow { Write-ConstellationIntegrationReceipt -RepoRoot $Sandbox -Consumer "covenant-courier" -Provider "x" -Contract "c.v1" -RequestSha256 "ABC" -Outcome "ok" } "CIR_INVALID:request_sha256" "bad-request-hash"
MustThrow { Write-ConstellationIntegrationReceipt -RepoRoot $Sandbox -Consumer "covenant-courier" -Provider "x" -Contract "c.v1" -Outcome "maybe" -ErrorToken "X" } "CIR_INVALID:outcome" "bad-outcome"

# Verification catches edits, reordering, truncation and non-canonical bytes.
function Variant([string]$name,[scriptblock]$mutate){
  $p = Join-Path $Sandbox ("variant-" + $name + ".ndjson")
  $t = [IO.File]::ReadAllText($a.Path)
  [IO.File]::WriteAllText($p,(& $mutate $t),(CC-Utf8NoBom))
  return $p
}
$p = Variant "edit" { param($t) $t.Replace('"outcome":"unavailable"','"outcome":"deferred"') }
MustThrow { Test-ConstellationIntegrationReceiptFile -Path $p } "CIR_VERIFY_FAIL:CHAIN_BROKEN:2" "edited-line"
$p = Variant "reorder" { param($t) $l = $t.TrimEnd("`n").Split("`n"); (($l[1],$l[0],$l[2]) -join "`n") + "`n" }
MustThrow { Test-ConstellationIntegrationReceiptFile -Path $p } "CIR_VERIFY_FAIL:CHAIN_BROKEN:0" "reordered-lines"
$p = Variant "truncate" { param($t) $t.Substring(0,$t.Length-5) }
MustThrow { Test-ConstellationIntegrationReceiptFile -Path $p } "CIR_VERIFY_FAIL:TRUNCATED_LAST_LINE" "truncated"
$p = Variant "spaces" { param($t) $l = $t.TrimEnd("`n").Split("`n"); $l[0] = $l[0].Replace('","consumer"','", "consumer"'); ($l -join "`n") + "`n" }
MustThrow { Test-ConstellationIntegrationReceiptFile -Path $p } "CIR_VERIFY_FAIL:NOT_CANONICAL:0" "insignificant-whitespace"
$p = Variant "crlf" { param($t) $t.Replace("`n","`r`n") }
MustThrow { Test-ConstellationIntegrationReceiptFile -Path $p } "CIR_VERIFY_FAIL:CR_NOT_ALLOWED" "crlf"
$p = Variant "keyorder" { param($t) $l = $t.TrimEnd("`n").Split("`n"); $l[0] = $l[0].Replace('"consumer":"covenant-courier","provider":"covenant-gate"','"provider":"covenant-gate","consumer":"covenant-courier"'); ($l -join "`n") + "`n" }
MustThrow { Test-ConstellationIntegrationReceiptFile -Path $p } "CIR_VERIFY_FAIL:KEY_ORDER:0" "key-order"

Write-Host ("CIR_SELFTEST_CASES: " + $Cases)
Write-Host "CONSTELLATION_INTEGRATION_RECEIPTS_SELFTEST_OK"
