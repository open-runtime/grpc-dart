#!/usr/bin/env bash
set -euo pipefail

# Smoke test for local Mutagen sync assets (Task 3).
# Verifies required files exist and .gitattributes has correct line-ending policy.

test -f scripts/devbox/setup-local-mutagen.sh
test -f scripts/devbox/mutagen.ignore
test -f .gitattributes
grep -qE '^\* text=auto eol=lf$' .gitattributes
grep -qE '^\*\.cmd text eol=crlf$' .gitattributes
grep -qE '^\*\.bat text eol=crlf$' .gitattributes
grep -qE '^\*\.ps1 text eol=crlf$' .gitattributes
