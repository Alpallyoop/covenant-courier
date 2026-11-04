# Changelog

## Unreleased (2026-11-04) - security audit

### Security

- Receive re-decides delivery with the receiver's own policy (recipient allow-list, size, text, restricted
  terms) under the session's profile, and builds the inbox notification from that profile; the sender's
  `policy_decision` and `notification` are no longer trusted (`RECEIVER_POLICY_<decision>:<reason>`). Shared
  evaluation in `scripts/_lib_courier_policy_eval_v1.ps1`.
- Restricted terms are matched on folded text (NFKD, Cf/Mn/Me removed, NFC, lower case) in payload (UTF-8 and
  UTF-16), preview, identities and organization; a non-text payload under a dictionary is never allowed
  (`PAYLOAD_NOT_SCANNABLE`).
- `deliver -PolicyPath` only accepts files under `<repo>/policy/` (`POLICY_PATH_NOT_IN_REPOSITORY`); a session
  opened with `-SessionPolicyRef` fixes the profile (`POLICY_PROFILE_NOT_SESSION_PROFILE`); a Covenant Gate
  decision signer may not be a node principal (`POLICY_PROFILE_GATE_SIGNER_IS_A_NODE`).
- Covenant Gate invoke mode runs only a checkout pinned with the new `courier.ps1 cg-pin`
  (`scripts/courier_covenant_gate_pin_v1.ps1`, `proofs/trust/covenant_gate_pin.json`): unpinned roots are not
  run (`COVENANT_GATE_ROOT_NOT_PINNED`, unavailable), changed pinned files are refused
  (`COVENANT_GATE_PIN_MISMATCH`); the hash-checked bytes are what runs.
- Sessions are never reopened or rebound (`COURIER_SESSION_FAIL:SESSION_CLOSED` /
  `SESSION_EXISTS_WITH_OTHER_BINDING`); opening an open session again is a no-op.
- Signature verifier: release signers only with `-IncludeReleaseSigners`; identity/namespace allow-list (no
  ssh-keygen argument injection); links and >4 MB inputs refused; verifies staged bytes read once and prints
  `COURIER_SIGNATURE_VERIFIED_SHA256`.
- Transport listener: strict `message_rel` / `signature_rel`, no links, size limits, verifier called with an
  argument array, verified-bytes hash must match, re-hash after the move, per-node accepted-payload index
  (re-framed replays refused). The policy loop hands allowed frames to `runtime/nodes/<node>/approved/`; rejected
  and duplicate frames are kept, never deleted through; the outbox never deletes a destination.
- VTP peer pin computes the fingerprint from the key, validates principal and key, writes
  `namespaces="courier/message"`, and refuses a second key for a pinned principal; invite and m2m imports refuse
  `..` and non-plain names. The local bootstrap signer is limited to `courier/message` and no longer rewrites
  other principals' lines.
- Receive verifies the product receipt chain before using the log (`RECEIPT_LOG_HAS_UNCHAINED_LINES`), creates
  each inbox entry once (`MESSAGE_ALREADY_IN_INBOX`), compares message ids case-insensitively; receipt appends
  are exclusive.
- Child scripts run from the installation (`$PSScriptRoot`), never from `-RepoRoot` or the current folder.
- Redacted, generic and minimal notifications no longer leave the sender's preview in the envelope; quarantine
  stores the evaluated bytes; IDs refuse a trailing dot and reserved device names; register-node validates id,
  principal and namespaces.
- UDP ingest binds 127.0.0.1 by default, ignores stray datagrams, checks IV/tag lengths; the wire key envelope
  is created owner-only; `vtp_udp_wire_listen_once_v1.ps1` (unused, unvalidated) removed; the VTP policy gate
  fails closed on empty allow-lists or unreadable JSON.

- Receivers verify Covenant Gate's own signed decision for gate-required profiles (`covenant_gate_decision`
  in the delivery envelope; `RECEIVER_GATE_DECISION_MISSING`, `RECEIVER_GATE_DECISION_INVALID:<token>`,
  `RECEIVER_GATE_DENY`); invoke mode has the pinned Covenant Gate sign its allow (`cg_sign_decision_v1.ps1`),
  else a required gate waits (`COVENANT_GATE_DECISION_UNSIGNED`). `confidential` names the signer
  `single-tenant/device_agent/covenant-gate`.
- `cg-pin` also pins the Covenant Gate policy hash (probed, or `-PolicyHash`) and the decision signer scripts;
  decisions under another policy are refused.
- Signed receipt chain head (`covenant_courier.receipt_chain_head.v1`, receipt signer `courier-receipts@local`);
  consistent rewrites, forged or dropped heads are refused.

### Tests

- New `_selftest_courier_receive_policy_v1.ps1` (forged allow, forged notification, re-framed replay, unchained
  log) and more cases in the deliver, trust-pin and registry self-tests; self-tests no longer close the demo
  session, pin into the repository's trust roots, or leave private key copies in sandboxes.

## Unreleased (2026-11-01) - VTP v2 payload encryption, message origin

### Added

- VTP v2.1 in-session DH ratchet (spec section 6.1): envelopes `vtp.message.v3` carry the sender's ratchet key
  and previous chain length; each round trip brings fresh P-256 ECDH from both devices (post-compromise recovery
  against a passive adversary). Skipped keys: at most 1000 per gap, 2000 per session with oldest-first eviction,
  deleted after the message lifetime. Public keys must be named-curve uncompressed P-256 SPKI. Decrypt stages the
  plaintext before saving state and refuses a directory as output. `vtp2.ps1 session-close`. Pre-2.1 sessions
  are refused and dropped. State limit 64 MiB. Internal review findings addressed; an independent human review is
  still required.
- `scripts/courier_build_release_v1.ps1`: release ZIP of a clean commit, manifest, sha256sums and clean-extract smoke.
- `courier.ps1 receipt-chain -VerifyOnly`: re-verifies without appending (for read-only callers).
- Payload encryption over VTP v2 for governed delivery: profile setting `payload_encryption` (`none` |
  `vtp2`; the `confidential` profile now requires `vtp2`). The envelope carries `payload_vtp2_b64` (a
  `vtp.message.v2`) instead of `payload_b64`; with no VTP v2 binding the delivery is quarantined
  (`REQUIRE_STRONGER_SESSION:VTP2_SESSION_NOT_BOUND`). Receive decrypts with the recipient node's state and
  refuses a plaintext envelope on a bound session or for a profile its own policy marks vtp2
  (`VTP2_DOWNGRADE_REFUSED`). A bound session always carries the payload encrypted; encrypted payloads are
  limited to 600,000 bytes; the sender's free-text preview is not carried in a sealed envelope.
- `courier.ps1 secure-session` (`scripts/courier_secure_session_v1.ps1`) binds a Courier session to a VTP v2
  session (`registry/vtp2_bindings/<session>.json`, schema `covenant_courier.vtp2_binding.v1`): `-LocalPair`
  for both nodes on one machine, or an existing two-machine VTP v2 session with its fingerprints.
- Optional message `origin` (`human` | `ai` | `service`; `-Origin` on `prepare` / `send`), passed to Covenant
  Gate as `action.origin` (`unspecified` when absent) for its `allow.courier.deliver.human` rule.
- `courier.ps1 node-signer -Action keygen|adopt|status` (`scripts/courier_node_signer_v1.ps1`): NeverLost-issued
  node signers. `keygen` creates the node key for `single-tenant/device_agent/courier/<node-id>` and prints the
  public key to issue; `adopt` switches the node's registry principal only when the imported NeverLost trust
  root lists that principal with exactly that key and namespace `courier/message`. Self-test (6 cases) in
  `verify-all`.
- `schemas/covenant_courier.settings.v1.json`: the settings contract the Global Workbench plugin manifest names.
- `courier.ps1 secure-session` and `-Origin` shown in `courier.ps1 help`.
- Delivery self-test: real Covenant Gate cases per origin, VTP v2 cases (unbound, local pair, sealed send
  without plaintext, tampered binding, downgrade refused, sealed end-to-end receive).

### Fixed

- `vtp2.ps1 ... --out <file>` failed with "parameter name 'out' is ambiguous" (the param block captured it as a
  common parameter), which also broke `courier-secure.ps1 bundle`. The script now parses its arguments itself;
  the VTP v2 self-test runs the wrapper path as a regression check.

## Unreleased (2026-10-15) - governed delivery and Constellation integration

### Fixed

- `courier send` signed a product receipt for the prepared message but transmitted a fixed test
  vector. It now delivers the prepared message itself through the governed delivery path.
- Product receipt chain rebuilt itself from the receipt log on every run, so edits went unnoticed.
  It is now append-only and re-verifies every existing entry (`TAMPER_DETECTED`).
- `courier receive` emitted `accepted` without checking what was accepted; it now verifies the
  delivery envelope against the sender's receipt, and writes a `rejected` receipt for transport or
  envelope rejections.
- Prepared payload file had a trailing newline its `payload_sha256` did not cover.
- `courier.ps1` and `vtp_verify_all.ps1` named a parameter `$Args`; child arguments were silently
  dropped.
- `courier_run_message_pipeline_v1.ps1` parameters had changed under its callers (`-InputDir`); the
  legacy entry point is restored alongside the new one.
- Signature verification only trusted `trust/allowed_signers` when present, so locally bootstrapped
  signers never verified on a clean checkout; local and NeverLost trust roots are now checked too, and
  an untrusted key reports `COURIER_VERIFY_FAIL:UNTRUSTED_SIGNER`.
- Several self-tests passed for the wrong reason (missing mandatory `-SignerIdentity`), or failed
  (stale transport tests without registry bindings, wrong failure token).
- The transport listener trusted a hard-coded sender identity; it now requires the sender node's
  registered principal. The UDP wire adapter took session, sender and network from constants; they now
  come from the open session in the registry (new negatives: unknown session, wrong sender, oversize).
- A listener temp file went to the system temp folder (missing on Linux); scratch now stays in
  `runtime/tmp`. Removed an obsolete self-patching script.
- `_RUN_courier_vectors_v1.ps1` defaulted to `C:\dev\...`; now repository-relative.
- Outbox retry time was reinterpreted in local time on PowerShell 7 (ConvertFrom-Json date handling).
- A variable-name collision (`$Cfg`/`$cfg`) in `_selftest_vtp_negatives_v1.ps1` wrote a stray file
  named `System.Collections.Specialized.OrderedDictionary` into the repository root.

- Transport listener: IDs from the unsigned frame header could traverse out of the registry
  folders; they are now pattern-checked, the frame folder must match its frame ID, and accepted
  evidence is never overwritten (an existing destination is a replay).
- UDP wire ingest: replay of a captured packet was accepted (the replay key included a fresh
  timestamp); it is now keyed on the authenticated MAC tag.
- NeverLost import: principals or namespaces containing allowed_signers pattern characters
  (`, * ? !`) are refused.
- Covenant Gate is asked about the sender node's registry principal, not the message's self-asserted
  identity.
- VTP v2: the largest accepted plaintext could produce an envelope the receiver refused (and burned
  a message number); canonical JSON escaped every `+` of base64; the key transcript included the
  malleable ECDSA signature.

### Added

- `courier.ps1 deliver` with `policy/courier_product_policy_v1.json` profiles (`default`, `public`,
  `confidential`), `covenant_courier.delivery.v1`, `.product_policy.v1`, `.product_receipt_chain.v1`.
- Constellation `constellation.integration.receipt.v1` emitter/verifier (proposal 0013) and
  `courier.ps1 integration-receipts`.
- Covenant Gate adapter (invoke and signed-document modes), NeverLost trust import
  (`courier.ps1 trust-import`).
- `courier.ps1 verify-all`; self-tests for delivery (29 cases), integration receipts (14), trust
  import (7).
- VTP v2: cross-platform build (`net10.0`), sealed state off Windows (`VTP2_STATE_KEY_FILE`), `rotate`,
  bundle rollback detection, closed field sets, duplicate-key rejection, total skipped-key cap,
  recipient-fingerprint binding, `kat` (RFC 5869 / 4231 / 8439 known answers), `status`.
- Everything runs on PowerShell 7 (Linux) as well as Windows PowerShell 5.1.
- `docs/canonical/CURRENT_STATE.md`, `docs/integrations/README.md`,
  `docs/proposals/0001-covenant-courier-ownership-and-integrations.md`.

## covenant-courier-v0.1.5-product-core

First clean-ZIP-smoke-gated product-core preview.

### Added

- Clean extracted ZIP verification path.
- Public allowed signers for release verification.
- Demo policy included in release bundle.
- Signed test vectors included in release bundle.
- VTP verifier included in release bundle.
- Clean-bundle demo registry bootstrap.
- Fast local release smoke test.
- Distribution documentation.

### Verified

Clean extracted ZIP smoke produced:

    COVENANT_COURIER_RELEASE_ZIP_SMOKE_OK
    COVENANT_COURIER_VERIFY_OK
    VTP_VERIFY_ALL_OK

### Supersedes

    covenant-courier-v0.1.0-product-core
    covenant-courier-v0.1.1-product-core
    covenant-courier-v0.1.2-product-core
    covenant-courier-v0.1.3-product-core
    covenant-courier-v0.1.4-product-core
