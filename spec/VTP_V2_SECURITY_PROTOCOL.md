# VTP v2 Security Protocol

Status: implementation target. VTP v1 is not security-compatible with v2.

## 1. Scope and claims

VTP v2 is an asynchronous, offline-capable, one-to-one encrypted messaging protocol.
It provides authenticated device identity, confidentiality and integrity of message content
and protected metadata, replay rejection, and forward secrecy after message-key deletion.
Post-compromise recovery requires an explicit new authenticated session establishment using
fresh uncompromised prekey material; v2.0 does not claim an in-session DH double ratchet.

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
canonical encoding of every envelope field except `ciphertext_b64` and `tag_b64`). v2.0 has no
in-session DH ratchet, so there is no ratchet public key or previous-chain-length field.

Skipped message keys are bounded to 100 per receiving chain in total (not merely per gap)
and are protected at rest with the rest of the state. A new
session handshake replaces both chains and the root using fresh ephemeral and one-time
prekey contributions. Operators must refresh a session after suspected compromise.

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
proof that transport spools contain none of the test plaintext.
