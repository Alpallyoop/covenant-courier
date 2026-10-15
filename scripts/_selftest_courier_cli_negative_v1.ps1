param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PSExe = ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$Cli   = Join-Path $RepoRoot "scripts\courier_cli_v1.ps1"
$NegRoot = Join-Path $RepoRoot "test_vectors\courier_v1\cli_negative"

$ComposeIn = Join-Path $RepoRoot "test_vectors\courier_v1\pipeline\compose.input.json"
$DictIn    = Join-Path $RepoRoot "policies\lexicon\default_dictionary_v1.json"
$WorkRoot  = Join-Path $NegRoot "run"
$ComposeOut= Join-Path $WorkRoot "message.composed.json"
$DictOut   = Join-Path $WorkRoot "dictionary.built.json"
$TokOut    = Join-Path $WorkRoot "message.tokenized.json"

function Fail([string]$Code){
  throw $Code
}

function Run-ChildCapture {
  param(
    [Parameter(Mandatory=$true)][string]$ArgumentString
  )

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $PSExe
  $psi.Arguments = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" {1}' -f $Cli, $ArgumentString)
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.CreateNoWindow = $true

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  [void]$p.Start()
  $stdout = $p.StandardOutput.ReadToEnd()
  $stderr = $p.StandardError.ReadToEnd()
  $p.WaitForExit()

  [pscustomobject]@{
    ExitCode = $p.ExitCode
    StdOut   = $stdout
    StdErr   = $stderr
    Text     = ($stdout + "`n" + $stderr)
  }
}

function Assert-FailToken {
  param(
    [Parameter(Mandatory=$true)][string]$CaseName,
    [Parameter(Mandatory=$true)][string]$Expected,
    [Parameter(Mandatory=$true)][pscustomobject]$Result
  )

  if($Result.ExitCode -eq 0){
    Fail ("COURIER_CLI_NEG_FAIL:" + $CaseName + ":UNEXPECTED_SUCCESS")
  }
  if($Result.Text -notmatch [regex]::Escape($Expected)){
    Fail ("COURIER_CLI_NEG_FAIL:" + $CaseName + ":WRONG_FAILURE_TOKEN:`n" + $Result.Text)
  }

  Write-Host ("COURIER_CLI_NEGATIVE_OK: " + $CaseName + " -> " + $Expected)
}

if(-not (Test-Path -LiteralPath $Cli)){
  Fail ("COURIER_CLI_NEG_FAIL:MISSING_CLI:" + $Cli)
}

if(Test-Path -LiteralPath $WorkRoot){
  Remove-Item -LiteralPath $WorkRoot -Recurse -Force
}
[void][System.IO.Directory]::CreateDirectory($WorkRoot)

# Build minimal valid artifacts for missing-signature case
& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $Cli `
  -RepoRoot $RepoRoot `
  -Command compose `
  -ComposePath $ComposeIn `
  -OutPath $ComposeOut
if($LASTEXITCODE -ne 0){ Fail ("COURIER_CLI_NEG_FAIL:SETUP_COMPOSE_EXIT_" + $LASTEXITCODE) }

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $Cli `
  -RepoRoot $RepoRoot `
  -Command build-dictionary `
  -DictionaryPath $DictIn `
  -OutPath $DictOut
if($LASTEXITCODE -ne 0){ Fail ("COURIER_CLI_NEG_FAIL:SETUP_BUILD_DICT_EXIT_" + $LASTEXITCODE) }

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $Cli `
  -RepoRoot $RepoRoot `
  -Command tokenize `
  -MessagePath $ComposeOut `
  -DictionaryPath $DictOut `
  -OutPath $TokOut `
  -Context internal
if($LASTEXITCODE -ne 0){ Fail ("COURIER_CLI_NEG_FAIL:SETUP_TOKENIZE_EXIT_" + $LASTEXITCODE) }

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $Cli `
  -RepoRoot $RepoRoot `
  -Command bootstrap-trust
if($LASTEXITCODE -ne 0){ Fail ("COURIER_CLI_NEG_FAIL:SETUP_BOOTSTRAP_EXIT_" + $LASTEXITCODE) }

# 1 unknown command
$r1 = Run-ChildCapture ('-RepoRoot "{0}" -Command bogus' -f $RepoRoot)
Assert-FailToken "unknown_command" "COURIER_CLI_FAIL:UNKNOWN_COMMAND:bogus" $r1

# 2 compose missing compose path
$r2 = Run-ChildCapture ('-RepoRoot "{0}" -Command compose -OutPath "{1}"' -f $RepoRoot, (Join-Path $NegRoot "out2.json"))
Assert-FailToken "compose_missing_composepath" "COURIER_CLI_FAIL:MISSING_COMPOSE_PATH" $r2

# 3 compose missing out path
$r3 = Run-ChildCapture ('-RepoRoot "{0}" -Command compose -ComposePath "{1}"' -f $RepoRoot, $ComposeIn)
Assert-FailToken "compose_missing_outpath" "COURIER_CLI_FAIL:MISSING_OUT_PATH" $r3

# 4 build-dictionary missing dictionary path
$r4 = Run-ChildCapture ('-RepoRoot "{0}" -Command build-dictionary -OutPath "{1}"' -f $RepoRoot, (Join-Path $NegRoot "dict4.json"))
Assert-FailToken "build_dictionary_missing_dictionarypath" "COURIER_CLI_FAIL:MISSING_DICTIONARY_PATH" $r4

# 5 tokenize missing message path
$r5 = Run-ChildCapture ('-RepoRoot "{0}" -Command tokenize -DictionaryPath "{1}" -OutPath "{2}"' -f $RepoRoot, $DictOut, (Join-Path $NegRoot "tok5.json"))
Assert-FailToken "tokenize_missing_messagepath" "COURIER_CLI_FAIL:MISSING_MESSAGE_PATH" $r5

# 6 decode missing dictionary path
$r6 = Run-ChildCapture ('-RepoRoot "{0}" -Command decode -MessagePath "{1}" -OutPath "{2}"' -f $RepoRoot, $TokOut, (Join-Path $NegRoot "dec6.json"))
Assert-FailToken "decode_missing_dictionarypath" "COURIER_CLI_FAIL:MISSING_DICTIONARY_PATH" $r6

# 7 run-pipeline missing workroot
$r7 = Run-ChildCapture ('-RepoRoot "{0}" -Command run-pipeline -ComposePath "{1}" -DictionaryPath "{2}"' -f $RepoRoot, $ComposeIn, $DictIn)
Assert-FailToken "run_pipeline_missing_workroot" "COURIER_CLI_FAIL:MISSING_WORKROOT" $r7

# 8 verify-signature missing signature
$sigPath = $TokOut + ".sig"
if(Test-Path -LiteralPath $sigPath){
  Remove-Item -LiteralPath $sigPath -Force
}

$r8 = Run-ChildCapture ('-RepoRoot "{0}" -Command verify-signature -MessagePath "{1}"' -f $RepoRoot, $TokOut)
Assert-FailToken "verify_signature_missing_signature" "COURIER_CLI_FAIL:STEP_EXIT_1:courier_verify_signature_v1.ps1" $r8
if($r8.Text -notmatch 'COURIER_VERIFY_FAIL:MISSING_SIGNATURE'){
  Fail ("COURIER_CLI_NEG_FAIL:verify_signature_missing_signature:INNER_TOKEN_MISSING:`n" + $r8.Text)
}
Write-Host "COURIER_CLI_NEGATIVE_OK: verify_signature_missing_signature -> COURIER_VERIFY_FAIL:MISSING_SIGNATURE"

Write-Host "COURIER_CLI_NEGATIVE_SUITE_OK"
