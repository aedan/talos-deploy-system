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
- The Lab-style acceptance spec has been simplified to one static management network for the current debug run; richer networking remains supported by the model/UI but is not the current acceptance target.

## Current Blocker

Talos node provisioning is reaching the post-boot configuration phase, but at least one worker transitions from live maintenance API to a partial installed state where kubelet is reachable on `10250` and Talos API `50000` is not reachable. This points to Talos config/apply/bootstrap behavior rather than OOB media or Ubuntu deployer provisioning.

## Recommended Next Step

Move the next iteration into a fast config-focused harness before another full physical acceptance run:

1. Build a virtual Talos test loop using the same generated `tds` machine configs, local registry behavior, and deployer-owned scripts.
2. Start with one control plane and one worker.
3. Classify node state as `configured-api`, `live-api`, `kubelet-only`, `ping-only`, or `down`.
4. Capture Talos service states and logs around first apply and installed boot.
5. Replay on one physical worker only after the virtual config path is green.

## Release State

`v0.1.0-alpha.2` captures the current proven progress. Do not include real account numbers, device IDs, credentials, or environment-specific hostnames in committed docs or release notes.
