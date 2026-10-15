# VTP v2 Threat Model

This model applies to `src/Vtp2`, `vtp2.ps1`, `courier-secure.ps1`, v2 prekey bundles,
session-init objects, encrypted message envelopes, and DPAPI-protected v2 state.

## Security objectives

VTP v2 protects message content and authenticated envelope fields against passive capture,
transport modification, untrusted senders, replay, reordering, and later compromise of
already-advanced message chains. It supports offline bundle exchange and store-and-forward
delivery without trusting the storage or transport provider.

The authenticated fields are protocol version, suite, session, sender device, recipient
device, random message ID, direction counter, creation and expiry time, content type, nonce,
and ciphertext length. Modifying any of them causes rejection before plaintext release.

## Trust boundaries

1. **Fingerprint ceremony:** The operator compares a 256-bit identity-signing-key
   fingerprint over a separate authenticated channel. VTP cannot secure a ceremony that
   accepts an attacker-provided fingerprint and bundle together.
2. **Endpoint state:** Private keys and session state cross from a DPAPI-protected file into
   the current user process. Malware running as that user is inside the trust boundary.
3. **Import boundary:** Bundles, session requests, and messages are hostile bounded JSON.
4. **Transport boundary:** Removable media, filesystem drops, UDP adapters, relays, and
   backups are untrusted and must carry only v2 public bundles or encrypted envelopes.
5. **Plaintext boundary:** Decrypted output paths are operator-selected and inherit the
   security of the destination filesystem.

## Addressed threats

| Threat | Control | Verification |
|---|---|---|
| Passive message capture | ChaCha20-Poly1305 with per-message chain keys | Spool plaintext scan |
| Message/header modification | Canonical associated data and 128-bit AEAD tag | Field and ciphertext mutation tests |
| Sender impersonation | ECDSA identity signatures, pinned fingerprint, 3DH+OPK transcript | Wrong pin, untrusted identity, bad signature tests |
| Recipient substitution | Recipient identity/fingerprint in signed handshake and message binding | Wrong-recipient tests |
| Handshake replay | Random session ID, session uniqueness, single-use OPK atomically consumed | Re-accept test |
| Message replay | Random message journal plus monotonic direction counters | Duplicate delivery test |
| Out-of-order delivery | Bounded skipped message keys | 2/0/1 delivery test |
| Offline password guessing | No join code or password-derived session key in v2 | Protocol inspection |
| Historical message recovery after state compromise | One-way chain advancement and non-persistence of message keys | State-transition tests |
| Concurrent key/nonce reuse | Exclusive state lock and atomic state replacement | Concurrent sender test |
| State disclosure at rest | Windows DPAPI CurrentUser protection | Protected-state inspection test |
| Parser/resource abuse | 1 MiB input, 768 KiB plaintext, depth and skip limits | Oversize and skip-limit tests |

## Residual and non-goals

- VTP v2.0 uses symmetric message chains, not an in-session double ratchet. Post-compromise
  recovery requires a newly authenticated session with a fresh unused OPK.
- A compromised endpoint can read plaintext and use keys while compromised. DPAPI does not
  protect against malware executing as the same logged-in user.
- Deleted SSD data, paging files, crash dumps, application telemetry, destination backups,
  and screen capture require operating-system controls outside VTP.
- Packet length, timing, sender/recipient network addresses, traffic volume, and relationship
  existence are not hidden. Padding and anonymity routing are not implemented.
- Denial of service, packet deletion, delaying, and permanent reordering cannot be prevented;
  limits make resource use bounded and failures explicit.
- P-256 and ChaCha20-Poly1305 availability does not itself imply FIPS, CNSA, NIAP, Common
  Criteria, or classified-system approval. Deployment must select validated modules and pass
  the applicable accreditation process.
- Group messaging, multi-device account synchronization, key backup, recovery escrow,
  remote revocation distribution, and anonymous discovery are outside v2.0.

## Failure policy

Unknown versions/suites, changed pinned keys, invalid signatures, missing or consumed OPKs,
bad curve encodings, malformed Base64/JSON, tag failure, replay, expiry, future timestamps,
counter gaps above 100, oversized inputs, protected-state failure, and concurrent lock timeout
all fail closed without releasing plaintext.

## Change rule

Every change to cryptography, canonical encoding, state transitions, authenticated fields,
limits, key lifetime, or trust enrollment must update this model, the v2 specification, and
at least one positive and negative test before merge.
