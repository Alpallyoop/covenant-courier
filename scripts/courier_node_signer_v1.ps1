param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][ValidateSet("keygen","adopt","status")][string]$Action,
  [Parameter(Mandatory=$true)][string]$NodeId,
  # NeverLost principal for this node (proposal 0001 section 5 / Constellation INTEGRATION_WORK).
  [string]$Principal
)

# NeverLost-issued node signers.
#
#   keygen  create the node's ed25519 signing key for its NeverLost principal (default
#           single-tenant/device_agent/courier/<node-id>) and print the public key to issue in NeverLost
#           (namespace courier/message). The private key never leaves proofs/keys/.
#   adopt   after `courier.ps1 trust-import` of a NeverLost trust bundle that lists this principal with
#           this exact key and namespace courier/message, switch registry/nodes/<node-id>.json to the
#           NeverLost principal. Refuses when the import does not carry the key.
#   status  print the node's current principal and whether it is NeverLost-issued and imported.
#
# Tokens: COURIER_NODE_SIGNER_OK / COURIER_NODE_SIGNER_FAIL:<reason>.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_lib_covenant_courier_product_v1.ps1")

function Fail([string]$Reason){ throw ("COURIER_NODE_SIGNER_FAIL:" + $Reason) }

$RepoRoot = (Resolve-Path $RepoRoot).Path
if($NodeId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,71}\z' -or $NodeId.Contains("..")){ Fail "BAD_NODE_ID" }
if([string]::IsNullOrWhiteSpace($Principal)){ $Principal = "single-tenant/device_agent/courier/" + $NodeId }
# Same principal rules as the NeverLost trust import (no allowed_signers pattern characters).
if($Principal -cnotmatch '^single-tenant/device_agent/.+\z' -or $Principal -match '[\s",*?!]'){ Fail "BAD_PRINCIPAL" }

$nodePath = Join-Path $RepoRoot ("registry\nodes\" + $NodeId + ".json")
$safe = ($Principal -replace '[^A-Za-z0-9._-]','_')
$privKey = Join-Path $RepoRoot ("proofs\keys\courier_" + $safe + "_ed25519")
$pubKey = $privKey + ".pub"
$nlAllowed = Join-Path $RepoRoot "proofs\trust\neverlost\allowed_signers"

function KeyCore([string]$Line){
  $p = @($Line.Trim() -split '\s+')
  if($p.Count -lt 2 -or $p[0] -cne "ssh-ed25519"){ Fail "BAD_PUBLIC_KEY" }
  return ($p[0] + " " + $p[1])
}

# The NeverLost-imported allowed_signers line for this principal, or $null.
function ImportedLine([string]$Core){
  if(-not (Test-Path -LiteralPath $nlAllowed -PathType Leaf)){ return $null }
  foreach($l in ([IO.File]::ReadAllText($nlAllowed) -split "`n")){
    $l = $l.TrimEnd("`r")
    if($l -cmatch '^(\S+) namespaces="([^"]*)" (ssh-ed25519 \S+)\z'){
      if($Matches[1] -ceq $Principal -and $Matches[3] -ceq $Core -and (@($Matches[2] -split ',') -ccontains "courier/message")){ return $l }
    }
  }
  return $null
}

if($Action -eq "keygen"){
  if(-not (Test-Path -LiteralPath $pubKey -PathType Leaf)){
    if(Test-Path -LiteralPath $privKey){ Fail "PRIVATE_KEY_WITHOUT_PUBLIC_KEY" }
    CC-EnsureDir (Split-Path -Parent $privKey)
    $kg = $(if($env:WINDIR -and (Test-Path -LiteralPath (Join-Path $env:WINDIR "System32\OpenSSH\ssh-keygen.exe"))){ Join-Path $env:WINDIR "System32\OpenSSH\ssh-keygen.exe" } else { $c = Get-Command ssh-keygen -ErrorAction SilentlyContinue; if($null -eq $c){ Fail "SSH_KEYGEN_NOT_FOUND" }; $c.Source })
    # Start-Process with one argument string: Windows PowerShell 5.1 drops the empty -N "" otherwise.
    $proc = Start-Process -FilePath $kg -ArgumentList ('-q -t ed25519 -N "" -C "{0}" -f "{1}"' -f $Principal,$privKey) -Wait -PassThru -NoNewWindow
    if($proc.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $pubKey -PathType Leaf)){ Fail ("KEYGEN_EXIT_" + $proc.ExitCode) }
  }
  $core = KeyCore ([IO.File]::ReadAllText($pubKey))
  Write-Host ("COURIER_NODE_SIGNER_PRINCIPAL: " + $Principal)
  Write-Host ("COURIER_NODE_SIGNER_PUBLIC_KEY: " + $core)
  Write-Host ("COURIER_NODE_SIGNER_PUBLIC_KEY_PATH: " + $pubKey)
  Write-Host ("COURIER_NODE_SIGNER_PUBLIC_KEY_SHA256: " + (CC-Sha256File $pubKey))
  Write-Host "COURIER_NODE_SIGNER_NEXT: issue this key in NeverLost for the principal with namespace courier/message, publish the trust bundle, run courier.ps1 trust-import, then courier.ps1 node-signer -Action adopt"
  Write-Host "COURIER_NODE_SIGNER_OK"
  exit 0
}

if(-not (Test-Path -LiteralPath $nodePath -PathType Leaf)){ Fail "NODE_UNKNOWN" }
$node = CC-ReadJsonFile $nodePath
if([string]$node.schema -cne "courier.node_registry.v1" -or [string]$node.node_id -cne $NodeId){ Fail "NODE_RECORD_INVALID" }
$current = [string]$node.principal

if($Action -eq "status"){
  $imported = $false
  if(Test-Path -LiteralPath $pubKey -PathType Leaf){ $imported = ($null -ne (ImportedLine (KeyCore ([IO.File]::ReadAllText($pubKey))))) }
  Write-Host ("COURIER_NODE_SIGNER_CURRENT_PRINCIPAL: " + $current)
  Write-Host ("COURIER_NODE_SIGNER_NEVERLOST_PRINCIPAL: " + $Principal)
  Write-Host ("COURIER_NODE_SIGNER_KEY_PRESENT: " + [string](Test-Path -LiteralPath $privKey -PathType Leaf).ToString().ToLowerInvariant())
  Write-Host ("COURIER_NODE_SIGNER_IMPORTED: " + $imported.ToString().ToLowerInvariant())
  Write-Host ("COURIER_NODE_SIGNER_ADOPTED: " + ($current -ceq $Principal).ToString().ToLowerInvariant())
  Write-Host "COURIER_NODE_SIGNER_OK"
  exit 0
}

# adopt
if(-not (Test-Path -LiteralPath $privKey -PathType Leaf) -or -not (Test-Path -LiteralPath $pubKey -PathType Leaf)){ Fail "KEY_MISSING" }
$core = KeyCore ([IO.File]::ReadAllText($pubKey))
if($null -eq (ImportedLine $core)){ Fail "NOT_IMPORTED" }
if(@($node.allowed_namespaces) -cnotcontains "courier/message"){ Fail "NODE_NAMESPACE_MISSING" }
$rec = [ordered]@{}
foreach($p in $node.PSObject.Properties){ $rec[$p.Name] = $p.Value }
$rec["principal"] = $Principal
[IO.File]::WriteAllText($nodePath, (($rec | ConvertTo-Json -Depth 20 -Compress) + [string][char]10), (CC-Utf8NoBom))
Write-Host ("COURIER_NODE_SIGNER_PREVIOUS_PRINCIPAL: " + $current)
Write-Host ("COURIER_NODE_SIGNER_ADOPTED: " + $Principal)
Write-Host "COURIER_NODE_SIGNER_OK"
exit 0
