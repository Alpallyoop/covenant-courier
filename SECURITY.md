# Security Policy

## Supported release

Current supported preview release:

    covenant-courier-v0.1.5-product-core

Earlier v0.1.0 through v0.1.4 release assets are superseded.

## Reporting security issues

Please report security issues privately.

Do not open a public issue with exploit details, private keys, tokens, or sensitive operational data.

## Sensitive files

Do not commit or publish:

    private keys
    API tokens
    webhook secrets
    service role keys
    local runtime outputs
    local proof receipts that contain sensitive operational context

Generated local folders should remain ignored:

    proofs/
    registry/
    runtime/
    release/

## Preview limitations

This release is a local CLI developer preview.

It is not a production key-management system, hosted service, or polished end-user application.
It is not approved for operational, defense, classified, or safety-critical use.
The current join-code and local wire-key modes are transitional development mechanisms;
they do not provide forward secrecy or post-compromise security.

Do not describe this preview as equivalent or superior to Signal. Production readiness
requires an independently reviewed authenticated key agreement and message ratchet,
protected endpoint key storage, encrypted data-at-rest storage, and external assessment.

## Cryptographic profile

The Windows PowerShell 5.1 compatibility profile currently uses:

    PBKDF2-HMAC-SHA256, 200000 iterations
    AES-256-CBC with HMAC-SHA256, encrypt-then-MAC
    independent 256-bit encryption and MAC keys
    random 128-bit salts and IVs

Algorithm identifiers in serialized envelopes must match the implementation exactly.
The HMAC is verified before CBC decryption. This profile is transitional and must not
be treated as a substitute for a reviewed asynchronous messaging protocol.

## Product delivery

`courier.ps1 deliver` sends a `covenant_courier.delivery.v1` envelope signed with OpenSSH
(`ssh-keygen -Y sign`, namespace `courier/message`) by the sender node's registered principal. The
receiver verifies the signature, the frame hash and the envelope's binding to the sender's product
receipt before releasing anything. By default the envelope is not encrypted: on the filesystem-drop
transport the payload is readable by anyone who can read the node folders. A profile with
`payload_encryption: vtp2` (the shipped `confidential` profile) sends the payload only as a VTP v2
`vtp.message.v3` under the session bound with `courier.ps1 secure-session`; with no binding nothing is
sent (quarantined); a bound session always carries the payload encrypted, and the receiver refuses a
plaintext envelope on a bound session or for a profile its own policy marks vtp2 (downgrade). A sealed
envelope does not carry the sender's free-text preview. Not covered: a process killed mid-delivery can
leave a plaintext temp file under `runtime/tmp`; VTP v2 commits replay state on decrypt, so a receive that
crashes after decrypt cannot be retried for that message. The
fingerprints in the binding must be verified out of band when the nodes are on different machines
(`-LocalPair` reads both from local state). The message `origin` is asserted by the sender (covered by
its signature), not authenticated by Covenant Gate. Released inbox payloads are plaintext on disk.

## VTP v2 secure core

Suite `VTP2-P256-HKDFSHA256-CHACHA20POLY1305` (spec: `spec/VTP_V2_SECURITY_PROTOCOL.md`). Device state
is DPAPI-protected on Windows. Elsewhere it is sealed with ChaCha20-Poly1305 under a 32-byte key file
named by `VTP2_STATE_KEY_FILE` (owner-only permissions required); there is no plaintext state mode.
Revision 2.1 adds an in-session DH ratchet: a copied state stops decrypting once both devices have used
ratchet keys made after the copy (passive adversary). An active adversary holding a copy can still inject
and hold a man-in-the-middle position until the session is closed (`vtp2.ps1 session-close`) and
re-established; the real device's messages then fail, which is the visible sign. Whole-state rollback is
not detected, and keys in managed memory and in old copies of the state file are not reliably erased.
The protocol and implementation have had internal (AI) review only; an independent cryptographic review is
required before relying on them against a capable adversary.

## Signature verification

Covenant Courier uses OpenSSH signature verification for the local preview flow. A runtime signature
(frames, delivery envelopes, Covenant Gate decision documents) is accepted when it verifies, for the
expected identity and namespace, against one of two trust roots: `proofs/trust/allowed_signers` (this
machine's local bootstrap signer and pinned VTP peers) and `proofs/trust/neverlost/allowed_signers`
(signers imported from a pinned NeverLost trust bundle with `courier.ps1 trust-import`). The published
release signers (`trust/allowed_signers`) are trusted only with `-IncludeReleaseSigners`, which only the
test-vector checks pass: a public signed test vector can never be framed and accepted as a runtime message.

The verifier reads the message and signature once, verifies exactly those bytes from a private staging
folder and prints their SHA-256 (`COURIER_SIGNATURE_VERIFIED_SHA256`), which the listener compares with the
frame's hash. Identities and namespaces are checked against a strict character set before they reach
ssh-keygen; links and inputs over 4 MB are refused. The local signer's `allowed_signers` line is limited to
`namespaces="courier/message"`, VTP peer pins likewise; a Covenant Gate decision signer must be a principal
of its own (never a node principal).

The release includes public allowed-signers material for verifying bundled preview test vectors.

## Audit 2026-11-04: what is enforced

- **The receiver decides for itself.** `courier.ps1 receive` re-runs the local delivery policy (recipient
  allow-list, size, text, restricted terms) with its own `policy/` file on the bytes it received, under the
  profile the session names (else the message's), and builds the inbox notification from that profile.
  A sender's `policy_decision` and `notification` are claims, not decisions. Covenant Gate is not
  re-consulted on receive (see open items).
- **The policy is the installation's own.** `deliver -PolicyPath` accepts only a file under `<repo>/policy/`.
  A session opened with `-SessionPolicyRef <profile>` fixes the profile; a message naming another is rejected.
- **Restricted terms are matched on folded text** (NFKD, format characters and combining marks removed, NFC,
  lower case), in the payload (UTF-8, and UTF-16 when the text carries NULs), the preview, the identities and
  the organization. A payload that is not text is never allowed under a profile with a dictionary
  (`PAYLOAD_NOT_SCANNABLE`).
- **Covenant Gate invoke mode runs only a pinned checkout** (`courier.ps1 cg-pin -CovenantGateRoot <dir>`:
  root plus SHA-256 of the evaluator, base policy and overlay, in `proofs/trust/covenant_gate_pin.json`). An
  unpinned root (environment variable or argument alone) is not run and counts as unavailable; changed pinned
  files are refused (`COVENANT_GATE_PIN_MISMATCH`). The checked bytes are what runs.
- **Sessions are opened once.** Opening an open session again with the same bindings is a no-op; a closed
  session is never reopened; a session id is never rebound.
- **Transport.** Frames: `message_rel` is one file under `payload/`, `signature_rel` is exactly
  `<message>.sig`, no links anywhere in a frame, size limits, the verifier is called with an argument array,
  the verified bytes' hash must equal the frame hash, the message is re-hashed after the move into the
  node's own folder, and a per-node index of accepted payload hashes refuses a signed payload re-framed under
  a new frame id. The policy loop moves allowed frames to `runtime/nodes/<node>/approved/`, which is what the
  listener reads (nothing written to the drop folder after the policy decision reaches it). Rejected or
  duplicate frames are kept as evidence, never deleted through. VTP peer pins compute the fingerprint from
  the key, validate principal and key, and refuse a second key for a pinned principal.
- **Receipts.** Receive verifies the product receipt chain (and refuses unchained lines) before using the log;
  appends are exclusive. The inbox entry for a message is created once (an existing one is a replay).
- **Code from the installation.** `courier.ps1`, `vtp.ps1` and the scripts they call run child scripts from
  their own folder, never from `-RepoRoot` (the data root) or the current folder.
- **Local files.** The UDP wire key envelope is created owner-only; UDP ingest binds 127.0.0.1 by default and
  ignores stray datagrams; the unused, unvalidated `vtp_udp_wire_listen_once_v1.ps1` was removed. IDs that
  become folder names refuse a trailing dot and reserved device names.

## Closed later on 2026-11-04

- **Receiver-side gate evidence.** When Covenant Gate allows a delivery and signs its decision, the envelope
  carries it (`covenant_gate_decision`: the exact `covenantgate.eval_output.v1` bytes, the signature, the
  signer). A receiver whose own profile requires the gate refuses an envelope without it, and checks the
  signature (the profile's `covenant_gate_signer`, namespace `covenant-gate/decision`, against its trust roots),
  the `input_hash` rebuilt from the message and its own registry principals, `decision: allow`, and the pinned
  policy hash. In invoke mode the sender has the pinned Covenant Gate checkout sign the decision with its own
  NeverLost-issued key (`scripts/cg_sign_decision_v1.ps1`, Covenant Gate PR #7; pinned and run from the checked
  bytes); without that signer a required-gate delivery waits for approval
  (`COVENANT_GATE_DECISION_UNSIGNED`). The shipped `confidential` profile names
  `single-tenant/device_agent/covenant-gate` as the signer; its key reaches the trust roots through a NeverLost
  trust import.
- **Signed receipt chain head.** After every append the chain's entry count and hash are signed by the
  installation's receipt signer (`courier-receipts@local`, namespace `courier/receipt-chain`, key created on
  first use, owner-only). Every chain run checks it; rewriting the log and chain together, forging the head or
  dropping it is refused. Restoring an older signed state as a whole still needs an outside witness.
- **Gate decisions are bound to the current gate policy.** `courier.ps1 cg-pin` records the Covenant Gate
  `policy_hash` (probed from the pinned evaluator, or given with `-PolicyHash` on a node without a checkout);
  decisions under any other policy are refused on send and on receive (`CG_POLICY_NOT_PINNED`,
  `CG_POLICY_HASH_NOT_PINNED`). A decision is also bound to one message (message id, payload hash, session,
  principals), so it cannot be reused for another. It carries no time, so within one Covenant Gate policy a
  decision for a message stays valid until that message is delivered once (inbox entries are created once).

## Still open

- Restoring the whole receipt state to an earlier signed point needs an outside witness (NeverLost or
  Constellation).
- VTP v2 binding fingerprints given for a two-machine session are recorded, not checked against VTP v2 state.
- JSON parsing keeps the last of duplicate keys on PowerShell 7.
