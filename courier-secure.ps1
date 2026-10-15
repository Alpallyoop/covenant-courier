param(
  [Parameter(Position=0,Mandatory=$true)][ValidateSet("init","bundle","trust","connect","accept","send","receive","inspect","verify")][string]$Command,
  [string]$State,
  [string]$Device,
  [string]$Bundle,
  [string]$PeerBundle,
  [string]$Fingerprint,
  [string]$Session,
  [string]$InputPath,
  [string]$OutputPath,
  [string]$ContentType = "application/octet-stream"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$Vtp = Join-Path $PSScriptRoot "vtp2.ps1"
function Need([string]$Value,[string]$Name){if([string]::IsNullOrWhiteSpace($Value)){throw ("COURIER_SECURE_MISSING:"+$Name)}}

switch($Command){
  "init" { Need $State "State";Need $Device "Device";& $Vtp init --state $State --device $Device }
  "bundle" { Need $State "State";Need $OutputPath "OutputPath";& $Vtp bundle --state $State --out $OutputPath }
  "trust" { Need $State "State";Need $Bundle "Bundle";Need $Fingerprint "Fingerprint";& $Vtp trust --state $State --bundle $Bundle --fingerprint $Fingerprint }
  "connect" { Need $State "State";Need $PeerBundle "PeerBundle";Need $OutputPath "OutputPath";& $Vtp session-init --state $State --peer-bundle $PeerBundle --out $OutputPath }
  "accept" { Need $State "State";Need $InputPath "InputPath";& $Vtp session-accept --state $State --request $InputPath }
  "send" { Need $State "State";Need $Session "Session";Need $InputPath "InputPath";Need $OutputPath "OutputPath";& $Vtp encrypt --state $State --session $Session --in $InputPath --out $OutputPath --content-type $ContentType }
  "receive" { Need $State "State";Need $InputPath "InputPath";Need $OutputPath "OutputPath";& $Vtp decrypt --state $State --in $InputPath --out $OutputPath }
  "inspect" { Need $InputPath "InputPath";& $Vtp inspect --in $InputPath }
  "verify" { & $Vtp verify }
}
exit $LASTEXITCODE
