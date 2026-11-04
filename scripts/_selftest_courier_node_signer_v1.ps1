param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

# NeverLost-issued node signers (courier_node_signer_v1.ps1) in a sandbox root: keygen for the node's
# NeverLost principal, adopt refused before the trust import carries the key (and for a different key),
# adopt after a pinned import, then a governed delivery signed by the NeverLost principal verifies and
# is received.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_lib_covenant_courier_product_v1.ps1")

$RepoRoot = (Resolve-Path $RepoRoot).Path
$PS = CC-HostExe
$Run = Join-Path $RepoRoot ("runtime\selftest_node_signer\" + (CC-UtcStampId))
$Sandbox = Join-Path $Run "repo"
$NL = Join-Path $Run "neverlost"
CC-EnsureDir $Sandbox; CC-EnsureDir (Join-Path $NL "proofs\keys")
$Signer = Join-Path $PSScriptRoot "courier_node_signer_v1.ps1"
$Cases = 0
function Must([bool]$c,[string]$code){ if(-not $c){ throw ("COURIER_NODE_SIGNER_SELFTEST_FAIL:" + $code) } }
# Continue around the child: Windows PowerShell 5.1 turns redirected child stderr into a terminating error under Stop.
function Child([string]$Script,[string[]]$A){ $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"; try { $o = & $PS -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Script @A 2>&1; $c = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }; return @{ Code = $c; Text = ($o | Out-String) } }
function S([string]$Name){ return (Join-Path $PSScriptRoot $Name) }
function Bundle([string]$Path,[string]$Principal,[string]$PubPath){
  $pub = ([IO.File]::ReadAllText($PubPath)).Trim()
  $b = [ordered]@{
    schema = "neverlost.trust_bundle.v1"; created_utc = "2026-11-01T00:00:00Z"
    principals = @([ordered]@{ principal = $Principal; keys = @([ordered]@{ key_id = "courier-node-ed25519"; alg = "ssh-ed25519"; pubkey_path = ("proofs/keys/" + (Split-Path -Leaf $PubPath)); pubkey_sha256 = (CC-Sha256File $PubPath); pubkey = $pub; namespaces = @("courier/message") }) })
  }
  [void](CC-WriteDocument $Path $b)
  return (CC-Sha256File $Path)
}

# The sandbox is a copy of this repository's code and policy without its runtime state (receive runs
# the node loop from the data root).
foreach($it in @(Get-ChildItem -LiteralPath $RepoRoot -Force)){
  if(@(".git","runtime","proofs","registry","src","release","dist") -contains $it.Name){ continue }
  Copy-Item -LiteralPath $it.FullName -Destination $Sandbox -Recurse -Force
}
$r = Child (S "courier_seed_demo_registry_v1.ps1") @("-RepoRoot",$Sandbox)
Must ($r.Code -eq 0) ("SEED:" + $r.Text)
$principal = "single-tenant/device_agent/courier/node-alpha"

$r = Child $Signer @("-RepoRoot",$Sandbox,"-Action","keygen","-NodeId","node-alpha")
Must ($r.Code -eq 0 -and $r.Text -match "COURIER_NODE_SIGNER_OK") ("KEYGEN:" + $r.Text)
Must ($r.Text -match ("COURIER_NODE_SIGNER_PRINCIPAL: " + [regex]::Escape($principal))) "KEYGEN_PRINCIPAL"
$pubPath = Join-Path $Sandbox "proofs\keys\courier_single-tenant_device_agent_courier_node-alpha_ed25519.pub"
Must (Test-Path -LiteralPath $pubPath -PathType Leaf) "KEYGEN_PUB"
$pubBefore = [IO.File]::ReadAllText($pubPath)
$r = Child $Signer @("-RepoRoot",$Sandbox,"-Action","keygen","-NodeId","node-alpha")
Must ($r.Code -eq 0 -and [IO.File]::ReadAllText($pubPath) -ceq $pubBefore) "KEYGEN_IDEMPOTENT"
$Cases++; Write-Host "COURIER_NODE_SIGNER_CASE_OK: keygen -> key for the NeverLost principal (idempotent)"

$r = Child $Signer @("-RepoRoot",$Sandbox,"-Action","keygen","-NodeId","node-alpha","-Principal","single-tenant/owner/x")
Must ($r.Code -ne 0 -and $r.Text -match "COURIER_NODE_SIGNER_FAIL:BAD_PRINCIPAL") "NON_DEVICE_AGENT_REFUSED"
$r = Child $Signer @("-RepoRoot",$Sandbox,"-Action","keygen","-NodeId","..\x")
Must ($r.Code -ne 0 -and $r.Text -match "COURIER_NODE_SIGNER_FAIL:BAD_NODE_ID") "BAD_NODE_ID"
$Cases++; Write-Host "COURIER_NODE_SIGNER_CASE_OK: non-device-agent principal and bad node id -> refused"

$r = Child $Signer @("-RepoRoot",$Sandbox,"-Action","adopt","-NodeId","node-alpha")
Must ($r.Code -ne 0 -and $r.Text -match "COURIER_NODE_SIGNER_FAIL:NOT_IMPORTED") ("ADOPT_BEFORE_IMPORT:" + $r.Text)
Must ([string](CC-ReadJsonFile (Join-Path $Sandbox "registry\nodes\node-alpha.json")).principal -ceq "courier-local@covenant") "UNCHANGED_BEFORE_IMPORT"
$Cases++; Write-Host "COURIER_NODE_SIGNER_CASE_OK: adopt-before-import -> refused, registry unchanged"

# A NeverLost bundle for the principal but a different key: still refused.
$otherKey = Join-Path $NL "proofs\keys\other_ed25519"
$kg = (Get-Command ssh-keygen -ErrorAction Stop).Source
if($env:WINDIR -and (Test-Path -LiteralPath (Join-Path $env:WINDIR "System32\OpenSSH\ssh-keygen.exe"))){ $kg = Join-Path $env:WINDIR "System32\OpenSSH\ssh-keygen.exe" }
$kp = Start-Process -FilePath $kg -ArgumentList ('-q -t ed25519 -N "" -C "other" -f "' + $otherKey + '"') -Wait -PassThru -NoNewWindow
Must ($kp.ExitCode -eq 0) "OTHER_KEYGEN"
$wrong = Join-Path $NL "wrong_key_bundle.json"
$wSha = Bundle $wrong $principal ($otherKey + ".pub")
$r = Child (S "courier_trust_import_neverlost_v1.ps1") @("-RepoRoot",$Sandbox,"-TrustBundlePath",$wrong,"-ExpectedSha256",$wSha)
Must ($r.Code -eq 0) ("IMPORT_WRONG:" + $r.Text)
$r = Child $Signer @("-RepoRoot",$Sandbox,"-Action","adopt","-NodeId","node-alpha")
Must ($r.Code -ne 0 -and $r.Text -match "COURIER_NODE_SIGNER_FAIL:NOT_IMPORTED") "ADOPT_WRONG_KEY"
$Cases++; Write-Host "COURIER_NODE_SIGNER_CASE_OK: imported-key-differs -> refused"

# The real issuance: NeverLost lists this node key for the principal (namespace courier/message).
Copy-Item -LiteralPath $pubPath -Destination (Join-Path $NL "proofs\keys") -Force
$bundle = Join-Path $NL "trust_bundle.json"
$bSha = Bundle $bundle $principal (Join-Path $NL ("proofs\keys\" + (Split-Path -Leaf $pubPath)))
$r = Child (S "courier_trust_import_neverlost_v1.ps1") @("-RepoRoot",$Sandbox,"-TrustBundlePath",$bundle,"-ExpectedSha256",$bSha,"-NeverLostRoot",$NL)
Must ($r.Code -eq 0 -and $r.Text -match "COURIER_TRUST_IMPORT_OK") ("IMPORT:" + $r.Text)
$r = Child $Signer @("-RepoRoot",$Sandbox,"-Action","adopt","-NodeId","node-alpha")
Must ($r.Code -eq 0 -and $r.Text -match ("COURIER_NODE_SIGNER_ADOPTED: " + [regex]::Escape($principal))) ("ADOPT:" + $r.Text)
$node = CC-ReadJsonFile (Join-Path $Sandbox "registry\nodes\node-alpha.json")
Must ([string]$node.principal -ceq $principal -and [string]$node.node_id -ceq "node-alpha" -and (@($node.allowed_namespaces) -ccontains "courier/message")) "REGISTRY_ADOPTED"
$r = Child $Signer @("-RepoRoot",$Sandbox,"-Action","status","-NodeId","node-alpha")
Must ($r.Text -match "COURIER_NODE_SIGNER_IMPORTED: true" -and $r.Text -match "COURIER_NODE_SIGNER_ADOPTED: true") ("STATUS:" + $r.Text)
$Cases++; Write-Host "COURIER_NODE_SIGNER_CASE_OK: pinned-import + adopt -> node principal is NeverLost-issued"

# Governed delivery signed by the NeverLost principal, then received.
$r = Child (S "courier_open_session_v1.ps1") @("-RepoRoot",$Sandbox,"-SessionId","session-nl-signer","-SenderNodeId","node-alpha","-RecipientNodeId","node-beta","-NetworkId","courier-internal-net-v1","-SessionRole","message-delivery")
Must ($r.Code -eq 0) ("SESSION:" + $r.Text)
$r = Child (S "courier_bootstrap_local_trust_v1.ps1") @("-RepoRoot",$Sandbox)
Must ($r.Code -eq 0) ("BOOTSTRAP:" + $r.Text)
$r = Child (S "courier_prepare_message_v1.ps1") @("-RepoRoot",$Sandbox,"-From","local/sender/demo","-To","local/recipient/demo","-RecipientNodeId","node-beta","-SessionId","session-nl-signer","-PolicyProfile","default","-PayloadText","signed by a neverlost principal","-Origin","human")
Must ($r.Code -eq 0) ("PREPARE:" + $r.Text)
$msg = $null; $pay = $null
foreach($l in ($r.Text -split "`n")){ if($l -match 'COURIER_PREPARE_MESSAGE_OK:\s+(.+)$'){ $msg = $Matches[1].Trim() }; if($l -match 'COURIER_PREPARE_PAYLOAD_OK:\s+(.+)$'){ $pay = $Matches[1].Trim() } }
Must ($null -ne $msg -and $null -ne $pay) "PREPARE_OUTPUT"
$out = Join-Path $Run "delivered"
$r = Child (S "courier_deliver_v1.ps1") @("-RepoRoot",$Sandbox,"-MessagePath",$msg,"-PayloadPath",$pay,"-OutDir",$out)
Must ($r.Code -eq 0 -and $r.Text -match "COVENANT_COURIER_DELIVER_OK") ("DELIVER:" + $r.Text)
$r = Child (S "courier_verify_signature_v1.ps1") @("-RepoRoot",$Sandbox,"-MessagePath",(Join-Path $out "delivery.json"),"-SignerIdentity",$principal,"-Namespace","courier/message")
Must ($r.Code -eq 0 -and $r.Text -match "COURIER_SIGNATURE_VERIFY_OK") ("VERIFY:" + $r.Text)
$r = Child (S "courier_receive_message_v1.ps1") @("-RepoRoot",$Sandbox)
Must ($r.Code -eq 0) ("RECEIVE:" + $r.Text)
$m = CC-ReadJsonFile $msg
Must (Test-Path -LiteralPath (Join-Path $Sandbox ("runtime\product_messages\inbox\node-beta\" + [string]$m.message_id + "\payload.bin")) -PathType Leaf) "INBOX"
$Cases++; Write-Host "COURIER_NODE_SIGNER_CASE_OK: delivery signed by the NeverLost principal -> verified and received"

# Private keys copied or made for the sandbox do not outlive the run.
Remove-Item -LiteralPath (Join-Path $Sandbox "proofs\keys") -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ("COURIER_NODE_SIGNER_SELFTEST_CASES: " + $Cases)
Write-Host "COURIER_NODE_SIGNER_SELFTEST_OK"
