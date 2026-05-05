# TDS Handoff

This note summarizes the current project state for continuing work in a fresh thread without relying on live chat history.

## Proven Progress

- The app and CLI are named `tds`; the desktop UI remains the primary operator surface and the CLI supports runtime/integration testing.
- Inventory can be loaded from Core-capable environments, filtered to physical server candidates, searched in the UI, and assigned as deployer, control-plane, or worker roles.
- The Ubuntu deployer bootstrap path uses generated NoCloud autoinstall media and has been proven through iterative install testing.
- `tds` can prepare an existing Ubuntu deployer as the in-environment foothold: service setup, media hosting, local registry caching, generated Talos artifacts, durable state, and maintenance scripts.
- Hammertime-backed deployer access works as the fallback transport when direct SSH is unavailable.
- Deployer-hosted OOB URL media can boot Talos nodes into maintenance/live mode.
- Generated Talos configs now use the Image Factory `metal-installer` image path and default Rackspace-oriented extensions.
- Staged/cloud-image Talos nodes can be configured in place: they skip OOB boot, wipe, and installed-disk boot prep, omit `machine.install`, and still run readiness, apply, bootstrap, and health.
- The OpenStack lab harness proved the Ubuntu deployer-owned Talos flow with 3 controllers and 1 worker on Talos `v1.13.0`.
- Bare-metal Lab-style acceptance has proven the deployer-owned Talos apply/bootstrap/health flow on the responsive physical nodes. The remaining risk is isolating hardware/network outliers that do not present Talos networking after successful OOB media boot.

## Current Blocker

No current OpenStack or deployer-owned Talos flow blocker. The next risk is hardware-specific remediation for bare-metal nodes that accept virtual media but never expose the Talos management API.

## Recommended Next Step

Continue bare-metal hardening:

1. Build and release `v0.1.0-alpha.4`.
2. Preserve the OpenStack and bare-metal acceptance evidence under ignored local capture directories only.
3. Investigate physical nodes that accept OOB media but remain down after Talos boot.
4. Keep interface-name networking as the default when an interface is known; reserve hardware selectors for hardware-address-only inventory.

## Release State

`v0.1.0-alpha.4` captures the OpenStack-proven staged Talos config process, bare-metal deployer-owned apply/bootstrap/health fixes, and Hammertime inventory parsing improvements. Do not include real account numbers, device IDs, credentials, or environment-specific hostnames in committed docs or release notes.
