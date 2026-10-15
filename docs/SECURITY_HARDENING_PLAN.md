# Covenant Courier Security Hardening Plan

## Security gate

VTP and Covenant Courier remain a developer preview until every mandatory gate below
is implemented and independently reviewed. Passing repository self-tests is not a
production security certification.

## Phase 1: implementation honesty and boundary hardening

- Serialized cipher and KDF identifiers match the executed algorithms.
- Authentication is checked before CBC decryption.
- Plaintext hashes are not emitted in encrypted envelopes.
- Receiver-controlled paths are constrained to their frame directory.
- UDP packets have an explicit size ceiling.
- Authenticated session, sender, recipient, and network bindings are checked.
- Replay checking executes on the UDP ingest path before policy and acceptance.

## Phase 2: protocol replacement

- Replace join-code-derived session keys with an independently reviewed authenticated
  X25519-based asynchronous handshake or standardized PAKE where human codes are required.
- Add per-device Ed25519 identity keys, signed prekeys, one-time prekeys, identity-change
  warnings, revocation, and device removal.
- Add a reviewed double-ratchet implementation with per-message key deletion, skipped-key
  limits, replay windows, and post-compromise recovery.
- Use one versioned AEAD suite, preferably ChaCha20-Poly1305 or AES-256-GCM through a
  maintained cryptographic library rather than handwritten protocol cryptography.
- Define canonical binary encodings, downgrade resistance, transcript binding, maximum
  sizes, expiry rules, and deterministic parser behavior.

## Phase 3: endpoint and operational assurance

- Store long-term keys in TPM, smart-card, HSM, or an OS-protected keystore.
- Encrypt messages, attachments, indexes, receipts, quarantine, and backups at rest.
- Define retention, secure deletion, backup recovery, update signing, rollback prevention,
  audit access, incident response, and cryptographic agility procedures.
- Replace demo and token-based tests with cross-device interoperability, fuzzing, property
  tests, known-answer vectors, compromise simulations, and power-loss/concurrency tests.
- Commission independent protocol review, implementation audit, red-team testing, and the
  accreditation required by the intended deployment environment.

## Claim policy

Until all three phases are complete, documentation and releases must use “developer
preview” and must not claim Signal equivalence, defense readiness, classified suitability,
forward secrecy, or post-compromise security.
