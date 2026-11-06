---
name: did-identity
iface: koruos/id.did
arms: [koru-native]
lane: native-zig
needs: []
accept: a spawn request carries a did:key attestation; the kernel binds the bag the attestation names
tier: qemu
status: open
evidence: —
peer: agents-keys mints did:key already; phi-identity = attestation merkle lane
provenance: project-owned (agents-keys, phi-identity write-up)
---

# did-identity

Identity is DID + attestations, not login/oauth/timeshare: a spawn
request arrives carrying a signed attestation (`did:key` minted by
agents-keys), the kernel verifies it and binds exactly the rights bag
the attestation names — the "who" a nid answers for becomes
cryptographic provenance, not a uid.

## Acceptance

A fixture child presents an attestation blob naming a bag; a second
presents one minted by a different key asking for MORE rights than
its attestation grants — refused by name. The accepted child's
getpid/nid carries the bound did. status=0.

## Notes

- Not multiuser: this is the "scoping permissions" axis 'user'
  misnames — a bag bound to a key, verifiable by any second party
  (attestations, forward keys on domain moves — phi-identity lane).
- Feeds Kopium later: an agent navigating the system needs identity
  it can attest, not a uid it can guess.
- did:web is the public-resolution half (rfc:web running already) —
  the kernel only needs the key+signature check, resolution lives
  outside.
