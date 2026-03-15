# Azure Dev Box Cursor Remote Windows Design

## Goal
Provide a Windows-specific remote development environment where Azure Dev Box supplies the Windows host, local Cursor connects to it over Remote SSH, and developers can optionally maintain a local mirror with a controlled single-writer handoff workflow.

## Requirements
- Windows-native toolchains, builds, tests, and debugging must run on the remote Windows machine.
- Local Cursor must remain the primary client.
- Azure Dev Box must be the managed workstation platform.
- Docker must be available on every Dev Box, but containers are not the default editor runtime.
- Developers may keep a local mirror and hand work between local and remote without recloning.
- The design must avoid unsupported assumptions about Windows devcontainers as the editor runtime.

## Non-Goals
- Developing directly inside a Windows container as the primary Cursor editor environment.
- True active-active editing on local and remote at the same time.
- Treating Dev Containers as the main Windows development model.

## Chosen Architecture
The approved architecture is:

- Azure resources create the Dev Center, project, and pool.
- Each developer creates an actual Dev Box from that pool.
- The Dev Box is treated as the real Windows development host.
- Local Cursor connects to the Dev Box through Remote SSH.
- Source code lives on the Dev Box filesystem for active remote work.
- Every Dev Box includes Docker Desktop for optional runtime and test isolation.
- A local mirror is allowed, but only under a single-writer handoff model.
- Git carries branch and history state. Mutagen carries working-tree file changes between local and remote.

This keeps Windows-specific work on Windows while preserving the local Cursor experience.

## Resource Model
The provided ARM template is part of the control plane only. It creates:

- `Microsoft.DevCenter/devcenters`
- `Microsoft.DevCenter/projects`
- `Microsoft.Authorization/roleAssignments`
- `Microsoft.DevCenter/projects/pools`

It does not create a ready-to-use developer VM by itself. A developer must still create an individual Dev Box from the pool before Cursor can connect to anything.

## Dev Box Host Model
Each Dev Box is a Windows host, not just a container runner. The host should provide:

- Windows 11 Enterprise plus Visual Studio tooling from the selected marketplace image
- Local administrator access, as already enabled by the pool definition
- `OpenSSH Server`
- `Git`
- `Docker Desktop`
- Required Windows SDKs, runtimes, and project-specific toolchains
- A standardized workspace root such as `C:\dev` or `D:\dev`
- UTF-8-friendly PowerShell defaults

The goal is to make the host itself the stable development target for Cursor Remote SSH.

## Cursor Connection Model
The connection model is remote-first:

- Local Cursor uses `Anysphere Remote SSH` to connect to the Dev Box.
- The repository is opened directly from the Dev Box filesystem.
- All heavy operations run remotely:
  - `git`
  - package restore
  - builds
  - tests
  - Docker commands
  - debugging
- Port forwarding is enabled so web apps and services running on the Dev Box can be reached locally.

This avoids the unsupported pattern of trying to bind-mount local files into a remote Windows development container.

## Container Model
Docker is included on every Dev Box, but containers are secondary infrastructure:

- Windows containers are execution, build, or test targets when needed.
- Linux containers are available through Docker Desktop and WSL2 when a project needs them.
- Neither Windows nor Linux containers are treated as the default Cursor editor runtime for this design.

This is intentional. The supported workflow is Windows host development first, containers second.

## Local Mirror And Handoff Model
The approved mirror model is not a passive read-only clone. It is a controlled two-way sync with single-writer handoff:

- Developers may keep a local working copy on macOS.
- Only one side is actively edited at a time.
- The remote Dev Box remains the Windows-specific execution environment.
- The local copy exists for handoff, mobility, and local editing convenience.

### Sync Responsibilities
- Git handles:
  - commits
  - branches
  - rebases
  - merges
  - remote history
- Mutagen handles:
  - working-tree file movement between local and remote

### Git Clone Layout
The local and remote machines keep separate Git clones. The `.git` directory is excluded from synchronization.

This means:
- Working-tree edits can move between local and remote.
- Branch and history state do not move through the sync layer.
- Branch alignment must be maintained through Git, not through file sync.

## Sync Tool Choice
The selected tool is Mutagen with a safe two-way mode and explicit ignore rules.

The reasons for choosing Mutagen are:
- It supports cross-platform synchronization between local and remote endpoints.
- It supports SSH-based remote endpoints.
- It offers safer conflict behavior than silent overwrite models.
- It fits a single-writer handoff workflow better than always-on active-active replication tools.

### Sync Guardrails
The sync layer must exclude at least:

- `.git/`
- build output directories
- package caches
- IDE state
- generated artifacts
- temporary files
- lock files that should not roam

The exact ignore list should be tailored per repository, but the design assumes an explicit allow/deny policy rather than syncing the whole tree blindly.

## Handoff Rules
The handoff procedure is a core part of the design:

1. Only one side is actively edited at a time.
2. Before switching, the current side waits for sync to become healthy and idle.
3. The next side confirms it is on the same Git branch.
4. Sync is not trusted to carry Git metadata.
5. Rebases, merges, resets, or large generated-file churn should not happen mid-handoff.
6. Windows-specific builds and tests still run on the Dev Box.

This preserves the convenience of a local mirror without pretending the setup is safe for unconstrained simultaneous editing.

## Bootstrap Strategy
Bootstrap should be standardized so each Dev Box becomes usable with minimal manual drift.

Preferred approach:
- Bake as much as possible into the Dev Box image or organization-approved base customization.
- Use a host bootstrap script for the remainder.

Bootstrap should cover:
- enabling `OpenSSH Server`
- starting `sshd`
- enabling `AllowTcpForwarding`
- opening the needed firewall rules
- installing `Git`
- installing `Docker Desktop`
- applying PowerShell UTF-8 defaults
- creating the standard workspace root
- optionally installing project-specific SDKs or CLIs

Local bootstrap should cover:
- local SSH key generation and registration
- local Cursor Remote SSH setup
- local Mutagen installation
- local clone creation

## Security And Reliability Notes
- Key-based SSH should be the steady-state access model.
- Password authentication may exist only for initial bootstrap if needed.
- The Dev Box should have outbound access required for Cursor remote components and extensions.
- Windows remote development is workable, but generally more brittle than the same workflow on Linux.
- Recovery steps must be documented for:
  - Remote SSH setup failures
  - sync drift
  - branch mismatch
  - accidental dual edits

## Failure Recovery Model
If the environment drifts, recovery should prefer deterministic reset points:

- If Mutagen reports conflicts or unsafe state, stop editing and pick one side as the temporary source of truth.
- If Git branch state diverges, reconcile with Git first, then resume file sync.
- If Remote SSH becomes unstable, reset the remote server state and reconnect rather than trying to debug partial corruption indefinitely.
- If generated files pollute sync, tighten ignore rules instead of normalizing the noise.

## Validation Checklist
The design is not complete until the following are proven end-to-end:

### Azure And Host Provisioning
- The ARM template deploys the Dev Center, project, role assignment, and pool successfully.
- A developer can create an actual Dev Box from the pool.
- The Dev Box receives the expected image, size, and host settings.

### Remote Access
- Local SSH key authentication works.
- Cursor can connect over Remote SSH to the Dev Box.
- Remote folders open successfully in Cursor.
- Port forwarding works.

### Windows Development
- Windows-native toolchains run on the Dev Box.
- A representative Windows build succeeds.
- A representative Windows test run succeeds.
- Debugging works from the remote environment.

### Docker
- Docker Desktop starts successfully on the Dev Box.
- A representative Docker build succeeds.
- If needed, a representative Windows container run succeeds.
- If needed, a representative Linux container run succeeds.

### Local Mirror And Handoff
- Mutagen sync initializes successfully between local macOS and the Dev Box.
- Local-to-remote file propagation works.
- Remote-to-local file propagation works.
- The single-writer handoff process works without recloning.
- Ignore rules successfully exclude `.git`, build outputs, and caches.

## Summary
This design intentionally centers on a Windows host, not on Windows devcontainers. Azure Dev Box provides the managed workstation layer, Cursor Remote SSH provides the editor access path, Docker is available on every box for optional runtime isolation, and Mutagen provides a controlled single-writer handoff path for a local mirror. The result is a Windows-specific development model that is realistic about current tool support instead of relying on unsupported container assumptions.
