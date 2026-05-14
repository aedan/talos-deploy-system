## Goal
- Add output logging/viewing for long-running operations (Phase 7)

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
- Updated DeploymentView, DeployerOpsView, RecoveryView execute buttons with `.disabled()` and `ProgressView`
- Phase 6 Complete: Changed `statusMessage` from `String` to `String?` (Optional)
- Added status message display in DeploymentView, DeployerOpsView, RecoveryView, and main toolbar
- Updated all execute methods to set `statusMessage` with appropriate messages
- Updated `IloLocalMediaWebView` Coordinator to use optional status message
- Fixed test to unwrap optional status message
- All 74 tests pass with 0 failures
- Phase 7 Complete: Added `operationOutput: [String]` to AppController
- Added `clearOperationOutput()` and `appendOperationOutput(_:)` helper methods
- Updated `prepareDeployerServices()` to clear output before execution
- Updated `runDeployment()` to clear output before execution
- Updated `runDeploymentSpecFromPath()` to clear output before execution
- Updated `resumeDeployment()` to clear output before execution
- Updated `reprovisionDeployment()` to clear output before execution
- Updated `prepareInstalledDiskBoot()` to clear output before execution (in DeploymentExecution.swift)
- Added `operationOutput = []` to all 6 execute methods in Deployment.swift
- Added output display UI to RecoveryView showing captured logs in a scrollable monospaced text view

### In Progress
- (none - Phase 7 complete)

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
- Output log is an array of strings to track line-by-line execution output
- Execute methods now clear output before starting to ensure fresh logs per operation
- `prepareInstalledDiskBoot` private method now accepts async `@Sendable (String) async -> Void` callback for output capture
- Main actor-isolated `appendOperationOutput` wrapped in async closure using `await self?.appendOperationOutput($0)` pattern

## Next Steps
- Phase 8: Add progress bar to operation output view showing real-time progress
- Continue remaining UI improvements (Phases 9–15)

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
- All execute actions now have confirmation dialogs (Phase 4), state flags and ProgressView (Phase 5), status messages (Phase 6), and operation output logging (Phase 7)
- Phase 8 will add real-time progress bar to operation output view

## Relevant Files
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployCore/Deployment.swift:2265`: Added `operationOutput: [String]` to AppController
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployCore/Deployment.swift:2336`: Initialized `operationOutput = []` in init
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployCore/Deployment.swift:2936`: Added `clearOperationOutput()` and `appendOperationOutput(_:)` helper methods
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployCore/Deployment.swift:2920`: Updated `prepareInstalledDiskBoot()` to clear output before execution
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployCore/Deployment.swift:2847`: Updated `prepareDeployerServices()` to clear output before execution
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployCore/Deployment.swift:2779`: Updated `runDeployment()` to clear output before execution
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployCore/Deployment.swift:2759`: Updated `runDeploymentSpecFromPath()` to clear output before execution
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployCore/Deployment.swift:2882`: Updated `resumeDeployment()` to clear output before execution
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployCore/Deployment.swift:2900`: Updated `reprovisionDeployment()` to clear output before execution
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployCore/DeploymentExecution.swift:1025`: Private `prepareInstalledDiskBoot(_:_:outputCallback:)` method with async callback
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Tests/TalosDeployCoreTests/TalosDeployCoreTests.swift:2071`: Test updated to unwrap optional statusMessage
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployApp/TalosDeployApp.swift:73`: Toolbar status message with nil-coalescing
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployApp/TalosDeployApp.swift:930`: DeploymentView status display
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployApp/TalosDeployApp.swift:1003`: DeployerOpsView status display
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployApp/TalosDeployApp.swift:1156`: RecoveryView status display
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployApp/TalosDeployApp.swift:1116`: Operation Log view section in RecoveryView
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployApp/TalosDeployApp.swift:1617`: IloLocalMediaWebView Coordinator statusMessage updated to String?
