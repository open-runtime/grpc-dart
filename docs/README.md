# Dev Box Daily Workflow

This document describes the practical workflow for developing on Windows using Azure Dev Box, Cursor Remote SSH, and Mutagen sync. Some steps happen once when you set up a new Dev Box pair, and some steps are the daily checks you repeat before editing.

## Prerequisites

- Azure Dev Box pool deployed (see `infra/devbox/README.md`)
- For validation: see [validation-checklist.md](validation-checklist.md)
- Mutagen installed locally on macOS
- Cursor with Remote SSH support
- SSH key configured for the Dev Box

## Daily Workflow

1. **Create a Dev Box from the approved pool**
   - Use Azure Portal, CLI, or API to create a Dev Box from your organization's pool.
   - Wait for the Dev Box to provision and become ready.

2. **Ensure `C:\dev` exists on the Dev Box**
   - Connect to the Dev Box using the approved first-login path (for example, RDP from the Azure portal).
   - On the Dev Box, create the workspace root if it is missing:
     ```powershell
     New-Item -ItemType Directory -Path C:\dev -Force
     ```

3. **Clone the repository on the Dev Box under `C:\dev\<repo>`**
   - The approved pool image should already include Git for this initial clone. The bootstrap step standardizes the host afterward.
   - On the Dev Box:
     ```powershell
     cd C:\dev
     git clone <repo-url> grpc
     cd grpc
     ```
   - Replace `<repo-url>` with the actual repository URL (e.g. `https://github.com/open-runtime/grpc-dart.git`).

4. **Run the Windows bootstrap script on the Dev Box**
   - **Run from an elevated (Administrator) PowerShell session.** The bootstrap installs system components and requires administrator privileges.
   - From the cloned repository on the Dev Box, run:
     ```powershell
     powershell.exe -ExecutionPolicy Bypass -File scripts/devbox/bootstrap-devbox.ps1 -Apply
     ```
   - This installs OpenSSH Server, Git, Docker Desktop, and configures the workspace root.
   - **Note:** Docker Desktop installation may require a reboot before Docker is usable. If `docker info` fails immediately after bootstrap, reboot the Dev Box and retry.

5. **Clone the repository locally on macOS**
   - On your Mac:
     ```bash
     mkdir -p ~/src
     git clone <repo-url> ~/src/grpc
     cd ~/src/grpc
     ```

6. **Before the first Mutagen sync, verify both clones are on the same branch and commit**
   - Because `.git` is excluded from sync, Git branch and history state must already match on both sides.
   - On the Dev Box clone, run:
     ```powershell
     git rev-parse --abbrev-ref HEAD
     git rev-parse HEAD
     ```
   - On the macOS clone, run:
     ```bash
     git rev-parse --abbrev-ref HEAD
     git rev-parse HEAD
     ```
   - If the branch name or commit SHA differs, fix that with Git before creating the first sync session.

7. **Create the first Mutagen session with the approved ignore list**
   - On your Mac, from the repo root:
     ```bash
     scripts/devbox/setup-local-mutagen.sh "$HOME/src/grpc" "devbox-alias:/C:/dev/grpc"
     ```
   - Replace `devbox-alias` with your SSH config host alias for the Dev Box.
   - The script uses `scripts/devbox/mutagen.ignore` to exclude `.git`, build outputs, caches, and IDE state.
   - This is a one-time creation step for the named session `devbox-handoff`.

8. **Reuse and health-check the existing Mutagen session on normal days**
   - Do not rerun `scripts/devbox/setup-local-mutagen.sh` if `devbox-handoff` already exists, because the script calls `mutagen sync create`.
   - Instead, run:
     ```bash
     mutagen sync list
     ```
   - Confirm the `devbox-handoff` session is present and healthy before you edit on either side.
   - If the session is missing because you ended it intentionally, recreate it with `scripts/devbox/setup-local-mutagen.sh`.

9. **Use local Cursor Remote SSH to open the Dev Box workspace**
   - In Cursor: Remote-SSH > Connect to Host > select your Dev Box alias.
   - Open the folder: `C:\dev\grpc` (or `C:\dev\<repo>` for your project).
   - All editing, builds, and tests run on the remote Windows host.

10. **Follow the single-writer handoff rule when switching sides**
   - Only one side (local or remote) should be actively edited at a time.
   - Before switching sides: wait for Mutagen sync to become healthy and idle.
   - Confirm both sides are on the same Git branch before resuming edits.
   - Git handles branch and history; Mutagen handles working-tree file sync only.

## Validation

Before relying on this workflow, run through the [validation checklist](validation-checklist.md). It covers ARM template validation, Dev Box creation, SSH, Cursor Remote SSH, Windows build/test, Docker Desktop, Mutagen sync, and single-writer handoff. Items that require a real Dev Box instance are clearly marked.

## Recovery

If something goes wrong, see [recovery.md](recovery.md) for troubleshooting steps.
