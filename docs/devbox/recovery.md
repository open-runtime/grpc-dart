# Dev Box Recovery Guide

When the Dev Box workflow encounters issues, use these recovery steps before resuming normal development.

## Remote SSH Fails

If Cursor Remote SSH cannot connect to the Dev Box:

1. **Verify SSH first outside Cursor**
   - From a terminal: `ssh devbox-alias hostname`
   - If this fails, the problem is SSH configuration or connectivity, not Cursor.
   - Check: SSH keys, `~/.ssh/config`, firewall, Dev Box status, network.

2. Fix SSH connectivity before retrying Cursor Remote SSH.

## Sync Drifts

If Mutagen reports conflicts or the sync state becomes unsafe:

1. **Stop editing immediately** on both local and remote.
2. **Pick one side as the temporary source of truth** (local or remote).
3. Resolve by either:
   - Pausing sync, copying the chosen side over the other, then resuming sync, or
   - Using Mutagen's conflict resolution tools as documented.
4. Do not resume editing until sync is healthy and both sides match.

## Branch State Diverges

If local and remote Git branches are out of alignment:

1. **Fix branch alignment with Git before resuming sync**
   - Sync does not carry `.git`; branch and history state are Git's responsibility.
   - On the side that is behind: `git fetch` and `git checkout` or `git merge`/`git rebase` as needed.
   - Ensure both sides are on the same branch and commit before resuming file sync.

## Generated Files Churn

If generated files (build outputs, caches, tool artifacts) cause sync noise or conflicts:

1. **Tighten ignores instead of accepting the noise**
   - Add patterns to `scripts/devbox/mutagen.ignore`.
   - Do not sync generated artifacts; they should be rebuilt on each side.
   - Restart the Mutagen session after updating the ignore list. Ignores are locked in at session creation, so you must terminate and recreate the session:
     ```bash
     mutagen sync terminate devbox-handoff
     scripts/devbox/setup-local-mutagen.sh "$HOME/src/grpc" "devbox-alias:/C:/dev/grpc"
     ```
     Replace `devbox-alias` with your SSH config host alias. If termination hangs, see [Mutagen documentation](https://mutagen.io/documentation/synchronization/ignores) for session lifetime behavior. See [README](README.md) for the normal Mutagen workflow.
