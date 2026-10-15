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
receipt before releasing anything. The envelope is not encrypted: on the filesystem-drop transport the
payload is readable by anyone who can read the node folders. Use VTP v2 (`vtp2.ps1`,
`courier-secure.ps1`) where confidentiality is required; the product path does not use it yet.

## VTP v2 secure core

Suite `VTP2-P256-HKDFSHA256-CHACHA20POLY1305` (spec: `spec/VTP_V2_SECURITY_PROTOCOL.md`). Device state
is DPAPI-protected on Windows. Elsewhere it is sealed with ChaCha20-Poly1305 under a 32-byte key file
named by `VTP2_STATE_KEY_FILE` (owner-only permissions required); there is no plaintext state mode.
The implementation has not been independently reviewed.

## Signature verification

Covenant Courier uses OpenSSH signature verification for the local preview flow. A signature is
accepted when it verifies, for the expected identity and namespace, against one of three trust roots:
`trust/allowed_signers` (published release signers), `proofs/trust/allowed_signers` (this machine's
local bootstrap signer) and `proofs/trust/neverlost/allowed_signers` (signers imported from a pinned
NeverLost trust bundle with `courier.ps1 trust-import`).

The release includes public allowed-signers material for verifying bundled preview test vectors.

Do not treat preview trust material as production identity infrastructure.
