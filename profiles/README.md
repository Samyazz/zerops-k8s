# Cluster profile descriptors

The three JSON files in this directory are the source of truth for profile
topology, add-ons, capabilities, acceptance level, setup selection, and initial
Zerops resource contracts. Generated/static Zerops imports mirror these values
and are checked by `scripts/tests/test_profiles.py`.

Shell automation selects a descriptor with `K8S_PROFILE`; sourcing
`scripts/lib.sh` validates the name and exports the resolved node arrays and
topology values. Existing callers that do not set it resolve to `full`.

Supported image modes are:

- `object-storage`: retrieve and checksum the image cached in `k8sbackups`.
- `local`: build the pinned `node/Dockerfile` in the target runtime, verify the
  image ID and embedded kubeadm version, and use no outer storage service.

The profile imports are alternatives. They must never be combined into one
project inventory.
