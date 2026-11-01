# Current state - Covenant Courier

Recorded 2026-10-15, updated 2026-11-01. Describes what the implementation does today, not the target. Identity, ownership
and integrations proposed for the registry: `docs/proposals/0001-covenant-courier-ownership-and-integrations.md`.

## What runs

| Area | State | Proof |
|---|---|---|
| Governed delivery (`courier.ps1 deliver` / `send`) | Working. Message validation, delivery policy (`policy/courier_product_policy_v1.json`), policy decision + notification documents, signed `covenant_courier.delivery.v1` envelope sent as a VTP frame, product receipt for every outcome. | `scripts/_selftest_covenant_courier_deliver_v1.ps1` |
| Receive (`courier.ps1 receive`) | Working. Node policy loop, listener signature + hash check, envelope binding check against the sender's receipt, inbox release, accepted or rejected receipt. | same, plus `courier.ps1 verify` |
| Product receipt chain | Append-only and tamper-evident (re-verifies every existing entry before appending). | same |
| Constellation integration receipts | Emitted by Courier for `covenant-courier > covenant-gate` and `covenant-courier > neverlost`, byte-exact to `constellation.integration.receipt.v1`. | `scripts/_selftest_constellation_integration_receipts_v1.ps1` |
| Covenant Gate adapter | Invoke mode (Covenant Gate's sealed evaluator, out of process) and signed-document mode. Off by default. | deliver selftest (+ real Covenant Gate when `COVENANT_GATE_ROOT` is set) |
| NeverLost trust import | Pinned import of a principals trust bundle into a third trust root. | `scripts/_selftest_courier_trust_import_v1.ps1` |
| NeverLost-issued node signers | `courier.ps1 node-signer` creates a node key for `single-tenant/device_agent/courier/<node-id>` and switches the node's registry principal only after a trust import carries that exact key. | `scripts/_selftest_courier_node_signer_v1.ps1` |
| VTP v1 transport | Frames, listener, node loop, outbox, replay guard, UDP wire adapter (bindings from the session registry). | `vtp.ps1 verify`, `_RUN_*` suites |
| VTP v2 secure core (`vtp2.ps1`) | X3DH-style P-256 handshake, per-direction symmetric chains, ChaCha20-Poly1305, rotation, strict decoding, KATs. | `vtp2.ps1 verify` |
| Payload encryption in delivery | Profiles with `payload_encryption: vtp2` (shipped: `confidential`) send the payload only as a `vtp.message.v2` under the VTP v2 session bound to the Courier session (`courier.ps1 secure-session`); unbound sessions quarantine; a bound session is always sealed (payloads up to 600,000 bytes); receive decrypts and refuses a plaintext downgrade. | deliver selftest (VTP v2 cases) |
| Message origin | Optional `origin` (`human`/`ai`/`service`) carried to Covenant Gate as `action.origin` (`unspecified` when absent). | deliver selftest |

## Known limits (true today)

- Developer preview. Not a production E2E messenger; see `SECURITY.md` and
  `docs/SECURITY_HARDENING_PLAN.md`. Product delivery frames are signed and hash-bound but not
  encrypted at rest or in the filesystem-drop transport unless the profile requires VTP v2 payload
  encryption; otherwise payload confidentiality on the wire exists only in the v1 UDP adapter
  (transitional AES-CBC+HMAC with a local key envelope). Released inbox payloads are plaintext on disk.
- VTP v2 has no in-session DH ratchet (post-compromise recovery needs a new session).
- Local signing keys are created by `courier_bootstrap_local_trust_v1.ps1` under `proofs/keys/` without
  a passphrase (local development trust). Production signers should come from NeverLost
  (`courier.ps1 node-signer`); node keys it creates are also unencrypted files under `proofs/keys/`.
- `courier.ps1 receive` processes the newest unsettled sent frame; there is no inbox subscription or
  background service (the scheduled-task node loop is Windows-only and opt-in).
- Covenant Gate's `main` answers `DEFAULT_DENY` for every `courier.deliver` until its branch
  `claude/courier-deliver-human-rule` (rule `allow.courier.deliver.human`, proposal 0025) is merged; after
  that only `origin: human` is allowed. `origin` is sender-asserted, not authenticated by Covenant Gate.
- Several older self-tests write into tracked `test_vectors/` folders, so running them changes
  tracked files (pre-existing behaviour, left as is).

## Platforms

Every PowerShell script runs on Windows PowerShell 5.1 and PowerShell 7 (Linux and Windows). VTP v2
targets `net10.0`: DPAPI-protected state on Windows, `VTP2_STATE_KEY_FILE` sealed state elsewhere.
The scheduled-task node install (`vtp.ps1 install-node`) is Windows-only.
