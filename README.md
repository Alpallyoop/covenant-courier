# Covenant Courier

Covenant Courier is a governed secure message and notification courier system.

It is built around a simple rule:

    no delivery without policy, receipts, and traceability

Covenant Courier is the product layer. VTP is the transport/protocol substrate underneath it.

## What this is

Covenant Courier packages product messages, sends them through VTP, receives and policy-gates frames, emits product-level receipts, and builds a tamper-evident receipt chain.

It is not a general chat app.

It is not only a packet transport.

It is not meant to run invisibly in the background by default.

The current product core is local-first and CLI-driven. Runtime/proof state is intentionally ignored by git.

## Current status

Product core: governed delivery, verified receive, append-only receipt chain, Constellation
integration receipts, Covenant Gate adapter, NeverLost trust import. VTP v1 substrate and the VTP v2
secure core are green. Facts and limits: `docs/canonical/CURRENT_STATE.md`.

Primary product proof:

    .\courier.ps1 verify          ->  COVENANT_COURIER_VERIFY_OK
    .\courier.ps1 verify-all      ->  COVENANT_COURIER_VERIFY_ALL_OK, COVENANT_COURIER_VERIFY_OK

`verify` = schema test, prepare, send, receive (positive and negative), receipts, receipt chain and the
VTP substrate (`.\vtp.ps1 verify` -> `VTP_VERIFY_ALL_OK`). `verify-all` adds the governed-delivery
self-test (29 cases; 30 with a Covenant Gate checkout), the integration-receipt self-test (14), the NeverLost trust-import self-test (7),
a verification of every integration receipt on disk, and the VTP v2 self-test (`.\vtp2.ps1 verify`,
needs the .NET 10 SDK).

## Command map

### Product CLI

    .\courier.ps1 help
    .\courier.ps1 schema-test
    .\courier.ps1 prepare  [-PayloadText ..] [-PolicyProfile default|public|confidential]
    .\courier.ps1 send     [-PayloadText ..] [-PolicyProfile ..]      prepare + deliver (demo nodes)
    .\courier.ps1 deliver  -MessagePath <message.json> -PayloadPath <file> [-OutDir <dir>]
                           [-CovenantGateRoot <dir> | -CovenantGateDecisionPath <eval_output.json>]
    .\courier.ps1 receive
    .\courier.ps1 receive-negative
    .\courier.ps1 receipts
    .\courier.ps1 receipt-chain
    .\courier.ps1 trust-import -TrustBundlePath <file> -ExpectedSha256 <sha> [-NeverLostRoot <dir>]
    .\courier.ps1 integration-receipts [-Action verify|list|nfl-inboxes]
    .\courier.ps1 verify
    .\courier.ps1 verify-all

`deliver` exit codes: 0 sent, 42 refused by policy (rejected or quarantined), anything else failed.
The full caller contract is in `docs/integrations/README.md`.

### VTP protocol CLI

    .\vtp.ps1 verify | transmit -To node-beta | wire-smoke | wire-ingest | wire-negative | dlp-test | receipts
    .\vtp2.ps1 verify | build | init | bundle | rotate | trust | session-init | session-accept | encrypt | decrypt | status | kat
    .\courier-secure.ps1 init|bundle|trust|connect|accept|send|receive|inspect|verify     (VTP v2 wrapper)

## Product flow

    prepare covenant_courier.message.v1 + payload
    deliver:
      validate message, recompute payload hash
      delivery policy for the message's profile (recipient, session, size, encoding, restricted terms)
      optional Covenant Gate decision (off | advisory | required per profile)
      write covenant_courier.policy_decision.v1 and covenant_courier.notification.v1
      allowed  -> sign covenant_courier.delivery.v1 (message + decision + notification + payload)
                  and send it as a VTP frame to the recipient node
      refused  -> reject, or quarantine under runtime/product_messages/quarantine/
      product receipt for every outcome, appended and chained
    receive:
      recipient node policy loop, listener signature + frame hash check
      envelope bound to the sender's receipt (message ID, payload hash, node, session, decision)
      release to runtime/product_messages/inbox/<node>/<message_id>/, accepted or rejected receipt

## Receipts

    proofs\receipts\covenant_courier_product.ndjson         product receipts (covenant_courier.product_receipt.v1)
    proofs\receipts\covenant_courier_product.chain.ndjson   append-only chain (covenant_courier.product_receipt_chain.v1)
    proofs\receipts\courier_transport.ndjson                transport receipts
    proofs\receipts\vtp_udp_wire_ingest.ndjson              UDP wire ingest receipts
    proofs\integration_receipts\<consumer>__<provider>\receipts.ndjson
                                                            constellation.integration.receipt.v1 (Courier as emitter)

`product_receipt.json` written by `deliver` holds exactly the receipt line, so its SHA-256 equals the
chain's `receipt_sha256`. The chain re-verifies every existing entry before appending; an edited,
removed or reordered receipt fails with `COVENANT_COURIER_RECEIPT_CHAIN_FAIL:TAMPER_DETECTED`.

The proofs directory is intentionally ignored by git.

## Schemas

    schemas\covenant_courier.message.v1.json
    schemas\covenant_courier.notification.v1.json
    schemas\covenant_courier.policy_decision.v1.json
    schemas\covenant_courier.product_receipt.v1.json
    schemas\covenant_courier.delivery.v1.json
    schemas\covenant_courier.product_policy.v1.json
    schemas\covenant_courier.product_receipt_chain.v1.json

Delivery policy: `policy\courier_product_policy_v1.json`. Schema test: `.\courier.ps1 schema-test`.

## Constellation and integrations

Covenant Courier is the `covenant-courier` service (family `covenant`, layer
`workflow.governed-messaging`) in the Constellation ecosystem. It works with no other service present.

| Edge | Courier's side |
|---|---|
| Rebound -> Courier (registered) | `courier.ps1 deliver` contract; Rebound carries SHA-256 of `product_receipt.json` |
| Courier -> Covenant Gate (proposed) | invoke Covenant Gate's sealed evaluator or verify a signed decision; integration receipt per consultation |
| Courier -> NeverLost (proposed) | `trust-import` of a pinned trust bundle; integration receipt per import |
| NFL (witness) | reads `proofs/integration_receipts/*` as receipt-mode inboxes |
| Global Workbench (proposed) | draft plugin manifest |

Details: `docs/integrations/README.md`. Proposed registry changes and what Courier needs from each
service: `docs/proposals/0001-covenant-courier-ownership-and-integrations.md`.

## Docs

    docs\canonical\CURRENT_STATE.md          what runs today, known limits
    docs\integrations\README.md              delivery contract, Covenant Gate, NeverLost, NFL
    docs\proposals\0001-...md                 ownership and integration proposal for Constellation
    docs\COVENANT_COURIER_PRODUCT_SPEC_V1.md
    docs\COVENANT_COURIER_THREAT_MODEL_V1.md
    docs\COVENANT_COURIER_RELEASE_CHECKLIST_V1.md
    spec\VTP_V2_SECURITY_PROTOCOL.md
    docs\VTP_WIRE_TRACE_MODEL.md, docs\VTP_WIRE_KEY_AND_RECEIPTS.md
    docs\ROADMAP.md

## Runtime and git hygiene

Ignored local state: `proofs/`, `registry/`, `runtime/`, `release/`, `covenant-courier_release_smoke/`,
and VTP v2 build output (`src/Vtp2/bin`, `src/Vtp2/obj`). These hold proof outputs, sessions, keys,
receipts, frames and build output and must not be committed.

## Working remotely

Prerequisites (Linux cloud session): PowerShell 7 (`pwsh`), OpenSSH `ssh-keygen`, and the .NET 10 SDK
for VTP v2. On Windows the same commands run under Windows PowerShell 5.1 (`ssh-keygen` from
`C:\Windows\System32\OpenSSH`, used automatically when present).

Commands run in a Linux session on 2026-10-15, all green:

    pwsh -File courier.ps1 verify -RepoRoot .        # product + VTP substrate
    pwsh -File courier.ps1 verify-all -RepoRoot .    # + delivery, integration receipts, trust import, VTP v2
    pwsh -File scripts/_smoke_covenant_courier_release_fast_v1.ps1 -RepoRoot .
    pwsh -File scripts/_RUN_vtp_conformance_v1.ps1 -RepoRoot .   (and the other scripts/_RUN_*.ps1)
    pwsh -File scripts/FULL_GREEN_RUNNER_COURIER_STANDALONE_v1.ps1 -RepoRoot .

Off Windows, VTP v2 state is sealed under a key file: create 32 random bytes with mode 0600 and set
`VTP2_STATE_KEY_FILE` to its path (the self-test does this itself). Windows-only: DPAPI state
protection for VTP v2 and the scheduled-task node loop (`vtp.ps1 install-node`). Nothing else needs the
home computer.

## Current limitations

This is a local CLI product-core checkpoint, not a polished public app release.
It is also not a production end-to-end encrypted messenger. The current key exchange,
endpoint storage, and transport adapters are development prototypes and are unsuitable
for defense or classified deployment.

Known remaining work:

    product delivery over VTP v2 sessions (today: signed, hash-bound frames without payload encryption)
    in-session DH ratchet for VTP v2
    fixed binary wire header
    signers issued by NeverLost instead of local bootstrap keys
    service mode only if explicit
    UI through Global Workbench
    public release package for the current product core (v0.1.5 predates governed delivery)

## Release posture

Current state:

    product-core green checkpoint, developer preview

Not yet:

    public v1 release

Before public release, the release checklist and threat model must be reviewed and the command surface must remain simple for non-developer users.
## Release status

Current release status:

    docs\RELEASE_STATUS.md

Final product-core checkpoint tag:

    covenant-courier-product-core-v1-finalized
## Tags

Tag guidance:

    docs\TAGS.md

Authoritative final product-core tag:

    covenant-courier-product-core-v1-finalized-green-fixed
## Distribution

Distribution instructions:

    docs\DISTRIBUTION.md

Current distributable release:

    covenant-courier-v0.1.5-product-core

Earlier v0.1.0 through v0.1.4 release assets are superseded.
## Public preview docs

Current public preview:

    covenant-courier-v0.1.5-product-core

Start here:

    docs\QUICKSTART.md
    docs\PUBLIC_RELEASE.md
    docs\VERIFY_RELEASE.md
    docs\DISTRIBUTION.md
    docs\FAQ.md
    SECURITY.md
    CHANGELOG.md

Download:

    https://github.com/ScrappyHub/covenant-courier/releases/tag/covenant-courier-v0.1.5-product-core
