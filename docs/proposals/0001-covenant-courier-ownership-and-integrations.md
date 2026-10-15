# Proposal 0001 - Covenant Courier ownership, contracts and integrations

| Field | Value |
|---|---|
| Status | Proposed (2026-10-15). Needs the owner's decision, then Constellation `registry/services.json` + `registry/integrations.json` and a re-publish. |
| Affects | Constellation registry entry `covenant-courier` (`owns`, `does_not_own`, `upstream_services`, `downstream_users`, `contract_families`), `registry/integrations.json` (three new planned records, one updated), NFL `config/inbox_registry.json`, Covenant Gate canonical policy, Global Workbench plugins |
| Compatibility | Additive. No existing contract changes. Courier stays standalone-first: every integration below is optional and has an explicit unavailable / refused / failed state. |

This file is the only place this repository proposes canonical changes. `.constellation/`,
`project.contract.json` and `docs/canonical/ECOSYSTEM_INTEGRATION.md` are Constellation's and are
not edited here.

## 1. Why

The registry says Covenant Courier owns `UNCLASSIFIED`, has no upstream services and no contract
families, while Rebound is already registered as consuming four `covenant_courier.*` contracts. The
implementation now has a real governed delivery path, Constellation integration receipts, a
Covenant Gate adapter and a NeverLost trust import (see `docs/canonical/CURRENT_STATE.md`). The
registry should describe that, so agents and Constellation's doctor stop treating Courier as an
unclassified service.

## 2. Proposed ownership

**Owns**

- Governed delivery of messages and notifications: nothing is sent without a policy decision, a
  product receipt and a traceable frame.
- The delivery policy evaluation for a message (`covenant_courier.product_policy.v1`: recipient
  allow-list, session, size, encoding, restricted terms, notification display mode).
- The product contracts `covenant_courier.message.v1`, `.notification.v1`, `.policy_decision.v1`,
  `.product_receipt.v1`, `.delivery.v1`, `.product_receipt_chain.v1`, `.product_policy.v1`.
- The append-only product receipt log and its hash chain.
- VTP: the transport protocol (v1 frames, UDP wire adapter, node loop, outbox) and the VTP v2 secure
  session core (`vtp.prekey_bundle.v2`, `vtp.session_init.v2`, `vtp.message.v2`).
- Courier's node, network and session registries (delivery routing state).

**Does not own**

- Identity creation, signer lists and key custody: NeverLost. Courier imports a pinned NeverLost
  trust bundle; it never issues identities for other services.
- Policy authority beyond the delivery gate: Covenant Gate (and Arbiter for machine law). Courier asks
  and verifies; it does not author ecosystem policy.
- Permanent witnessing of hashes: NFL.
- Email relay, mailboxes, delivery-state truth for mail, retries and conversation projections:
  Rebound (Rebound's own boundary document says so: "identity and trust must not become transport
  truth").
- UI: Global Workbench hosts any Courier panels; Courier keeps no UI of its own.

## 3. Proposed dependency records

| consumer > provider | contracts | state | receipt (proposal 0013) | What it is |
|---|---|---|---|---|
| `rebound > covenant-courier` | `covenant_courier.message.v1`, `.notification.v1`, `.policy_decision.v1`, `.product_receipt.v1` | exists (registered) | emitted_by consumer, carries `covenant_courier.product_receipt.v1` — unchanged | Rebound submits a message through `courier.ps1 deliver` and carries the SHA-256 of `product_receipt.json`. See `docs/integrations/README.md`. |
| `covenant-courier > covenant-gate` | `covenantgate.eval_output.v1` | planned -> **emitting** | emitted_by consumer, witness nfl | Profiles with `covenant_gate: advisory/required` consult Covenant Gate (sealed evaluator, or a signed decision document). Receipt written for every consultation, including unavailable and refused. |
| `covenant-courier > neverlost` | `neverlost.trust_bundle.v1` | planned -> **emitting** | emitted_by consumer, witness nfl | `courier.ps1 trust-import` imports a pinned NeverLost trust bundle as a trust root. |
| `covenant-courier > nfl` | `constellation.integration.receipt.v1` (witnessing) | planned | NFL reads Courier's receipt folders in inbox mode `receipt` | No Courier code calls NFL. NFL needs the inbox entries below. |
| `global-workbench > covenant-courier` | `covenant_courier.settings.v1` (to be defined with the plugin) | planned | emitted_by consumer | A Courier plugin manifest for the workbench (draft in section 6). |

`contract_families` for the registry entry: `covenant_courier.*` (product), `vtp.*` (transport), and
`constellation.integration.receipt.v1` (as an emitter).

Layer stays `workflow.governed-messaging`. Dependency direction is respected: Courier (communications)
depends on identity / trust / policy / preservation services, never the other way round.

## 4. What Courier needs from each service

### Constellation

1. Apply sections 2 and 3 to `registry/services.json` and `registry/integrations.json`, re-publish.
2. After that, set the two Courier-emitted records (`covenant-courier > covenant-gate`,
   `covenant-courier > neverlost`) to receipt state `emitting`: both have positive and negative tests
   (`scripts/_selftest_covenant_courier_deliver_v1.ps1`, `scripts/_selftest_courier_trust_import_v1.ps1`,
   `scripts/_selftest_constellation_integration_receipts_v1.ps1`).
3. Optionally publish the registered integrations machine-readably into `.constellation/` (NFL's
   proposal 0002 asks for the same) so Courier can refuse to emit for an unregistered edge.

### Covenant Gate

1. A rule in the canonical base policy for `enforcement_point: eval.request` with
   `action.type: courier.deliver`. Today Covenant Gate's real evaluator answers `DEFAULT_DENY` for every
   Courier delivery (proven in this session against the real evaluator), so a profile with
   `covenant_gate: required` can only quarantine or reject.
2. Signed decision documents: a detached ssh signature (`ssh-keygen -Y sign`, namespace
   `covenant-gate/decision`) over the canonical `covenantgate.eval_output.v1` bytes, by a principal in
   the NeverLost trust bundle. Courier already verifies such signatures; without them, document mode is
   unusable and only invoke mode (Courier runs Covenant Gate's sealed evaluator from a configured
   checkout) works.
3. Keep `CG-CanonBytes` and the `evaluation_id` formula stable: Courier recomputes both.

### NeverLost

1. Issue principals for Courier nodes (for example `single-tenant/device_agent/courier/<node-id>`)
   with namespace `courier/message`, and for Covenant Gate's decision signer with namespace
   `covenant-gate/decision`.
2. Publish the trust bundle hash out of band (`verify_trust_bundle_v1.ps1` already prints
   `TRUST_BUNDLE_SHA256=`); Courier pins it on import.

### NFL

Add receipt-mode inboxes (output of `courier.ps1 integration-receipts -Action nfl-inboxes`):

    { "name": "courier-covenant-gate-receipts", "path": "../covenant-courier/proofs/integration_receipts/covenant-courier__covenant-gate", "mode": "receipt", "integration": "covenant-courier>covenant-gate" }
    { "name": "courier-neverlost-receipts", "path": "../covenant-courier/proofs/integration_receipts/covenant-courier__neverlost", "mode": "receipt", "integration": "covenant-courier>neverlost" }

These are refused (`NFL_INGEST_UNATTRIBUTED` / unregistered) until section 3 is in the registry.

### Rebound

1. Replace the bridge's "run Courier's fast smoke" proof with a real delivery: write a
   `covenant_courier.message.v1` + payload, call `courier.ps1 deliver`, keep `product_receipt.json`,
   and write Rebound's `constellation.integration.receipt.v1` (consumer `rebound`, provider
   `covenant-courier`, contract `covenant_courier.message.v1`, `request_sha256` = SHA-256 of the
   message file bytes sent, `response_sha256` = SHA-256 of `product_receipt.json`, `carried` =
   `[{ "contract": "covenant_courier.product_receipt.v1", "sha256": <same> }]`, outcome `ok` for exit 0,
   `refused` for exit 42, `failed` otherwise).
2. Fix the default `-CourierRoot` in `rebound_courier.ps1`: it assumes Courier is a sibling folder of
   Rebound (`..\covenant-courier`), but Courier lives in `_Covenant-systems\` and Rebound in
   `_Venture-Systems\`. Pass the root explicitly (or read it from configuration); never guess it.
3. Run Courier with the current PowerShell host, not a hard-coded `%WINDIR%\...\powershell.exe`.

### Global Workbench

Add the plugin manifest in section 6 (or the owner's variant) to `workbench-plugins/covenant-courier/`.
`vtp_tray_contract_v1.json` in this repository already states the rule the UI must follow: UI only,
never redefine VTP transport law.

## 5. Not changed

- Courier keeps working with no other service present: `courier.ps1 verify` and `verify-all` need
  none of them.
- The four registered Rebound contracts are unchanged on the wire.
- Release posture stays "developer preview" (see `SECURITY.md`, `docs/SECURITY_HARDENING_PLAN.md`).

## 6. Draft Global Workbench plugin manifest

```json
{
  "schema": "global_workbench.plugin_manifest.v1",
  "plugin_id": "covenant-courier",
  "display_name": "Covenant Courier",
  "version": "0.1.0",
  "project_type": "governed_messaging",
  "description": "Governed delivery: policy decisions, product receipts and chain, transport frames, quarantine, integration receipts.",
  "resource_types": ["message", "receipt", "frame", "policy_bundle"],
  "commands": ["covenantCourier.openReceipts", "covenantCourier.openQuarantine", "covenantCourier.verifyChain"],
  "panels": ["covenantCourier.receiptPanel", "covenantCourier.quarantinePanel", "covenantCourier.integrationPanel"],
  "inspectors": ["covenantCourier.receiptInspector", "covenantCourier.deliveryInspector"],
  "default_workspace": "covenantCourier.receipts",
  "capabilities": ["workbench.navigation", "workbench.commands", "workbench.panels", "workbench.inspectors", "workbench.receipts.read"],
  "navigation": { "activity_entry": "Covenant Courier", "sidebar_root": "Delivery" },
  "settings_schema": "covenant_courier.settings.v1"
}
```

## 7. Tests that back this proposal

| Claim | Proof |
|---|---|
| Delivery path, every outcome writes a receipt, chain is append-only and tamper-evident | `scripts/_selftest_covenant_courier_deliver_v1.ps1` (29 cases, 30 with `COVENANT_GATE_ROOT` set) |
| Integration receipts match `constellation.integration.receipt.v1` byte for byte | `scripts/_selftest_constellation_integration_receipts_v1.ps1` (14 cases) |
| NeverLost import, pinned, derived like NeverLost, refusals recorded | `scripts/_selftest_courier_trust_import_v1.ps1` (7 cases) |
| VTP v2 secure core | `vtp2.ps1 verify` |
| Everything together | `courier.ps1 verify-all` |
