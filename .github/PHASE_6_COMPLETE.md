## Goal
- Add confirmation modals before destructive execute actions (Phase 4)
- Add progress indicators for long-running operations (Phase 5)
- Add status messages for visual feedback (Phase 6 in progress)

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
- Phase 6 Complete: Changed `statusMessage` from `String` to `String?` (Optional)
- Added status message display in DeploymentView, DeployerOpsView, RecoveryView
- Added status message display in main toolbar (shows current operation status)
- Updated all execute methods to set `statusMessage` with appropriate messages
- Updated `IloLocalMediaWebView` Coordinator to use optional status message
- Fixed test to unwrap optional status message
- All 74 tests pass with 0 failures

### In Progress
- (none - Phase 6 complete)

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
- Status messages are Optional (`String?`) so they only display when there's a message to show
- Status message in toolbar uses `controller.statusMessage ?? ""` to handle optional unwrapping
- Status messages in views use `if let status = controller.statusMessage` to conditionally show when set

## Next Steps
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
- Status message is now Optional and displays in toolbar and view sections to show current operation status

## Relevant Files
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployCore/Deployment.swift:2265`: statusMessage changed from `String` to `String?`, initialized to `nil`
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployCore/Deployment.swift:2335`: statusMessage initialized to `nil` in init
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployCore/Deployment.swift:2776`: runDeployment sets statusMessage
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployCore/Deployment.swift:2755`: runDeploymentSpecFromPath sets statusMessage
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployCore/Deployment.swift:2844`: prepareDeployerServices sets statusMessage
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployCore/Deployment.swift:2876`: resumeDeployment sets statusMessage
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployCore/Deployment.swift:2894`: reprovisionDeployment sets statusMessage
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployCore/Deployment.swift:2914`: prepareInstalledDiskBoot sets statusMessage
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployApp/TalosDeployApp.swift:73`: Toolbar status message with nil-coalescing
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployApp/TalosDeployApp.swift:930`: DeploymentView status display
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployApp/TalosDeployApp.swift:1003`: DeployerOpsView status display
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployApp/TalosDeployApp.swift:1156`: RecoveryView status display
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployApp/TalosDeployApp.swift:1617`: IloLocalMediaWebView Coordinator statusMessage updated to String?
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployApp/TalosDeployApp.swift:1664`: Coordinator sets status message (optional assignment)
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Tests/TalosDeployCoreTests/TalosDeployCoreTests.swift:2071`: Test updated to unwrap optional statusMessage
