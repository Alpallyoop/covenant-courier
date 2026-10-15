param(
  [string]$RepoRoot = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path $RepoRoot).Path
$Schemas = Join-Path $RepoRoot "schemas"

$Expected = @(
  "covenant_courier.message.v1.json",
  "covenant_courier.notification.v1.json",
  "covenant_courier.policy_decision.v1.json",
  "covenant_courier.product_receipt.v1.json",
  "covenant_courier.delivery.v1.json",
  "covenant_courier.product_policy.v1.json",
  "covenant_courier.product_receipt_chain.v1.json"
)

function Require-Prop {
  param(
    [Parameter(Mandatory=$true)]$Obj,
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][string]$FileName
  )

  if($Obj.PSObject.Properties.Name -notcontains $Name){
    throw ("COVENANT_COURIER_SCHEMA_TEST_FAIL:MISSING_PROP:" + $FileName + ":" + $Name)
  }
}

foreach($fileName in $Expected){
  $path = Join-Path $Schemas $fileName

  if(-not (Test-Path -LiteralPath $path -PathType Leaf)){
    throw ("COVENANT_COURIER_SCHEMA_TEST_FAIL:MISSING_SCHEMA:" + $fileName)
  }

  $raw = Get-Content -LiteralPath $path -Raw
  $schema = $raw | ConvertFrom-Json

  Require-Prop -Obj $schema -Name '$schema' -FileName $fileName
  Require-Prop -Obj $schema -Name '$id' -FileName $fileName
  Require-Prop -Obj $schema -Name 'type' -FileName $fileName
  Require-Prop -Obj $schema -Name 'required' -FileName $fileName
  Require-Prop -Obj $schema -Name 'properties' -FileName $fileName

  if([string]$schema.type -ne "object"){
    throw ("COVENANT_COURIER_SCHEMA_TEST_FAIL:TYPE_NOT_OBJECT:" + $fileName)
  }

  if($schema.PSObject.Properties.Name -contains "additionalProperties"){
    if([bool]$schema.additionalProperties -ne $false){
      throw ("COVENANT_COURIER_SCHEMA_TEST_FAIL:ADDITIONAL_PROPERTIES_NOT_FALSE:" + $fileName)
    }
  } else {
    throw ("COVENANT_COURIER_SCHEMA_TEST_FAIL:MISSING_ADDITIONAL_PROPERTIES:" + $fileName)
  }

  Write-Host ("COVENANT_COURIER_SCHEMA_OK: " + $fileName)
}

# The shipped delivery policy must name its schema, a default profile that exists, and only
# profiles with the closed field set.
$policyPath = Join-Path $RepoRoot "policy\courier_product_policy_v1.json"
if(-not (Test-Path -LiteralPath $policyPath -PathType Leaf)){ throw "COVENANT_COURIER_SCHEMA_TEST_FAIL:MISSING_PRODUCT_POLICY" }
$policy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json
if([string]$policy.schema -ne "covenant_courier.product_policy.v1"){ throw "COVENANT_COURIER_SCHEMA_TEST_FAIL:PRODUCT_POLICY_SCHEMA" }
if($policy.profiles.PSObject.Properties.Name -notcontains [string]$policy.default_profile){ throw "COVENANT_COURIER_SCHEMA_TEST_FAIL:PRODUCT_POLICY_DEFAULT_PROFILE" }
$allowedProfileFields = @("allowed_recipient_nodes","max_payload_bytes","require_utf8_payload","restricted_dictionary","restricted_action","notification_display_mode","covenant_gate","covenant_gate_signer")
foreach($p in $policy.profiles.PSObject.Properties){
  foreach($n in $p.Value.PSObject.Properties.Name){ if($allowedProfileFields -notcontains $n){ throw ("COVENANT_COURIER_SCHEMA_TEST_FAIL:PRODUCT_POLICY_UNKNOWN_FIELD:" + $p.Name + ":" + $n) } }
}
Write-Host "COVENANT_COURIER_SCHEMA_OK: policy/courier_product_policy_v1.json"

Write-Host "COVENANT_COURIER_SCHEMA_TEST_OK"
