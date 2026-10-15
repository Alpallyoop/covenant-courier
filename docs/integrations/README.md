# Covenant Courier integrations

Courier is standalone-first. Every integration here is optional, explicit (a path or a pinned hash is
always passed in, never guessed), and records each exchange as a `constellation.integration.receipt.v1`
when Courier is the calling side. Registry status of each edge: `docs/proposals/0001-covenant-courier-ownership-and-integrations.md`.

## 1. Delivery contract (for Rebound and any other caller)

    pwsh -File courier.ps1 deliver -RepoRoot <courier root> -MessagePath <message.json> -PayloadPath <payload file> [-OutDir <dir>]

Input

- `message.json`: a `covenant_courier.message.v1` (closed field set; `organization_id` optional).
  `message_id`, node IDs, `session_id` and `policy_profile` must match `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`.
  `payload_sha256` must equal SHA-256 of the payload file bytes.
- The payload file: up to 768 KiB (the profile may set less).
- The message's `session_id` must be an open session in Courier's registry between the message's
  sender and recipient nodes (`courier_open_session_v1.ps1`).

Exit code

| Code | Meaning | `product_receipt.json` decision |
|---|---|---|
| 0 | sent: signed envelope is in the recipient node's inbox | `sent` |
| 42 | refused by policy | `rejected` or `quarantined` |
| other | failed (signing, transport, policy file) | `failed` |

Output in `-OutDir` (default `runtime/product_messages/delivered/<message_id>/`)

| File | Contract | Always |
|---|---|---|
| `product_receipt.json` | `covenant_courier.product_receipt.v1` | yes |
| `policy_decision.json` | `covenant_courier.policy_decision.v1` | when the message parsed |
| `notification.json` | `covenant_courier.notification.v1` | when the message parsed |
| `message.json` | copy of the input | when the message parsed |
| `delivery.json` + `.sig` | `covenant_courier.delivery.v1`, ssh signature, namespace `courier/message` | when sent |
| `covenant_gate/` | eval input/output | when Covenant Gate was consulted |

`product_receipt.json` contains exactly the receipt line (no trailing newline), so
`SHA-256(product_receipt.json)` = the receipt chain's `receipt_sha256` for that entry. That is the hash
to carry. The same line is appended to `proofs/receipts/covenant_courier_product.ndjson` and the chain
`proofs/receipts/covenant_courier_product.chain.ndjson` is extended (append-only; any edit, removal or
reordering of earlier receipts fails with `COVENANT_COURIER_RECEIPT_CHAIN_FAIL:TAMPER_DETECTED`).

Stdout tokens: `COVENANT_COURIER_DELIVER_MESSAGE_ID`, `..._POLICY`, `..._FRAME_ID` (sent only),
`..._RECEIPT`, `..._RECEIPT_SHA256`, `..._DECISION`, `..._REASON`, then exactly one of
`COVENANT_COURIER_DELIVER_OK`, `..._REFUSED`, `..._FAILED`.

Policy reason codes (`reason_code`): `POLICY_ALLOW`, `RESTRICTED_TERM_NOTIFICATION_REDACTED`,
`MESSAGE_INVALID:<detail>`, `PAYLOAD_HASH_MISMATCH`, `POLICY_PROFILE_UNKNOWN`,
`RECIPIENT_NODE_NOT_ALLOWED`, `SESSION_UNKNOWN`, `SESSION_NOT_OPEN`, `SESSION_BINDING_MISMATCH`,
`NODE_UNKNOWN`, `NODE_INACTIVE`, `PAYLOAD_TOO_LARGE`, `PAYLOAD_NOT_UTF8`, `RESTRICTED_TERM`,
`QUARANTINE:<reason>`, `REQUIRE_APPROVAL:<reason>`, `COVENANT_GATE_DENY:<codes>`,
`COVENANT_GATE_REFUSED:<token>`, `COVENANT_GATE_REQUIRED:<token>`, `COURIER_DELIVER_FAILED:<token>`,
`COURIER_POLICY_FAILED:<token>`.

Receiving side: `courier.ps1 receive` runs the recipient node's policy loop, verifies the envelope
against the sender's receipt (message ID, payload hash, recipient node, frame bindings, deliverable
policy decision) and only then writes `runtime/product_messages/inbox/<node>/<message_id>/`
(`payload.bin`, `message.json`, `policy_decision.json`, `notification.json`). A transport rejection or
an invalid envelope writes a `rejected` product receipt (`event_type
covenant_courier.product.receive_reject.v1`).

### What Rebound writes (its side of proposal 0013)

    consumer        rebound
    provider        covenant-courier
    emitted_by      consumer
    contract        covenant_courier.message.v1
    request_sha256  SHA-256 of the message.json bytes it passed
    response_sha256 SHA-256 of product_receipt.json
    carried         [{ "contract": "covenant_courier.product_receipt.v1", "sha256": <same as response> }]
    outcome         ok (exit 0) | refused (exit 42) | failed (other) | unavailable (Courier root missing)
    error_token     null | the reason code's leading token, e.g. RESTRICTED_TERM

Courier's own integration-receipt library (`scripts/_lib_constellation_integration_receipt_v1.ps1`)
can be reused for this: it writes the schema's exact byte form and chains `prev_sha256`.

## 2. Covenant Gate (Courier is the consumer)

Profile setting `covenant_gate`: `off` (default), `advisory`, `required`.

| Mode | How | Courier verifies |
|---|---|---|
| invoke | `-CovenantGateRoot <checkout>` or `COVENANT_GATE_ROOT`. Courier runs Covenant Gate's sealed evaluator (`scripts/_lib_covenantgate_eval_v1.ps1`, `CG-EvalV1`, canonical base policy + v1 overlay) in a separate process, read-only. | `input_hash` = SHA-256 of Courier's own canonical eval input + LF; `evaluation_id` = SHA-256(`policy_hash\ninput_hash\ncovenantgate.eval.v1`); schema, engine, decision. |
| document | `-CovenantGateDecisionPath <eval_output.json>` with `<eval_output.json>.sig` (namespace `covenant-gate/decision`) by the profile's `covenant_gate_signer`. | Signature against Courier's trust roots, then the same checks. |

Eval input Courier sends (`covenantgate.eval_input.v1`): `enforcement_point: eval.request`,
`subject {type: courier_sender, principal, node_id, claimed_identity}`, `action {type: courier.deliver}`,
`execution_surface: covenant-courier`, `resource {domain: courier.message, message_id, payload_sha256,
policy_profile, recipient_claimed_identity, recipient_node_id, recipient_principal, session_id}`.

Outcomes: allow -> local decision stands; deny -> `rejected COVENANT_GATE_DENY:<codes>`; a refused
document (bad signature, hash mismatch) -> `rejected`; unavailable -> `required` quarantines with
`REQUIRE_APPROVAL:COVENANT_GATE_REQUIRED:<token>`, `advisory` proceeds on local policy; reached but
failed (evaluator crash, missing document) -> `advisory` quarantines with
`REQUIRE_APPROVAL:COVENANT_GATE_FAILED:<token>`. Any other `covenant_gate` value fails closed
(`COURIER_POLICY_FAILED:POLICY_PROFILE_BAD_COVENANT_GATE`).

The subject Courier presents is the sender node's registry principal (the identity that signs the
frame) and the recipient node's principal; the message's self-asserted `sender_identity` /
`recipient_identity` travel only as `claimed_identity` / `recipient_claimed_identity`. Receipts:
`proofs/integration_receipts/covenant-courier__covenant-gate/receipts.ndjson`.

Verified in this repository's session against Covenant Gate's real evaluator: Courier's input hash and
evaluation ID matched Covenant Gate's; the decision was `DEFAULT_DENY` because Covenant Gate's canonical
policy has no rule for `courier.deliver` yet (proposal 0001, section 4).

## 3. NeverLost (Courier is the consumer)

    pwsh -File courier.ps1 trust-import -TrustBundlePath <neverlost proofs/trust/trust_bundle.json> -ExpectedSha256 <TRUST_BUNDLE_SHA256> [-NeverLostRoot <neverlost checkout>]

- The bundle's SHA-256 must equal the pinned value (from NeverLost's `verify_trust_bundle_v1.ps1`).
- Principals form only (`neverlost.trust_bundle.v1`), closed field sets, NeverLost's principal pattern,
  no allowed_signers pattern characters (`, * ? !`) in principals or namespaces, `ssh-ed25519` keys; with `-NeverLostRoot`, `pubkey_sha256` is recomputed over the key files.
- Writes `proofs/trust/neverlost/allowed_signers`, derived exactly like NeverLost's own (checked
  byte-identical against NeverLost's real bundle in this session), plus `import.json`.
- `courier_verify_signature_v1.ps1` accepts a signature that verifies against any of: `trust/allowed_signers`
  (release signers), `proofs/trust/allowed_signers` (local bootstrap), `proofs/trust/neverlost/allowed_signers`.
- Receipts: `proofs/integration_receipts/covenant-courier__neverlost/receipts.ndjson` (`ok`, `refused`
  for pin/format failures, `unavailable` for a missing bundle).

## 4. NFL (witness)

Courier never calls NFL and never blocks on it. NFL witnesses Courier's receipts by reading the
folders above in inbox mode `receipt`; `courier.ps1 integration-receipts -Action nfl-inboxes` prints the
entries for NFL's `config/inbox_registry.json`. `courier.ps1 integration-receipts` verifies every line
and chain locally.

The product receipt chain head (`COVENANT_COURIER_RECEIPT_CHAIN_HEAD`) can be committed to NFL as a
file artifact by an operator; that is not an integration record today.

## 5. Global Workbench

Draft plugin manifest: proposal 0001, section 6. `vtp_tray_contract_v1.json` lists the controls and the
receipt files a UI may read.
