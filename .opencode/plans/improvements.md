# Talos Deploy System — Implementation Plan

## Status: Phase 9 Complete - Next: Unsaved Changes Indicator

### Phase 1: ShellPath Utility + Hardcoded Path Replacement 🔄 IN PROGRESS
**Files to modify:** `CommandSupport.swift`, `UbuntuBootstrap.swift`
- Add `ShellPath` struct with `which(_:)` and `resolve(_:fallback:)` methods
- Replace `/usr/bin/ssh` → `ShellPath.resolve("ssh", fallback: "/usr/bin/ssh")` in `SSHCommandRouter.run()`
- Replace `/usr/bin/rsync` → `ShellPath.resolve("rsync", fallback: "/usr/bin/rsync")` in `SSHCommandRouter.sync()`
- Replace `/bin/bash` → `ShellPath.resolve("bash", fallback: "/bin/bash")` in `UbuntuBootstrap.swift:470`
- Replace `/usr/bin/env` → `ShellPath.resolve("env", fallback: "/usr/bin/env")` in `UbuntuBootstrap.swift:501`
- Leave `/bin/bash` in cloud-init YAML (line 381) — Ubuntu always has it
- Leave `/usr/sbin/dnsmasq` in systemd template (line 279) — runs on Ubuntu, not macOS

### Phase 2: Actor Refactor
**Files to modify:** `CommandSupport.swift`, `Deployment.swift`, `DeploymentExecution.swift`, `DeployerTransport.swift`, `Hammertime.swift`, `CoreAPI.swift`, `CoreBridge.swift`, `Settings.swift`, `OOBHardwareInventory.swift`, `PreflightCapture.swift`, `UbuntuBootstrap.swift`
- Make `LocalCommandRunner` a proper `actor` — the only class with true cross-call mutable state (Process management)
- Update `CommandRunning` protocol to be `@unchecked Sendable` with safety comment
- Update `SSHCommandRouter` to accept `any CommandRunning` (works with actor)
- Update all callers to use `LocalCommandRunner()` as before (actor is `Sendable` by default)
- Add `@unchecked Sendable` with inline safety comments to 25 stateless classes

### Phase 3: External Bash Scripts
**New files:** 8 `.sh` files in `Sources/TalosDeployCore/Resources/maintenance/`
- Extract all embedded scripts from `DeploymentExecution.swift`
- Update `Package.swift` to include `.copy("Resources/maintenance/")`
- Update `DeploymentExecution.swift` to load scripts from `Bundle.module`

### Phase 4: Confirmation Dialogs
**File to modify:** `TalosDeployApp.swift`
- Create `ConfirmExecution` sheet modifier with phases listing and destructive button
- Apply to: Execute Deployment, Execute Spec, Resume Execute, Reprovision Execute, Disk Boot Execute, Prepare Services

### Phase 5: Progress Indicators
**Files to modify:** `Deployment.swift`, `TalosDeployApp.swift`
- Add `currentOperation` and `operationProgress` to `AppController`
- Create `ProgressOverlay` view for global progress display
- Set operation state in all long-running methods

### Phase 6: Talos Factory Sequential Steps
**File to modify:** `TalosDeployApp.swift`
- Replace flat 4-button row with numbered step indicator
- Disable subsequent steps until prior ones succeed

### Phase 7: Inventory Install Toggle Label
**File to modify:** `TalosDeployApp.swift`
- Add `.help()` tooltip to the label-hidden toggle

### Phase 8: JSON Editor Inline Validation 🔄 COMPLETED
**File to modify:** `TalosDeployApp.swift`
- Debounced JSON validation on keystroke
- Green/red indicator + inline error messages
- Added validation error tracking with Color.red / Color.secondary.opacity(0.25)
- Inline validation indicators with checkmark/cross icons

### Phase 9: Persist iLO Password 🔄 COMPLETED
**Files to modify:** `Deployment.swift`, `TalosDeployApp.swift`
- Add `temporaryILOPassword` to `AppController`
- Replace local `@State` with `$controller.temporaryILOPassword`
- Changed field help text from "not saved" to "persists for the app session"
- Removed local `@State private var iloPassword` from BootstrapDeployerView

### Phase 10: Unsaved Changes Indicator
**Files to modify:** `Deployment.swift`, `TalosDeployApp.swift`
- Track modified vs loaded settings
- Visual indicator on modified sections
- Disable Save when clean

### Phase 11: Content Max-Width
**File to modify:** `TalosDeployApp.swift`
- Add `.frame(maxWidth: 1200)` to all detail view content

### Phase 12: DeployerOps Success/Failure Color
**File to modify:** `TalosDeployApp.swift`
- Green/red instead of secondary for success
- Checkmark/cross icon added

### Phase 13: Keyboard Shortcuts
**File to modify:** `TalosDeployApp.swift`
- `Cmd+S` save settings, `Cmd+R` refresh, `Cmd+Shift+R` resume

### Phase 14: Persist Deployment Spec Path
**Files to modify:** `Models.swift`, `Deployment.swift`, `TalosDeployApp.swift`
- Add `deploymentSpecPath` to `AppSettings`
- Load/save with settings

### Phase 15: Centered Content Modifier
**File to modify:** `TalosDeployApp.swift`
- Create reusable `.centeredContent()` modifier

### Phase 16: Tests
**File to modify:** `TalosDeployCoreTests.swift`
- Update mock classes for actor signatures
- Update hardcoded path assertions
- Run tests to verify

## Summary
All 16 phases planned. Ready to execute sequentially.
