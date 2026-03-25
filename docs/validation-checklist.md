# Dev Box Validation Checklist

Use this checklist to validate the Azure Dev Box workflow end-to-end. Items marked as "Requires Dev Box" need a real Dev Box instance; items marked "Proven" have been verified in this environment or a prior session.

## Validation Items

### 1. ARM Template Validates

**Requires:** Azure CLI (`az`), a resource group, and parameters file.

**Command:** You can validate with `parameters.example.json` as a baseline, or with your customized `parameters.json` after tailoring values:
```bash
az deployment group validate \
  --resource-group "<RESOURCE_GROUP>" \
  --template-file infra/devbox/azure-dev-box.template.json \
  --parameters @infra/devbox/parameters.example.json
```

**Expected:** Exit 0 with validation output; no template syntax or semantic errors.

**Status:** Proven (Task 5 session: `az deployment group validate` succeeded with resource group CICD).

---

### 2. Dev Box Can Be Created From the Pool

**Requires:** Deployed control plane (Dev Center, project, pool) and RBAC for the developer identity.

**Steps:**
1. Deploy the control plane (see `infra/devbox/README.md`).
2. In Azure Portal: Dev Box > Create Dev Box > select the pool.
3. Wait for provisioning to complete.

**Expected:** Dev Box appears in the project and reaches "Running" status.

**Status:** Requires Dev Box.

---

### 3. SSH Works From Local Machine

**Requires:** Dev Box running, OpenSSH Server installed (via bootstrap; first run uses `powershell.exe` from an elevated session per [README](README.md)), SSH key configured, `~/.ssh/config` host alias.

**Command:**
```bash
ssh devbox-alias hostname
```

**Expected:** Prints the remote Windows host name; exit 0.

**Status:** Requires Dev Box.

---

### 4. Cursor Remote SSH Opens the Remote Workspace

**Requires:** SSH working (item 3), Cursor with Remote SSH extension.

**Steps:**
1. Cursor: Remote-SSH > Connect to Host > select Dev Box alias.
2. Open folder: `C:\dev\grpc` (or `C:\dev\<repo>`).

**Expected:** Cursor opens the remote workspace; file tree and terminal operate on the Dev Box.

**Status:** Requires Dev Box.

---

### 5. Windows-Native Build/Test Succeeds on the Dev Box

**Requires:** Dev Box with workspace cloned. **Dart is not installed by the current bootstrap script**; it must come from the base Dev Box image or a separate project toolchain step.

**Command (on Dev Box):**
```powershell
cd C:\dev\grpc
dart pub get
dart test --platform vm
```

**Expected:** Tests pass; no platform-specific failures.

**Status:** Requires Dev Box.

---

### 6. Docker Desktop Works on the Dev Box

**Requires:** Dev Box with Docker Desktop installed (via bootstrap).

**Command (on Dev Box):**
```powershell
docker info
```

**Expected:** Docker daemon responds; no errors.

**Status:** Requires Dev Box.

---

### 7. Mutagen Sync Works Local -> Remote and Remote -> Local

**Requires:** Dev Box with SSH working, local clone and remote clone on same branch/commit, Mutagen installed locally.

**Setup:**
```bash
scripts/devbox/setup-local-mutagen.sh "$HOME/src/grpc" "devbox-alias:/C:/dev/grpc"
```

**Verification:**
- Create a file locally; confirm it appears on the remote within sync interval.
- Create a file remotely (e.g. via Cursor); confirm it appears locally.
- Run `mutagen sync list` and confirm session `devbox-handoff` is healthy.

**Expected:** Two-way sync completes without conflicts; both sides see changes.

**Status:** Requires Dev Box.

---

### 8. Single-Writer Handoff Succeeds Without Recloning

**Requires:** Mutagen session healthy (item 7), both sides on same Git branch.

**Steps:**
1. Edit locally; wait for sync idle.
2. Switch to remote; edit there; wait for sync idle.
3. Switch back to local; confirm changes present.
4. Do not reclone; Git branch and history remain authoritative.

**Expected:** Handoff works; no reclone required; `.git` excluded from sync.

**Status:** Requires Dev Box.

---

## Verified Results

| Item | Status | Notes |
|------|--------|-------|
| ARM template validates | Proven | Validated 2026-03-15 with `az deployment group validate` (resource group CICD). |
| Dev Box creation | Requires Dev Box | |
| SSH | Requires Dev Box | |
| Cursor Remote SSH | Requires Dev Box | |
| Windows build/test | Requires Dev Box | |
| Docker Desktop | Requires Dev Box | |
| Mutagen sync | Requires Dev Box | |
| Single-writer handoff | Requires Dev Box | |

**Session context:** Task 5. ARM template validation and Mutagen smoke test were run successfully in this environment. All other items require a provisioned Dev Box instance.

---

## Quick Reference

- **Infrastructure:** `infra/devbox/README.md`
- **Daily workflow:** `docs/devbox/README.md`
- **Recovery:** `docs/devbox/recovery.md`
- **Local Mutagen smoke:** `bash scripts/devbox/tests/setup-local-mutagen-smoke.sh` (Proven in Task 5.)
