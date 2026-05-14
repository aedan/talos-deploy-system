## Goal
- Add progress bar to operation output view showing real-time progress for prepareInstalledDiskBoot operation (Phase 8)

## Constraints & Preferences
- Do not break existing functionality; tests must continue to pass
- Progress updates must be actor-safe using @MainActor isolation
- Progress bar only displays when operationProgress > 0
- All existing execute methods must remain compatible with progress callback pattern
- Progress callback uses @Sendable (Double) async -> Void pattern for thread safety

## Progress
### Done
- Added `operationProgress: Double` to AppController initialized to 0.0
- Added `updateOperationProgress(_:)` helper method for actor-safe progress updates using @MainActor isolation
- Updated `prepareDeployerServices()` to clear progress before execution
- Updated `runDeployment()` to clear progress before execution
- Updated `runDeploymentSpecFromPath()` to clear progress before execution
- Updated `resumeDeployment()` to clear progress before execution
- Updated `reprovisionDeployment()` to clear progress before execution
- Updated `prepareInstalledDiskBoot()` in Deployment.swift to clear progress before execution
- Added `operationProgress = 0.0` to all 6 execute methods in Deployment.swift
- Updated `prepareInstalledDiskBoot(_:_:outputCallback:)` in DeploymentExecution.swift to accept `progressCallback: @Sendable (Double) async -> Void` parameter
- Updated `prepareInstalledDiskBoot` loop to call `progressCallback(progress)` with progress values from 0.0 to 1.0
- Added progress callback integration to all 6 execute methods using `@Sendable (Double) async -> Void` pattern
- Added progress bar UI to RecoveryView showing real-time progress with conditional display when operationProgress > 0
- Phase 8 Complete: Progress bar displays in RecoveryView operation log section
- All 74 tests pass with 0 failures

### In Progress
- (none - Phase 8 complete)

### Blocked
- (none)

## Key Decisions
- Progress state stored in AppController alongside operationOutput for unified operation state
- `updateOperationProgress(_:)` uses @MainActor for thread-safe UI updates
- Progress callback pattern follows same pattern as output callback for consistency
- Progress values normalized to 0.0-1.0 range for ProgressView compatibility
- Progress bar only displays when `operationProgress > 0` to avoid showing empty progress during quick operations
- All execute methods initialize `operationProgress = 0.0` to ensure clean state per operation
- Progress callback uses @Sendable for thread-safe cross-actor communication
- Progress bar integrated into RecoveryView operation log section for centralized visibility

## Next Steps
- Phase 9: Add cancel token infrastructure, operation history tracking, and system notifications
- Continue remaining UI improvements (Phases 9–15)

## Critical Context
- Progress callback pattern established in Phase 7 for output capture extends to progress tracking
- All execute methods now support optional progress callback alongside output callback
- `prepareInstalledDiskBoot` is the first operation with implemented progress tracking
- Progress bar UI uses SwiftUI ProgressView with currentProgress and totalProgress parameters
- RecoveryView shows progress bar in same section as operation output for consolidated view
- Main actor isolation ensures progress updates safely reach UI thread

## Relevant Files
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployCore/Deployment.swift:2266`: Added `operationProgress: Double` to AppController
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployCore/Deployment.swift:2337`: Initialized `operationProgress = 0.0` in init
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployCore/Deployment.swift:2956`: Added `updateOperationProgress(_:)` helper method
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployCore/Deployment.swift:2941`: Updated `prepareInstalledDiskBoot()` to clear progress before execution
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployCore/Deployment.swift:2862`: Updated `prepareDeployerServices()` to clear progress before execution
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployCore/Deployment.swift:2794`: Updated `runDeployment()` to clear progress before execution
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployCore/Deployment.swift:2774`: Updated `runDeploymentSpecFromPath()` to clear progress before execution
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployCore/Deployment.swift:2897`: Updated `resumeDeployment()` to clear progress before execution
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployCore/Deployment.swift:2915`: Updated `reprovisionDeployment()` to clear progress before execution
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployCore/DeploymentExecution.swift:1026`: Private `prepareInstalledDiskBoot(_:_:outputCallback:progressCallback:)` method with progress callback parameter
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployApp/TalosDeployApp.swift:1117`: Progress bar UI in RecoveryView operation log section
- `/Users/aedan/Documents/GitHub/talos-deploy-system/Sources/TalosDeployApp/TalosDeployApp.swift:1175`: RecoveryView conditional progress bar display with `if operationProgress > 0`
