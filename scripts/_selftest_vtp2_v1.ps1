param([Parameter(Mandatory=$true)][string]$RepoRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path $RepoRoot).Path
$Project = Join-Path $RepoRoot "src\Vtp2\Vtp2.csproj"
$Dll = Join-Path $RepoRoot "src\Vtp2\bin\Release\net10.0\vtp2.dll"
$Root = Join-Path $RepoRoot "runtime\vtp2_selftest"
if(Test-Path -LiteralPath $Root){ Remove-Item -LiteralPath $Root -Recurse -Force }
[void][IO.Directory]::CreateDirectory($Root)
if($null -eq (Get-Command dotnet -ErrorAction SilentlyContinue)){ throw "VTP2_SELFTEST_FAIL:DOTNET_SDK_NOT_FOUND" }
$IsWin = ($env:OS -eq "Windows_NT")

# Off Windows the state is sealed under an operator key file (no DPAPI). Create one for the
# test with owner-only permissions, and prove the tool refuses to run without it.
if(-not $IsWin){
  $KeyFile = Join-Path $Root "state.key"
  [IO.File]::WriteAllBytes($KeyFile,[Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
  & chmod 600 $KeyFile
  $env:VTP2_STATE_KEY_FILE = $KeyFile
}

& dotnet build $Project -c Release --nologo | Out-Host
if($LASTEXITCODE -ne 0){ throw "VTP2_SELFTEST_FAIL:BUILD" }

function Run([string[]]$A){ & dotnet $Dll @A | Out-Host; if($LASTEXITCODE -ne 0){throw ("VTP2_SELFTEST_FAIL:COMMAND:" + ($A -join ' '))} }
function Expect-Fail([string]$Token,[string[]]$A){
  $prior=$ErrorActionPreference;$ErrorActionPreference="Continue"
  $text=(& dotnet $Dll @A 2>&1 | Out-String); $code=$LASTEXITCODE
  $ErrorActionPreference=$prior
  if($code -eq 0){throw ("VTP2_SELFTEST_FAIL:EXPECTED_FAILURE:"+$Token)}
  if(-not $text.Contains($Token)){throw ("VTP2_SELFTEST_FAIL:WRONG_FAILURE:EXPECTED="+$Token+":ACTUAL="+$text)}
  Write-Host ("VTP2_NEGATIVE_OK:"+$Token)
}
function Fingerprint([string]$Bundle){$o=Get-Content -LiteralPath $Bundle -Raw|ConvertFrom-Json;$b=[Convert]::FromBase64String([string]$o.identity_sign_public_b64);$h=[Security.Cryptography.SHA256]::Create();try{return (($h.ComputeHash($b)|ForEach-Object{$_.ToString("x2")})-join "")}finally{$h.Dispose()}}
function Write-Raw([string]$Dest,[string]$Text){[IO.File]::WriteAllText($Dest,$Text,[Text.UTF8Encoding]::new($false))}
# PowerShell 7 ConvertFrom-Json rewrites ISO-8601 strings as DateTime values, which would change
# authenticated bytes on re-serialisation. Shield them so only the intended field changes.
function Mutate([string]$Source,[string]$Dest,[scriptblock]$Change){$raw=Get-Content -LiteralPath $Source -Raw;$raw=[regex]::Replace($raw,'"(\d{4}-\d\d-\d\dT[^"]*)"','"@@T@@$1"');$o=$raw|ConvertFrom-Json;& $Change $o;$json=($o|ConvertTo-Json -Depth 30 -Compress).Replace('@@T@@','');[IO.File]::WriteAllText($Dest,$json,[Text.UTF8Encoding]::new($false))}

Run @("kat")
$Alice=Join-Path $Root "alice.state"; $Bob=Join-Path $Root "bob.state"
$AB=Join-Path $Root "alice.bundle.json"; $BB=Join-Path $Root "bob.bundle.json"
Run @("init","--state",$Alice,"--device","alice-device")
Run @("init","--state",$Bob,"--device","bob-device")
Run @("bundle","--state",$Alice,"--out",$AB); Run @("bundle","--state",$Bob,"--out",$BB)
$AF=Fingerprint $AB; $BF=Fingerprint $BB
Expect-Fail "VTP2_FINGERPRINT_MISMATCH" @("trust","--state",$Alice,"--bundle",$BB,"--fingerprint",("0"*64))
Run @("trust","--state",$Alice,"--bundle",$BB,"--fingerprint",$BF); Run @("trust","--state",$Bob,"--bundle",$AB,"--fingerprint",$AF)

$Init=Join-Path $Root "session-init.json"; Run @("session-init","--state",$Alice,"--peer-bundle",$BB,"--out",$Init)
$Session=[string](Get-Content -LiteralPath $Init -Raw|ConvertFrom-Json).session_id
Run @("session-accept","--state",$Bob,"--request",$Init)
Expect-Fail "VTP2_SESSION_REPLAY" @("session-accept","--state",$Bob,"--request",$Init)

$messages=@(); for($i=0;$i -lt 3;$i++){
  $plain=Join-Path $Root ("plain-"+$i+".txt");$msg=Join-Path $Root ("message-"+$i+".json")
  [IO.File]::WriteAllText($plain,("secret-vtp2-value-"+$i),[Text.UTF8Encoding]::new($false))
  Run @("encrypt","--state",$Alice,"--session",$Session,"--in",$plain,"--out",$msg,"--content-type","text/plain");$messages+=$msg
}
foreach($i in @(2,0,1)){$out=Join-Path $Root ("out-"+$i+".txt");Run @("decrypt","--state",$Bob,"--in",$messages[$i],"--out",$out);if((Get-Content -LiteralPath $out -Raw)-ne("secret-vtp2-value-"+$i)){throw "VTP2_SELFTEST_FAIL:OUT_OF_ORDER_ROUNDTRIP"}}
Expect-Fail "VTP2_REPLAY_DETECTED" @("decrypt","--state",$Bob,"--in",$messages[0],"--out",(Join-Path $Root "replay.txt"))

$reply=Join-Path $Root "reply.txt";[IO.File]::WriteAllText($reply,"responder-secret",[Text.UTF8Encoding]::new($false));$replyMsg=Join-Path $Root "reply.json"
Run @("encrypt","--state",$Bob,"--session",$Session,"--in",$reply,"--out",$replyMsg);Run @("decrypt","--state",$Alice,"--in",$replyMsg,"--out",(Join-Path $Root "reply.out"))
if((Get-Content -LiteralPath (Join-Path $Root "reply.out") -Raw)-ne"responder-secret"){throw "VTP2_SELFTEST_FAIL:BIDIRECTIONAL"}

$freshPlain=Join-Path $Root "fresh.txt";[IO.File]::WriteAllText($freshPlain,"fresh-secret-for-tamper",[Text.UTF8Encoding]::new($false));$freshMsg=Join-Path $Root "fresh.json"
Run @("encrypt","--state",$Alice,"--session",$Session,"--in",$freshPlain,"--out",$freshMsg)
$tamper=Join-Path $Root "tamper.json";Mutate $freshMsg $tamper {param($o)$o.ciphertext_b64=[Convert]::ToBase64String([byte[]](1..32));$o.ciphertext_length=32}
Expect-Fail "VTP2_CRYPTOGRAPHIC_FAILURE" @("decrypt","--state",$Bob,"--in",$tamper,"--out",(Join-Path $Root "tamper.out"))
$wrong=Join-Path $Root "wrong-recipient.json";Mutate $replyMsg $wrong {param($o)$o.recipient_device_id="mallory-device"}
Expect-Fail "VTP2_MESSAGE_BINDING_MISMATCH" @("decrypt","--state",$Alice,"--in",$wrong,"--out",(Join-Path $Root "wrong.out"))
$badInit=Join-Path $Root "bad-init.json";Mutate $Init $badInit {param($o)$o.ephemeral_public_b64=[Convert]::ToBase64String([byte[]](1..20))}
Expect-Fail "VTP2_BAD_SIGNATURE" @("session-accept","--state",$Bob,"--request",$badInit)

$badBundle=Join-Path $Root "bad-bundle.json";Mutate $BB $badBundle {param($o)$o.device_id="attacker-device"}
Expect-Fail "VTP2_BAD_SIGNATURE" @("trust","--state",$Alice,"--bundle",$badBundle,"--fingerprint",$BF)
$BobReplacement=Join-Path $Root "bob-replacement.state";$BobReplacementBundle=Join-Path $Root "bob-replacement.bundle.json"
Run @("init","--state",$BobReplacement,"--device","bob-device");Run @("bundle","--state",$BobReplacement,"--out",$BobReplacementBundle)
Expect-Fail "VTP2_IDENTITY_CHANGED" @("trust","--state",$Alice,"--bundle",$BobReplacementBundle,"--fingerprint",(Fingerprint $BobReplacementBundle))

$skip=Join-Path $Root "skip.json";Mutate $freshMsg $skip {param($o)$o.message_number=1000}
Expect-Fail "VTP2_SKIP_LIMIT" @("decrypt","--state",$Bob,"--in",$skip,"--out",(Join-Path $Root "skip.out"))
$expired=Join-Path $Root "expired.json";Mutate $freshMsg $expired {param($o)$o.expires_utc="2000-01-01T00:00:00.0000000+00:00"}
Expect-Fail "VTP2_MESSAGE_EXPIRED" @("decrypt","--state",$Bob,"--in",$expired,"--out",(Join-Path $Root "expired.out"))
$oversize=Join-Path $Root "oversize.bin";[IO.File]::WriteAllBytes($oversize,(New-Object byte[] (768*1024+1)))
Expect-Fail "VTP2_INPUT_TOO_LARGE" @("encrypt","--state",$Alice,"--session",$Session,"--in",$oversize,"--out",(Join-Path $Root "oversize.json"))
# Largest allowed plaintext round-trips (its envelope must stay under the 1 MiB input limit).
$maxPlain=Join-Path $Root "max.bin";[IO.File]::WriteAllBytes($maxPlain,(New-Object byte[] (768*1024-4096)));$maxMsg=Join-Path $Root "max.json"
Run @("encrypt","--state",$Alice,"--session",$Session,"--in",$maxPlain,"--out",$maxMsg);Run @("decrypt","--state",$Bob,"--in",$maxMsg,"--out",(Join-Path $Root "max.out"))
if((Get-Item -LiteralPath (Join-Path $Root "max.out")).Length -ne (768*1024-4096)){throw "VTP2_SELFTEST_FAIL:MAX_SIZE_ROUNDTRIP"}
$hugeJson=Join-Path $Root "huge.json";[IO.File]::WriteAllBytes($hugeJson,(New-Object byte[] (1024*1024+1)))
Expect-Fail "VTP2_INPUT_TOO_LARGE" @("inspect","--in",$hugeJson)

$concurrentPlain=Join-Path $Root "concurrent.txt";[IO.File]::WriteAllText($concurrentPlain,"concurrent-secret",[Text.UTF8Encoding]::new($false));$jobs=@()
for($i=0;$i -lt 6;$i++){$out=Join-Path $Root ("concurrent-"+$i+".json");$jobs+=Start-Process -FilePath dotnet -ArgumentList @($Dll,"encrypt","--state",$Alice,"--session",$Session,"--in",$concurrentPlain,"--out",$out) -NoNewWindow -PassThru}
$jobs|ForEach-Object{$_.WaitForExit();if($_.ExitCode-ne 0){throw "VTP2_SELFTEST_FAIL:CONCURRENT_SEND"}}
$numbers=@(Get-ChildItem -LiteralPath $Root -Filter "concurrent-*.json"|ForEach-Object{[uint64](Get-Content -LiteralPath $_.FullName -Raw|ConvertFrom-Json).message_number})
if(@($numbers|Sort-Object -Unique).Count-ne 6){throw "VTP2_SELFTEST_FAIL:CONCURRENT_COUNTER_REUSE"}

$corrupt=Join-Path $Root "corrupt.state";[IO.File]::WriteAllBytes($corrupt,[IO.File]::ReadAllBytes($Alice));$bytes=[IO.File]::ReadAllBytes($corrupt);$bytes[10]=$bytes[10]-bxor 255;[IO.File]::WriteAllBytes($corrupt,$bytes)
Expect-Fail "VTP2_STATE_PROTECTION_FAILED" @("bundle","--state",$corrupt,"--out",(Join-Path $Root "corrupt.bundle"))

# --- Parser strictness: duplicate keys and unknown fields fail closed.
$freshText=Get-Content -LiteralPath $freshMsg -Raw
$dup=Join-Path $Root "duplicate-key.json";Write-Raw $dup ($freshText.TrimEnd().TrimEnd('}') + ',"session_id":"' + $Session + '"}')
Expect-Fail "VTP2_DUPLICATE_KEY" @("decrypt","--state",$Bob,"--in",$dup,"--out",(Join-Path $Root "dup.out"))
$unknown=Join-Path $Root "unknown-field.json";Mutate $freshMsg $unknown {param($o)$o|Add-Member -NotePropertyName "downgrade" -NotePropertyValue "v1"}
Expect-Fail "VTP2_UNKNOWN_FIELD:MESSAGE:downgrade" @("decrypt","--state",$Bob,"--in",$unknown,"--out",(Join-Path $Root "unknown.out"))
$badSuite=Join-Path $Root "bad-suite.json";Mutate $freshMsg $badSuite {param($o)$o.suite="VTP1-AES-CBC"}
Expect-Fail "VTP2_UNSUPPORTED_SUITE" @("decrypt","--state",$Bob,"--in",$badSuite,"--out",(Join-Path $Root "suite.out"))
$wrongType=Join-Path $Root "wrong-type.json";Mutate $freshMsg $wrongType {param($o)$o.message_number="7"}
Expect-Fail "VTP2_MISSING_FIELD:message_number" @("decrypt","--state",$Bob,"--in",$wrongType,"--out",(Join-Path $Root "type.out"))
$future=Join-Path $Root "future.json";Mutate $freshMsg $future {param($o)$o.created_utc="2999-01-01T00:00:00.0000000+00:00"}
Expect-Fail "VTP2_MESSAGE_FROM_FUTURE" @("decrypt","--state",$Bob,"--in",$future,"--out",(Join-Path $Root "future.out"))
$tagTamper=Join-Path $Root "tag-tamper.json";Mutate $freshMsg $tagTamper {param($o)$t=[Convert]::FromBase64String($o.tag_b64);$t[0]=$t[0]-bxor 1;$o.tag_b64=[Convert]::ToBase64String($t)}
Expect-Fail "VTP2_CRYPTOGRAPHIC_FAILURE" @("decrypt","--state",$Bob,"--in",$tagTamper,"--out",(Join-Path $Root "tag.out"))
$ctTamper=Join-Path $Root "content-type-tamper.json";Mutate $freshMsg $ctTamper {param($o)$o.content_type="text/html"}
Expect-Fail "VTP2_CRYPTOGRAPHIC_FAILURE" @("decrypt","--state",$Bob,"--in",$ctTamper,"--out",(Join-Path $Root "ct.out"))
# The untouched message still decrypts after all of the failed attempts (no state burned).
Run @("decrypt","--state",$Bob,"--in",$freshMsg,"--out",(Join-Path $Root "fresh.out"))
if((Get-Content -LiteralPath (Join-Path $Root "fresh.out") -Raw)-ne"fresh-secret-for-tamper"){throw "VTP2_SELFTEST_FAIL:STATE_BURNED_BY_REJECTED_INPUT"}

# --- Skipped-key budget is bounded in total, not just per gap.
$burst=@();for($i=0;$i -lt 60;$i++){$p=Join-Path $Root ("burst-"+$i+".json");Run @("encrypt","--state",$Alice,"--session",$Session,"--in",$freshPlain,"--out",$p);$burst+=$p}
Run @("decrypt","--state",$Bob,"--in",$burst[59],"--out",(Join-Path $Root "burst59.out"))
$more=@();for($i=0;$i -lt 60;$i++){$p=Join-Path $Root ("burst2-"+$i+".json");Run @("encrypt","--state",$Alice,"--session",$Session,"--in",$freshPlain,"--out",$p);$more+=$p}
Expect-Fail "VTP2_SKIP_LIMIT" @("decrypt","--state",$Bob,"--in",$more[59],"--out",(Join-Path $Root "burst-over.out"))
Run @("decrypt","--state",$Bob,"--in",$burst[10],"--out",(Join-Path $Root "burst10.out"))

# --- Bundle rotation, rollback and stale sequences.
$BobOld=Join-Path $Root "bob.bundle.seq1.json";Copy-Item -LiteralPath $BB -Destination $BobOld
Run @("rotate","--state",$Bob);$BB2=Join-Path $Root "bob.bundle.seq2.json";Run @("bundle","--state",$Bob,"--out",$BB2)
Run @("trust","--state",$Alice,"--bundle",$BB2,"--fingerprint",$BF)
Expect-Fail "VTP2_BUNDLE_ROLLBACK" @("trust","--state",$Alice,"--bundle",$BobOld,"--fingerprint",$BF)
$Init2=Join-Path $Root "session-init-2.json";Run @("session-init","--state",$Alice,"--peer-bundle",$BB2,"--out",$Init2)
Run @("session-accept","--state",$Bob,"--request",$Init2)
Run @("rotate","--state",$Bob);Run @("rotate","--state",$Bob)
$Carol=Join-Path $Root "carol.state";$CB=Join-Path $Root "carol.bundle.json";Run @("init","--state",$Carol,"--device","carol-device");Run @("bundle","--state",$Carol,"--out",$CB)
Run @("trust","--state",$Carol,"--bundle",$BB2,"--fingerprint",$BF);Run @("trust","--state",$Bob,"--bundle",$CB,"--fingerprint",(Fingerprint $CB))
$Init3=Join-Path $Root "session-init-stale.json";Run @("session-init","--state",$Carol,"--peer-bundle",$BB2,"--out",$Init3)
Expect-Fail "VTP2_STALE_BUNDLE_SEQUENCE" @("session-accept","--state",$Bob,"--request",$Init3)
Expect-Fail "VTP2_UNTRUSTED_IDENTITY" @("session-init","--state",$Carol,"--peer-bundle",$AB,"--out",(Join-Path $Root "carol-alice.json"))
$misdirected=Join-Path $Root "misdirected.json";Run @("session-init","--state",$Carol,"--peer-bundle",$BB2,"--out",$misdirected)
Expect-Fail "VTP2_WRONG_RECIPIENT" @("session-accept","--state",$Alice,"--request",$misdirected)

# --- Unknown bundle fields are rejected even when otherwise valid-looking.
$extraBundle=Join-Path $Root "extra-bundle.json";Mutate $BB2 $extraBundle {param($o)$o|Add-Member -NotePropertyName "note" -NotePropertyValue "x"}
Expect-Fail "VTP2_UNKNOWN_FIELD:BUNDLE:note" @("trust","--state",$Alice,"--bundle",$extraBundle,"--fingerprint",$BF)

# --- Off Windows: no key file, no state access.
if(-not $IsWin){
  $saved=$env:VTP2_STATE_KEY_FILE; Remove-Item Env:VTP2_STATE_KEY_FILE
  Expect-Fail "VTP2_STATE_KEY_REQUIRED" @("status","--state",$Alice)
  $open=Join-Path $Root "open.key";[IO.File]::WriteAllBytes($open,[IO.File]::ReadAllBytes($saved));& chmod 644 $open;$env:VTP2_STATE_KEY_FILE=$open
  Expect-Fail "VTP2_STATE_KEY_PERMISSIONS_TOO_OPEN" @("status","--state",$Alice)
  $wrong=Join-Path $Root "wrong.key";[IO.File]::WriteAllBytes($wrong,[Security.Cryptography.RandomNumberGenerator]::GetBytes(32));& chmod 600 $wrong;$env:VTP2_STATE_KEY_FILE=$wrong
  Expect-Fail "VTP2_STATE_PROTECTION_FAILED" @("status","--state",$Alice)
  $env:VTP2_STATE_KEY_FILE=$saved
  $mode=(& stat -c "%a" $Alice); if($mode -ne "600"){throw ("VTP2_SELFTEST_FAIL:STATE_FILE_MODE:"+$mode)}
}
Run @("status","--state",$Alice)

$jsonFiles=Get-ChildItem -LiteralPath $Root -Filter *.json
foreach($f in $jsonFiles){$t=Get-Content -LiteralPath $f.FullName -Raw;if($t.Contains("secret-vtp2-value") -or $t.Contains("responder-secret") -or $t.Contains("fresh-secret-for-tamper") -or $t.Contains("concurrent-secret")){throw ("VTP2_SELFTEST_FAIL:PLAINTEXT_LEAK:"+$f.Name)}}
foreach($st in @($Alice,$Bob,$Carol)){$statePrefix=[Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($st));if($statePrefix.Contains("SignPrivate") -or $statePrefix.Contains("-device")){throw "VTP2_SELFTEST_FAIL:STATE_NOT_PROTECTED"}}

Write-Host "VTP2_SELFTEST_OK"
