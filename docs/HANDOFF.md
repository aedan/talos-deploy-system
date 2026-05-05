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
- The Lab-style acceptance spec has been simplified to one static management network for the current debug run; richer networking remains supported by the model/UI but is not the current acceptance target.

## Current Blocker

No current virtual-lab blocker. The next risk is the full bare-metal Lab2 run, where OOB boot behavior, physical NIC naming, and deployer-to-node routing need to be proven with the same deployer-owned apply/bootstrap/health flow.

## Recommended Next Step

Run the Lab2 bare-metal end-to-end acceptance:

1. Build and release `v0.1.0-alpha.3`.
2. Query Lab2 inventory and confirm deployer/control-plane/worker role assignment.
3. Install or validate the Ubuntu 24.04 deployer.
4. Run the deployer-owned Talos apply/bootstrap/health flow against the physical Talos nodes.
5. Keep evidence under ignored local capture directories only.

## Release State

`v0.1.0-alpha.3` captures the OpenStack-proven staged Talos config process and harness. Do not include real account numbers, device IDs, credentials, or environment-specific hostnames in committed docs or release notes.
