# VTP v2 Security Protocol

Status: implementation target. VTP v1 is not security-compatible with v2. Revision 2.1 (2026-11-01) adds
the in-session DH ratchet (section 6.1); sessions created before 2.1 must be re-established.

## 1. Scope and claims

VTP v2 is an asynchronous, offline-capable, one-to-one encrypted messaging protocol.
It provides authenticated device identity, confidentiality and integrity of message content
and protected metadata, replay rejection, forward secrecy after message-key deletion, and
in-session post-compromise recovery through a DH ratchet (section 6.1): once both devices have
used ratchet keys generated after a state compromise, the compromised state no longer decrypts.
The implementation has not been independently reviewed (see section 11).

It does not hide IP addresses, packet timing, packet length, device compromise, traffic
volume, or the existence of a relationship. It is not a certification for classified use.

## 2. Mandatory suite

The only v2 suite is `VTP2-P256-HKDFSHA256-CHACHA20POLY1305`:

- ECDSA P-256/SHA-256 device identity signatures
- ECDH P-256 identity, signed-prekey, one-time-prekey, and ratchet agreement
- HKDF-SHA-256 with explicit labels and transcript hashes
- ChaCha20-Poly1305 with 256-bit keys, 96-bit nonces, and 128-bit tags
- SHA-256 identifiers and transcript digests
- CSPRNG-generated 128-bit identifiers and 256-bit random state secrets

There is no algorithm negotiation. Unknown suites and versions fail closed.

## 3. Canonical encoding

Signed and authenticated structures use deterministic UTF-8 JSON: object keys are sorted
ordinally, arrays retain order, strings use minimal JSON escaping (only `"`, `\` and control
characters are escaped; `+`, `/` and non-ASCII are written as UTF-8), numbers use their JSON lexical
form, and no insignificant whitespace or BOM is present. Decoders reject duplicate keys,
unknown security-critical fields, excessive depth, and inputs above their command-specific
limits.

## 4. Device identity and prekey bundle

Each device owns:

- an ECDSA identity signing key `ISK`
- a long-term ECDH identity key `IDK`
- a rotating ECDH signed prekey `SPK`
- a pool of single-use ECDH one-time prekeys `OPK[i]`

Private material is stored as a DPAPI CurrentUser protected state blob on Windows. On other
platforms the state is sealed with ChaCha20-Poly1305 under a 32-byte operator key named by the
`VTP2_STATE_KEY_FILE` environment variable; the key file must be owner-only (no group or other
permission bits) and the tool refuses to read or write state without it (`VTP2_STATE_KEY_REQUIRED`).
There is no plaintext state mode. A bundle contains public ISK, IDK, SPK, expiry, sequence
number, and OPK public keys, and no other fields. ISK signs the canonical bundle body. Import
pins the SHA-256 fingerprint of ISK through an explicit out-of-band comparison. A changed
identity key is rejected (`VTP2_IDENTITY_CHANGED`) unless an explicit replacement ceremony is
performed. A bundle whose sequence is lower than the last one accepted for that device is a
rollback and is rejected (`VTP2_BUNDLE_ROLLBACK`).

### 4.1 Rotation

`rotate` replaces SPK, refills the OPK pool to 20, increments the bundle sequence and sets a
fresh 30-day expiry. Identity keys never change on rotation. The previous SPK is retained for
exactly one rotation so that session requests made against the immediately previous bundle can
still be accepted; a request naming any older sequence fails with `VTP2_STALE_BUNDLE_SEQUENCE`.
A device whose own bundle has expired must rotate before publishing a bundle.

## 5. Asynchronous session establishment

The initiator validates the recipient bundle signature, expiry, device binding, and pinned
identity fingerprint, selects one OPK uniformly at random, creates ephemeral `EK-A`, and computes:

    DH1 = ECDH(IDK-A, SPK-B)
    DH2 = ECDH(EK-A, IDK-B)
    DH3 = ECDH(EK-A, SPK-B)
    DH4 = ECDH(EK-A, OPK-B)

The responder computes the corresponding secrets. Each DHi is the SHA-256 of the raw ECDH shared
secret (.NET `DeriveKeyFromHash`). HKDF over DH1||DH2||DH3||DH4, salted by the canonical
handshake transcript hash (the signed handshake body without `signature_b64`, since ECDSA
signatures are malleable), produces the initial root key and directional
chain keys. The handshake body carries the recipient device ID, recipient ISK fingerprint and
the recipient bundle sequence it was built against, and the initiator signs it with ISK-A. The
responder validates the signature, that the request names its own fingerprint, and the pinned
initiator identity before consuming OPK-B. OPK consumption and session
creation occur in one locked, atomic state transition; reuse is rejected.

## 6. Message key chains

Each direction has an independent chain key and counter. For every message:

    message_key = HMAC-SHA256(chain_key, 0x01)
    next_chain  = HMAC-SHA256(chain_key, 0x02)

The old chain and message keys are zeroed and not persisted. Each envelope authenticates
the schema, suite, session ID, sender and recipient device IDs, message number, message ID,
creation time, expiry, content type, nonce, and ciphertext length as AEAD associated data (the
canonical encoding of every envelope field except `ciphertext_b64` and `tag_b64`), including the
sender's ratchet public key and previous chain length (section 6.1).

Skipped message keys are bounded to 100 per session in total (across chains, not merely per gap),
keyed by (SHA-256 of the sender's ratchet public key, message number), and are protected at rest
with the rest of the state. A new session handshake replaces both chains and the root using fresh
ephemeral and one-time prekey contributions.

### 6.1 In-session DH ratchet (2.1)

Each device holds a current P-256 ratchet key pair; every envelope carries the sender's ratchet
public key (`ratchet_public_b64`, SPKI) and `previous_chain_length` (the number of messages it sent
on its previous sending chain). With `RK` the root key and

    KDF_RK(RK, dh) = HKDF-SHA256(ikm = dh, salt = RK, info = "VTP2 ratchet", 64 bytes) -> (RK', CK)

the session starts as follows (`RK0`, `CK-i2r`, `CK-r2i` from section 5):

- Responder: ratchet key pair = its signed prekey `SPK-B`; sending chain `CK-r2i`; no receiving
  chain until the initiator's first message. It may send immediately.
- Initiator: peer ratchet key = `SPK-B` (from the bundle it validated); receiving chain `CK-r2i`;
  it generates ratchet key pair `R-A1` and sets `(RK1, CKs) = KDF_RK(RK0, ECDH(R-A1, SPK-B))`.
  `CK-i2r` is not used.

When a message arrives whose ratchet public key differs from the stored peer key, the receiver
first keeps the message keys still owed on its current receiving chain up to the announced
`previous_chain_length` (counted in the skipped-key bound), then steps:

    (RK, CKr) = KDF_RK(RK, ECDH(own ratchet key, new peer key));  Nr = 0
    PN = Ns;  Ns = 0;  own ratchet key = new key pair
    (RK, CKs) = KDF_RK(RK, ECDH(new own key, new peer key))

Message keys within a chain follow section 6. Every change is made on the loaded state and saved
only after the AEAD check of the message passes, so a forged or corrupted message (including a
forged ratchet key, which is associated data) changes nothing. Each completed round trip brings
fresh DH contributions from both devices: a copy of a device's state stops decrypting as soon as
both sides have used ratchet keys created after the copy was taken. A session saved by a version
without the ratchet is refused with `VTP2_SESSION_LEGACY_REKEY_REQUIRED`.

State advancement is protected by an exclusive lock and atomic replace. Encryption reserves
and commits a message number before returning an envelope, preventing nonce/key reuse after
crash. Decryption commits replay state before releasing plaintext.

## 7. Replay, expiry, and limits

- Message IDs are random 128-bit values and retained in a bounded replay journal.
- Duplicate `(session_id, message_number)` and duplicate message IDs are rejected.
- Clock-independent ratchet counters are authoritative; timestamps enforce policy only.
- Default lifetime is 7 days; messages beyond expiry, more than 10 minutes in the future, or
  claiming a lifetime longer than 7 days (plus skew) are rejected.
- Envelope maximum is 1 MiB; plaintext maximum is 782,336 bytes (768 KiB minus 4 KiB, so the
  base64 envelope always fits); an envelope that would exceed 1 MiB is refused before a message
  number is used; JSON depth maximum is 16.
- Counter exhaustion, skipped-key limit, malformed base64, invalid curve points, and state
  rollback indicators fail closed.

## 8. Storage and deletion

Private identity keys, prekeys, session roots, chain keys, skipped keys, and replay journals
are stored only inside protected state (section 4). State files are created owner-only
(mode 0600) on Unix; on Windows they inherit the user profile ACL and are DPAPI-bound to the user.
Writes use a same-directory temporary file, flush-to-disk, and atomic replacement. Plaintext
is returned to the caller or written only to an explicitly selected output path; transport
spools contain encrypted envelopes only.

## 9. Strict decoding

Every security structure has a closed field set. Unknown fields fail with
`VTP2_UNKNOWN_FIELD:<STRUCTURE>:<name>`, duplicate keys at any depth with `VTP2_DUPLICATE_KEY`,
wrong JSON types with `VTP2_MISSING_FIELD:<name>` or `VTP2_INVALID_FIELD_TYPE`. Exit code 42
means a protocol or verification failure; exit code 1 means an internal failure.

## 10. Required verification gates

Release verification must include deterministic primitive vectors, two-device handshake,
offline bidirectional and out-of-order delivery, concurrent send serialization, replay,
tampering of every authenticated field, wrong identity, changed pin, expired bundle/message,
consumed OPK, oversized/truncated/malformed inputs, state corruption, path traversal, and
proof that transport spools contain none of the test plaintext; for the ratchet: keys rotate per
round trip, out-of-order delivery across ratchet steps, post-compromise recovery against a copied
state, a forged ratchet key refused without a state change, the responder sending first.

## 11. Review status

The protocol and the implementation (`src/Vtp2/Program.cs`) have had internal review only. An
independent cryptographic review is required before VTP v2 is used where confidentiality matters
to an adversary; until then `SECURITY.md` treats it as a developer preview.
