# Covenant Courier local delivery policy (v1): the checks one profile makes on one payload, shared by the
# sender (courier_deliver_v1.ps1) and the receiver (courier_receive_message_v1.ps1), so the receiver
# re-decides with its own policy instead of trusting the sender's policy_decision.
#
# Restricted-term matching works on a folded form of the text: compatibility decomposition (NFKD), with
# format characters (Cf: soft hyphen, zero-width joiner, ...), and combining marks (Mn, Me) removed, then
# NFC and lower case. "r­ose", "ｒｏｓｅ" and "róse" all fold to "rose". A payload that is not
# text cannot be scanned: with a dictionary configured it is never passed as allowed.

Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "_lib_covenant_courier_product_v1.ps1")

function CCP-Fold([string]$Text){
  if($null -eq $Text){ return $null }
  $d = $Text.Normalize([Text.NormalizationForm]::FormKD)
  $sb = New-Object System.Text.StringBuilder $d.Length
  foreach($ch in $d.ToCharArray()){
    $cat = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch)
    if($cat -eq [Globalization.UnicodeCategory]::Format -or $cat -eq [Globalization.UnicodeCategory]::NonSpacingMark -or $cat -eq [Globalization.UnicodeCategory]::EnclosingMark){ continue }
    [void]$sb.Append($ch)
  }
  return $sb.ToString().Normalize([Text.NormalizationForm]::FormC).ToLowerInvariant()
}

# The texts a payload can be read as: strict UTF-8, and when that text carries NUL characters (UTF-16
# looks like UTF-8 with NULs), UTF-16 LE and BE as well. Empty list = not text.
function CCP-PayloadTexts([byte[]]$Bytes){
  $texts = New-Object System.Collections.Generic.List[string]
  $utf8 = $null
  try { $utf8 = (New-Object System.Text.UTF8Encoding($false,$true)).GetString($Bytes) } catch { $utf8 = $null }
  if($null -ne $utf8){
    $texts.Add($utf8)
    if($utf8.Contains([string][char]0) -and ($Bytes.Length % 2) -eq 0){
      foreach($enc in @((New-Object System.Text.UnicodeEncoding($false,$false,$true)),(New-Object System.Text.UnicodeEncoding($true,$false,$true)))){
        try { $texts.Add($enc.GetString($Bytes)) } catch {}
      }
    }
  }
  return ,$texts
}

# Returns @{ Decision; Reason; IsText }. Decision is one of allow, reject, quarantine, require_approval,
# redact_notification. $Fields are the other texts that reach the recipient (preview, identities).
function CCP-EvaluateLocal {
  param(
    [Parameter(Mandatory=$true)][string]$RepoRoot,
    [Parameter(Mandatory=$true)]$Profile,
    [Parameter(Mandatory=$true)][AllowEmptyCollection()][byte[]]$PayloadBytes,
    [Parameter(Mandatory=$true)][string]$RecipientNodeId,
    [string[]]$Fields = @(),
    [switch]$PayloadTooLarge
  )
  $r = @{ Decision = "allow"; Reason = "POLICY_ALLOW"; IsText = $false }
  if(@($Profile.allowed_recipient_nodes) -cnotcontains $RecipientNodeId){ $r.Decision = "reject"; $r.Reason = "RECIPIENT_NODE_NOT_ALLOWED"; return $r }
  if($PayloadTooLarge -or $PayloadBytes.Length -gt [int64]$Profile.max_payload_bytes){ $r.Decision = "reject"; $r.Reason = "PAYLOAD_TOO_LARGE"; return $r }
  $texts = CCP-PayloadTexts $PayloadBytes
  $r.IsText = ($texts.Count -gt 0)
  if(-not $r.IsText -and [bool]$Profile.require_utf8_payload){ $r.Decision = "reject"; $r.Reason = "PAYLOAD_NOT_UTF8"; return $r }
  if($null -eq $Profile.restricted_dictionary){ return $r }

  $action = [string]$Profile.restricted_action
  if(-not $r.IsText){
    # Bytes that are not text cannot be checked against the dictionary: never an allow.
    $r.Decision = $(if($action -ceq "reject"){ "reject" } elseif($action -ceq "require_approval"){ "require_approval" } else { "quarantine" })
    $r.Reason = "PAYLOAD_NOT_SCANNABLE"; return $r
  }
  $dictRel = [string]$Profile.restricted_dictionary
  if([IO.Path]::IsPathRooted($dictRel) -or $dictRel.Contains("..")){ CC-Fail "POLICY_DICTIONARY_PATH_INVALID" }
  $dict = CC-ReadJsonFile (Join-Path $RepoRoot $dictRel)
  $folded = @()
  foreach($t in $texts){ $folded += ,(CCP-Fold $t) }
  foreach($f in @($Fields)){ if(-not [string]::IsNullOrEmpty($f)){ $folded += ,(CCP-Fold $f) } }
  $hit = $false
  foreach($e in @($dict.entries)){
    if([string]$e.sensitivity -ne "controlled"){ continue }
    foreach($form in @($e.surface_forms)){
      $ff = CCP-Fold ([string]$form)
      if([string]::IsNullOrWhiteSpace($ff)){ continue }
      $rx = '(?<![\p{L}\p{N}])' + [regex]::Escape($ff) + '(?![\p{L}\p{N}])'
      foreach($t in $folded){ if([regex]::IsMatch($t,$rx)){ $hit = $true; break } }
      if($hit){ break }
    }
    if($hit){ break }
  }
  if($hit){
    switch($action){
      "reject" { $r.Decision = "reject"; $r.Reason = "RESTRICTED_TERM" }
      "quarantine" { $r.Decision = "quarantine"; $r.Reason = "RESTRICTED_TERM" }
      "require_approval" { $r.Decision = "require_approval"; $r.Reason = "RESTRICTED_TERM" }
      "redact_notification" { $r.Decision = "redact_notification"; $r.Reason = "RESTRICTED_TERM_NOTIFICATION_REDACTED" }
      default { $r.Decision = "reject"; $r.Reason = "POLICY_PROFILE_BAD_RESTRICTED_ACTION" }
    }
  }
  return $r
}

# The profile a delivery runs under. A session that names a profile (session_policy_ref) decides it;
# the message may only repeat it. Without one, the message's profile is used.
function CCP-ResolveProfileName($Message,$Session){
  $p = [string]$Message.policy_profile
  if($null -ne $Session -and (CC-HasProp $Session "session_policy_ref") -and -not [string]::IsNullOrWhiteSpace([string]$Session.session_policy_ref)){
    if([string]$Session.session_policy_ref -cne $p){ CC-Fail "POLICY_PROFILE_NOT_SESSION_PROFILE" }
  }
  return $p
}

# The notification the recipient sees, built from a profile's display mode (never the sender's choice).
function CCP-BuildNotification([string]$MessageId,[string]$RecipientIdentity,[string]$DisplayMode,[string]$Preview){
  $pv = switch($DisplayMode){
    "full_safe" { $Preview }
    "redacted" { "[redacted]" }
    "generic" { "New secure message" }
    default { "" }
  }
  return [ordered]@{
    schema = "covenant_courier.notification.v1"
    message_id = $MessageId
    recipient_identity = $RecipientIdentity
    display_mode = $DisplayMode
    preview = $pv
    created_utc = (CC-UtcNow)
  }
}
