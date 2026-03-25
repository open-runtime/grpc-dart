# Azure Dev Box Cursor Remote Windows Setup Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Create a repeatable Windows-specific remote development setup based on Azure Dev Box, Cursor Remote SSH, Docker Desktop, and a safe local-to-remote handoff workflow.

**Architecture:** Azure Dev Box provides the managed Windows host. Each developer creates a Dev Box from the approved pool, bootstraps that host with OpenSSH, Git, Docker Desktop, and standard workspace conventions, then connects from local Cursor over Remote SSH. A local mirror is supported through Mutagen in a single-writer handoff model, while Git remains responsible for branch and history state.

**Tech Stack:** Azure Dev Box, ARM template JSON, PowerShell, OpenSSH Server, Docker Desktop, Git, Mutagen, Cursor Remote SSH, `.gitattributes`.

---

### Task 1: Check In Dev Box Infrastructure Assets

**Files:**
- Create: `infra/devbox/azure-dev-box.template.json`
- Create: `infra/devbox/parameters.example.json`
- Create: `infra/devbox/README.md`
- Reference: `docs/plans/2026-03-15-azure-dev-box-cursor-remote-windows-design.md`

**Step 1: Write the parameter example**

```json
{
  "location": {
    "value": "eastus"
  },
  "devCenterName": {
    "value": "global-dev-boxes"
  },
  "projectName": {
    "value": "dev-boxes"
  },
  "poolName": {
    "value": "dev-boxes"
  }
}
```

**Step 2: Run validation before the template file exists**

Run: `az deployment group validate --resource-group CICD --template-file infra/devbox/azure-dev-box.template.json --parameters @infra/devbox/parameters.example.json`

Expected: FAIL with a file-not-found or template-read error, proving the validation command is wired up before the file lands.

**Step 3: Add the approved ARM template**

```json
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "location": {
      "type": "String"
    },
    "devCenterName": {
      "type": "String"
    },
    "projectName": {
      "type": "String"
    },
    "poolName": {
      "type": "String"
    }
  }
  /* ... copy the full approved template from the design doc/user-provided source ... */
}
```

**Step 4: Document the lifecycle clearly**

```md
# Azure Dev Box Infrastructure

This template creates the Dev Center control plane only:

- Dev Center
- Project
- Project role assignment
- Pool

Developers must still create an actual Dev Box from the pool before Cursor can connect.
```

**Step 5: Re-run validation and confirm it succeeds**

Run: `az deployment group validate --resource-group CICD --template-file infra/devbox/azure-dev-box.template.json --parameters @infra/devbox/parameters.example.json`

Expected: PASS or Azure semantic validation output with no template syntax errors.

**Step 6: Commit**

```bash
git add infra/devbox/azure-dev-box.template.json infra/devbox/parameters.example.json infra/devbox/README.md
git commit -m "chore: add azure dev box infrastructure assets"
```

### Task 2: Add The Dev Box Host Bootstrap Script

**Files:**
- Create: `scripts/devbox/bootstrap-devbox.ps1`
- Create: `scripts/devbox/tests/bootstrap-devbox.Tests.ps1`

**Step 1: Write the failing PowerShell contract tests**

```powershell
Describe "bootstrap-devbox -PlanOnly" {
  It "declares the required Windows host features" {
    $plan = & "$PSScriptRoot/../bootstrap-devbox.ps1" -PlanOnly | ConvertFrom-Json
    $plan.features | Should -Contain "OpenSSH.Server~~~~0.0.1.0"
    $plan.packages | Should -Contain "Git.Git"
    $plan.packages | Should -Contain "Docker.DockerDesktop"
    $plan.sshdConfig.AllowTcpForwarding | Should -Be "yes"
    $plan.workspaceRoot | Should -Be "C:\dev"
  }
}
```

**Step 2: Run the tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester scripts/devbox/tests/bootstrap-devbox.Tests.ps1"`

Expected: FAIL because `scripts/devbox/bootstrap-devbox.ps1` does not exist yet.

**Step 3: Implement the bootstrap script with a dry-run contract**

```powershell
param(
  [switch]$PlanOnly,
  [switch]$Apply
)

$plan = [ordered]@{
  workspaceRoot = 'C:\dev'
  features = @('OpenSSH.Server~~~~0.0.1.0')
  packages = @('Git.Git', 'Docker.DockerDesktop')
  sshdConfig = @{
    AllowTcpForwarding = 'yes'
  }
  powerShellUtf8 = $true
}

if ($PlanOnly) {
  $plan | ConvertTo-Json -Depth 5
  exit 0
}

if (-not $Apply) {
  throw "Specify -PlanOnly or -Apply"
}

# Install Windows capability, packages, sshd config, and workspace root here.
```

**Step 4: Add the minimal apply behavior**

```powershell
Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd

if (-not (Test-Path 'C:\dev')) {
  New-Item -ItemType Directory -Path 'C:\dev' | Out-Null
}

winget install --id Git.Git --accept-source-agreements --accept-package-agreements
winget install --id Docker.DockerDesktop --accept-source-agreements --accept-package-agreements
```

**Step 5: Re-run the tests**

Run: `pwsh -NoProfile -Command "Invoke-Pester scripts/devbox/tests/bootstrap-devbox.Tests.ps1"`

Expected: PASS.

**Step 6: Commit**

```bash
git add scripts/devbox/bootstrap-devbox.ps1 scripts/devbox/tests/bootstrap-devbox.Tests.ps1
git commit -m "feat: add dev box bootstrap script"
```

### Task 3: Add Local Sync Bootstrap And Cross-Platform Repo Policy

**Files:**
- Create: `scripts/devbox/setup-local-mutagen.sh`
- Create: `scripts/devbox/mutagen.ignore`
- Create: `scripts/devbox/tests/setup-local-mutagen-smoke.sh`
- Create: `.gitattributes`

**Step 1: Write the failing smoke test for local sync assets**

```bash
#!/usr/bin/env bash
set -euo pipefail

test -f scripts/devbox/setup-local-mutagen.sh
test -f scripts/devbox/mutagen.ignore
test -f .gitattributes
rg '^\* text=auto eol=lf$' .gitattributes
rg '^\*\.cmd text eol=crlf$' .gitattributes
rg '^\*\.bat text eol=crlf$' .gitattributes
rg '^\*\.ps1 text eol=crlf$' .gitattributes
```

**Step 2: Run the smoke test to verify it fails**

Run: `bash scripts/devbox/tests/setup-local-mutagen-smoke.sh`

Expected: FAIL because the files do not exist yet.

**Step 3: Implement the local Mutagen setup script**

```bash
#!/usr/bin/env bash
set -euo pipefail

LOCAL_PATH="${1:?local path required}"
REMOTE_ENDPOINT="${2:?remote endpoint required}"

mutagen sync create \
  --name="devbox-handoff" \
  --mode="two-way-safe" \
  --ignore-vcs \
  -i ".git/" \
  -i ".vs/" \
  -i ".vscode/" \
  -i ".cursor/" \
  -i "build/" \
  -i "node_modules/" \
  -i ".dart_tool/" \
  "$LOCAL_PATH" \
  "$REMOTE_ENDPOINT"
```

**Step 4: Add ignore and line-ending policy**

```text
.git/
.vs/
.vscode/
.cursor/
build/
node_modules/
.dart_tool/
```

```gitattributes
* text=auto eol=lf
*.cmd text eol=crlf
*.bat text eol=crlf
*.ps1 text eol=crlf
```

**Step 5: Re-run the smoke test and syntax-check the shell script**

Run: `bash -n scripts/devbox/setup-local-mutagen.sh && bash scripts/devbox/tests/setup-local-mutagen-smoke.sh`

Expected: PASS.

**Step 6: Commit**

```bash
git add scripts/devbox/setup-local-mutagen.sh scripts/devbox/mutagen.ignore scripts/devbox/tests/setup-local-mutagen-smoke.sh .gitattributes
git commit -m "feat: add local mutagen handoff workflow"
```

### Task 4: Document Daily Workflow And Recovery Procedures

**Files:**
- Create: `docs/devbox/README.md`
- Create: `docs/devbox/recovery.md`
- Modify: `docs/QUICKSTART.md`

**Step 1: Prove the quickstart does not already mention the new workflow**

Run: `rg "Dev Box|Mutagen|Remote SSH" docs/QUICKSTART.md`

Expected: FAIL with no matches.

**Step 2: Write the daily workflow document**

```md
# Dev Box Workflow

1. Create a Dev Box from the approved pool.
2. Run the Windows bootstrap script on the Dev Box.
3. Clone the repository on the Dev Box under `C:\dev\<repo>`.
4. Clone the repository locally on macOS.
5. Start Mutagen with the approved ignore list.
6. Use local Cursor Remote SSH to open the Dev Box workspace.
7. Follow the single-writer handoff rule when switching sides.
```

**Step 3: Write the recovery guide**

```md
# Recovery

- If Remote SSH fails, verify SSH first outside Cursor.
- If sync drifts, stop editing and select one side as the temporary source of truth.
- If branch state diverges, fix branch alignment with Git before resuming sync.
- If generated files churn, tighten ignores instead of accepting the noise.
```

**Step 4: Link the new workflow from the existing quickstart**

```md
See `docs/devbox/README.md` for the Windows-specific Azure Dev Box remote development workflow.
```

**Step 5: Verify the docs are linked and discoverable**

Run: `rg "Dev Box|Mutagen|Remote SSH|single-writer" docs/devbox/README.md docs/devbox/recovery.md docs/QUICKSTART.md`

Expected: PASS with matches in all three files.

**Step 6: Commit**

```bash
git add docs/devbox/README.md docs/devbox/recovery.md docs/QUICKSTART.md
git commit -m "docs: add dev box workflow documentation"
```

### Task 5: Validate End-To-End On A Fresh Dev Box

**Files:**
- Create: `docs/devbox/validation-checklist.md`
- Modify: `docs/devbox/README.md`

**Step 1: Write the validation checklist before running anything**

```md
# Validation Checklist

- ARM template validates
- Dev Box can be created from the pool
- SSH works from local machine
- Cursor Remote SSH opens the remote workspace
- Windows-native build/test succeeds on the Dev Box
- Docker Desktop works on the Dev Box
- Mutagen sync works local -> remote and remote -> local
- Single-writer handoff succeeds without recloning
```

**Step 2: Deploy or validate the infrastructure**

Run: `az deployment group create --resource-group CICD --template-file infra/devbox/azure-dev-box.template.json --parameters @infra/devbox/parameters.example.json`

Expected: PASS with deployment output or a clean create/update result.

**Step 3: Bootstrap the fresh Dev Box**

Run on the Dev Box: `powershell.exe -ExecutionPolicy Bypass -File scripts/devbox/bootstrap-devbox.ps1 -Apply`

Expected: PASS with OpenSSH, Git, Docker Desktop, and `C:\dev` configured.

**Step 4: Prove Cursor and SSH connectivity**

Run locally: `ssh devbox-alias hostname`

Expected: PASS and print the remote Windows host name.

Run locally: `cursor --folder-uri "vscode-remote://ssh-remote+devbox-alias/C:/dev/grpc"`

Expected: Cursor opens the remote workspace on the Dev Box.

**Step 5: Prove the handoff workflow**

Run locally: `scripts/devbox/setup-local-mutagen.sh "$HOME/src/grpc" "devbox-alias:/C:/dev/grpc"`

Expected: PASS and create the `devbox-handoff` session.

Then:
- make a file change locally and confirm it appears remotely
- make a file change remotely and confirm it appears locally
- switch active editing sides only after sync is healthy

**Step 6: Record the verified results**

```md
## Verified Results

- Date:
- Dev Box image:
- Dev Box size:
- SSH status:
- Cursor Remote SSH status:
- Windows build/test status:
- Docker status:
- Mutagen handoff status:
- Known issues:
```

**Step 7: Commit**

```bash
git add docs/devbox/validation-checklist.md docs/devbox/README.md
git commit -m "docs: record dev box validation workflow"
```
