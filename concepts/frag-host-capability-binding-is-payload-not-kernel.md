---
type: belief
id: frag-host-capability-binding-is-payload-not-kernel
provenance: koru-os native session — klanker chat / LM Studio provider-manifest rung, 2026-11
ts: 2026-11-07
tags: [native, providers, klanker, payload, naming]
---

**A host-side capability binds to a guest program through the
payload's declared manifest — never through kernel config.** The
`AGENTS_PROVIDERS_DIR` convention maps naturally onto the cpio
module: `/providers/lmstudio.local.json` names LM Studio's
llama-server on the QEMU host (slirp `10.0.2.2`, model
`qwen3.5-4b`, auth disabled) as payload text, while the kernel
stays ignorant of what a provider is. The environment variable
selects the overlay root; the manifest carries URL + model; no
host URL lives in kernel tables or package manifests.

- **The refusal ladder walks honestly through provider gaps.**
  Measured on `klanker chat`: no manifest → `LLM_BASE_URL
  required` (klanker's own config wall); manifest present →
  `unknown encoding: idna` (the trimmed stdlib lacked
  `stringprep.py`, idna's dependency — urllib's host
  normalization is codec work); codec landed → `urlopen error
  [Errno 97] Address family not supported` — `socket(AF_INET)`
  refused by name at `childSocket`. Each step names the next
  gap; none is silent.
- **A trimmed stdlib must chase transitive codec imports of the
  network path.** `encodings/idna.py` was kept but its
  `import stringprep` was not — lookup fails wholesale, not
  partially. The keep-list is a closure computation; urllib
  pulls idna pulls stringprep pulls unicodedata.
