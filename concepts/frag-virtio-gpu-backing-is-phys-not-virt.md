type: oracle-lesson
id: frag-virtio-gpu-backing-is-phys-not-virt
provenance: korukms-virtio-gpu harness, QEMU 11.0.3 TCG arm64→x86_64, 2026-11
ts: 2026-11-05
---
# virtio-gpu ATTACH_BACKING maps physical runs, not VA spans

QEMU's `virtio_gpu_create_mapping_iov` maps each mem entry's *physical*
address independently. A VA-contiguous guest pool attached as one entry
transfers correctly only up to its first physical discontinuity — the
display showed ~130 of 480 rows before zeroing. Correct form: emit one
entry per contiguous physical run. Separate lesson: `dma_map` refuses
ranges spanning the ISA hole (0xa0000–0xfffff) with RESP_ERR_UNSPEC —
allocate scanout pools clear of it.
