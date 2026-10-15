# Current state - Covenant Courier

Recorded 2026-10-15. Describes what the implementation does today, not the target. Identity, ownership
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
| VTP v1 transport | Frames, listener, node loop, outbox, replay guard, UDP wire adapter (bindings from the session registry). | `vtp.ps1 verify`, `_RUN_*` suites |
| VTP v2 secure core (`vtp2.ps1`) | X3DH-style P-256 handshake, per-direction symmetric chains, ChaCha20-Poly1305, rotation, strict decoding, KATs. Not yet used by the product delivery path. | `vtp2.ps1 verify` |

## Known limits (true today)

- Developer preview. Not a production E2E messenger; see `SECURITY.md` and
  `docs/SECURITY_HARDENING_PLAN.md`. Product delivery frames are signed and hash-bound but not
  encrypted at rest or in the filesystem-drop transport; payload confidentiality on the wire exists only
  in the v1 UDP adapter (transitional AES-CBC+HMAC with a local key envelope) and in VTP v2, which the
  product path does not use yet.
- VTP v2 has no in-session DH ratchet (post-compromise recovery needs a new session).
- Local signing keys are created by `courier_bootstrap_local_trust_v1.ps1` under `proofs/keys/` without
  a passphrase (local development trust). Production signers should come from NeverLost.
- `courier.ps1 receive` processes the newest unsettled sent frame; there is no inbox subscription or
  background service (the scheduled-task node loop is Windows-only and opt-in).
- Covenant Gate currently answers `DEFAULT_DENY` for `courier.deliver` (no rule in its canonical policy).
- Several older self-tests write into tracked `test_vectors/` folders, so running them changes
  tracked files (pre-existing behaviour, left as is).

## Platforms

Every PowerShell script runs on Windows PowerShell 5.1 and PowerShell 7 (Linux and Windows). VTP v2
targets `net10.0`: DPAPI-protected state on Windows, `VTP2_STATE_KEY_FILE` sealed state elsewhere.
The scheduled-task node install (`vtp.ps1 install-node`) is Windows-only.
