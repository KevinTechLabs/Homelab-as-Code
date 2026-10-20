#!/usr/bin/env bash
# Runs a playbook in CI and turns Ansible failures into GitHub annotations,
# so a failed task shows up on the run page without opening the raw log.
#   tests/ci-run.sh <log name> <ansible-playbook args...>
set -uo pipefail
log="$1"; shift
ansible-playbook "$@" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}

# "TASK [role : name]" followed by "fatal:" / "failed:" -> one annotation each
awk '
  /^TASK \[/ { task = $0; sub(/^TASK \[/, "", task); sub(/\].*$/, "", task) }
  /^(fatal|failed):/ { line = $0; gsub(/%/, "%25", line); print "::error title=" task "::" substr(line, 1, 900) }
' "$log"
exit "$rc"
