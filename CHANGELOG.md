# Changelog

## Unreleased (2026-11-01) - VTP v2 payload encryption, message origin

### Added

- Payload encryption over VTP v2 for governed delivery: profile setting `payload_encryption` (`none` |
  `vtp2`; the `confidential` profile now requires `vtp2`). The envelope carries `payload_vtp2_b64` (a
  `vtp.message.v2`) instead of `payload_b64`; with no VTP v2 binding the delivery is quarantined
  (`REQUIRE_STRONGER_SESSION:VTP2_SESSION_NOT_BOUND`). Receive decrypts with the recipient node's state and
  refuses a plaintext envelope on a bound session (`VTP2_DOWNGRADE_REFUSED`).
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
