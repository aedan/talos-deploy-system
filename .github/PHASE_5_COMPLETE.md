## Goal
- Add confirmation modals before destructive execute actions (Phase 4)
- Add progress indicators for long-running operations (Phase 5)

## Constraints & Preferences
- Do not break existing functionality; tests must continue to pass
- Shell paths must be portable across different environments (Nix, Homebrew, custom PATH)
- State classes should use actors or @unchecked Sendable with safety comments instead of @unchecked Sendable on mutable classes
- Bash scripts should be extracted to external files rather than embedded in Swift string literals
- All UI improvements must be non-breaking and additive
- Shell path resolution uses PATH search first, then fallbacks, then hardcoded default as last resort

## Progress
### Done
- Added `ShellPath` struct to `CommandSupport.swift` with `which(_:)` and `resolve(_:fallback:)` methods
- Replaced hardcoded `/usr/bin/rsync` with `ShellPath.resolve("rsync", fallback: "/usr/bin/rsync")` in `SSHCommandRouter.sync()`
- Replaced hardcoded `/usr/bin/ssh` with `ShellPath.resolve("ssh", fallback: "/usr/bin/ssh")` in `SSHCommandRouter.run()`
- Replaced hardcoded `/bin/bash` with `ShellPath.resolve("bash", fallback: "/bin/bash")` in `UbuntuBootstrap.swift:470`
- Replaced hardcoded `/usr/bin/env` with `ShellPath.resolve("env", fallback: "/usr/bin/env")` in `UbuntuBootstrap.swift:501`
- Converted `LocalCommandRunner` from `final class` to `actor` to ensure thread safety for Process management
- Updated `CommandRunning` protocol to be `Sendable` (removed @unchecked from protocol definition)
- Updated 27 `@unchecked Sendable` classes with safety comments or removed where appropriate
- Created `Resources/maintenance/` directory with 6 bash scripts: `talos-health.sh`, `apply-config.sh`, `upgrade-talos.sh`, `upgrade-k8s.sh`, `rotate-configs.sh`, `collect-logs.sh`
- Updated `MaintenanceBundleBuilder` to load external maintenance scripts from bundle
- Moved maintenance directory to `Sources/TalosDeployCore/Resources/maintenance/`
- Updated Package.swift to include maintenance resources in main `TalosDeployCore` target
- Updated `MaintenanceBundleBuilder.writeBundle(for:in:)` to use `Bundle.module` for SwiftPM resource lookup instead of hardcoded fallback paths
- Removed duplicate test target resource copying (test target inherits from main target)
- Fixed file overwrite issue by adding `fileManager.removeItem(at: targetURL)` before `copyItem(at:to:)`
- Phase 4 Complete: Added confirmation modals before all 6 destructive execute actions in UI
- Phase 5 Complete: Added 6 state flags to AppController (`isDeploymentExecuting`, `isSpecExecuting`, `isDeployerServicesExecuting`, `isResumeExecuting`, `isReprovisionExecuting`, `isDiskBootExecuting`) and initialized them in init
- Updated `runDeployment()` to use `isDeploymentExecuting` state flag with defer
- Updated `runDeploymentSpecFromPath()` to use `isSpecExecuting` state flag with defer
- Updated `prepareDeployerServices()` to use `isDeployerServicesExecuting` state flag with defer
- Updated `resumeDeployment()` to use `isResumeExecuting` state flag with defer
- Updated `reprovisionDeployment()` to use `isReprovisionExecuting` state flag with defer
- Updated `prepareInstalledDiskBoot()` to use `isDiskBootExecuting` state flag with defer
- Added AppKit import to `Deployment.swift` for `NSAlert` support
- Updated DeploymentView execute buttons with `.disabled()` and `ProgressView`
- Updated DeployerOpsView execute buttons with `.disabled()` and `ProgressView`
- Updated RecoveryView resume buttons with `.disabled()` and `ProgressView`
- Updated RecoveryView reprovision buttons with `.disabled()` and `ProgressView`
- Updated RecoveryView disk boot buttons with `.disabled()` and `ProgressView`
- All 74 tests pass with 0 failures

### Blocked
- (none)

## Key Decisions
- Only `LocalCommandRunner` needed to become a true `actor` because it manages mutable Process state; 25+ other `@unchecked Sendable` classes are immutable after init and keep `@unchecked Sendable` with safety comments
- Shell path resolution uses PATH search first, then fallbacks, then hardcoded default as last resort
- External maintenance scripts are bundled with the app and copied to maintenance directory during bundle generation
- Protocol definitions cannot use `@unchecked Sendable` directly; only conforming types can be marked
- `MaintenanceBundleBuilder.init(bundle:)` now uses `Bundle = .main` instead of optional bundle to simplify API
- SwiftPM `Bundle.module` automatically created for targets with resources; moved maintenance scripts to `Sources/TalosDeployCore/Resources/maintenance/` to enable `Bundle.module.url(forResource:...subdirectory:)` lookup
- Removed hardcoded fallback paths from `MaintenanceBundleBuilder` once maintenance scripts were moved into the `TalosDeployCore` target directory
- Confirmation helper `confirmDestructiveAction` is `public` to allow UI module access
- State flags use `defer` pattern to ensure they're always reset even on error
- UI execute buttons now disabled and show ProgressView during long-running operations

## Next Steps
- Phase 6: Add visual feedback indicators (spinner, status messages)
- Phase 7: Add output logging/viewing for long-running operations
- Continue remaining UI improvements (Phases 8–15)

## Critical Context
- The codebase had 26 instances of `@unchecked Sendable` across 14 files in `TalosDeployCore`
- Embedded bash scripts in `DeploymentExecution.swift` total ~600 lines across 8 scripts (now fully extracted to external files)
- All `SSHCommandRouter` calls work with actor-based `LocalCommandRunner` via `CommandRunning` protocol
- UI changes are additive and non-breaking
- SwiftPM resource bundles: main target resources at `TDS_TalosDeployCore.bundle/`, test resources at `TDS_TalosDeployCoreTests.bundle/`
- Bundle lookup now uses `Bundle.module.url(forResource: resourceName, withExtension: nil, subdirectory: "maintenance")` after initial bundle checks
- Test `testStageWritesMaintenanceBundleForDeployerOwnedOperations` passes due to correct `Bundle.module` resource lookup
- `FileManager.copyItem(at:to:)` throws if destination exists; fixed by adding `fileManager.removeItem(at: targetURL)` before copy
- AppController is defined in `Sources/TalosDeployCore/Deployment.swift:2207` and is used throughout the UI via `@EnvironmentObject`
- All execute actions now have confirmation dialogs added in Phase 4
- All execute actions now have state flags and ProgressView indicators in Phase 5

## Relevant Files
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployCore/Deployment.swift:2207`: AppController class definition, state flags (added for Phase 5), execute method implementations updated with state flags and defer
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployApp/TalosDeployApp.swift:849`: Deployment execute buttons updated with ProgressView and disabled state
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployApp/TalosDeployApp.swift:873`: Spec execute buttons updated with ProgressView and disabled state
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployApp/TalosDeployApp.swift:943`: Deployer services execute button updated with ProgressView and disabled state
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployApp/TalosDeployApp.swift:1030`: Resume execute buttons updated with ProgressView and disabled state
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployApp/TalosDeployApp.swift:1055`: Reprovision execute buttons updated with ProgressView and disabled state
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployApp/TalosDeployApp.swift:1073`: Disk boot execute buttons updated with ProgressView and disabled state
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployCore/CommandSupport.swift`: Added ShellPath utility, converted LocalCommandRunner to actor, updated protocol
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployCore/UbuntuBootstrap.swift`: Replaced hardcoded bash/env paths
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployCore/DeploymentExecution.swift`: Updated MaintenanceBundleBuilder to use external scripts, removed hardcoded fallback paths, added removal before copy
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Package.swift`: Added maintenance resources to main `TalosDeployCore` target
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployCore/Resources/maintenance/`: Directory with 6 extracted bash scripts
