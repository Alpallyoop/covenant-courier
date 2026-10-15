param(
  [string]$RepoRoot = ".",
  [string]$RecipientNodeId = "node-beta"
)

# Seeds the local demo registry (node-alpha, the recipient node, courier-internal-net-v1) when
# absent, so a clean checkout or release bundle can run the product flow. Existing entries are
# never modified. Registry state is local (ignored by git).

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path $RepoRoot).Path
$enc = [Text.UTF8Encoding]::new($false)
$nodeRoot = Join-Path $RepoRoot "registry\nodes"
$netRoot = Join-Path $RepoRoot "registry\networks"
[void][IO.Directory]::CreateDirectory($nodeRoot)
[void][IO.Directory]::CreateDirectory($netRoot)

function Seed([string]$Path,$Obj){
  if(Test-Path -LiteralPath $Path -PathType Leaf){ return }
  [IO.File]::WriteAllText($Path, (($Obj | ConvertTo-Json -Depth 20 -Compress) + [string][char]10), $enc)
  Write-Host ("COURIER_DEMO_REGISTRY_SEEDED: " + $Path)
}

$now = (Get-Date).ToUniversalTime().ToString("o")
foreach($n in @(@{ id = "node-alpha"; name = "Node Alpha"; role = "sender" }, @{ id = $RecipientNodeId; name = $RecipientNodeId; role = "receiver" })){
  Seed (Join-Path $nodeRoot ($n.id + ".json")) ([ordered]@{
    schema = "courier.node_registry.v1"; node_id = $n.id; node_name = $n.name; node_role = $n.role
    principal = "courier-local@covenant"; status = "active"; created_utc = $now; last_seen_utc = $null
    allowed_namespaces = @("courier/message"); tags = @("release-demo")
  })
}
Seed (Join-Path $netRoot "courier-internal-net-v1.json") ([ordered]@{
  schema = "courier.network_registry.v1"; network_id = "courier-internal-net-v1"; network_name = "Courier Internal Net"
  transport_kind = "filesystem-drop"; listener_port = 47151; binding_mode = "dedicated"; visibility = "private"
  status = "active"; allowed_nodes = @("node-alpha",$RecipientNodeId); created_utc = $now
})
Write-Host "COURIER_DEMO_REGISTRY_OK"
