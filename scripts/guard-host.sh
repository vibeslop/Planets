#!/bin/zsh
host_idle_seconds() {
  ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'
}

require_idle() {
  local min_idle=${MIN_IDLE:-90}
  local idle=$(host_idle_seconds)
  if (( idle < min_idle )); then
    print -u2 -- "SKIP: host idle only ${idle}s (need >= ${min_idle}s; use ./scripts/when-idle.sh)"
    exit 2
  fi
}

require_idle_or_vm() {
  [[ "${PLANETS_IN_VM:-0}" == "1" ]] && return 0
  require_idle
}

require_vm() {
  [[ "${PLANETS_IN_VM:-0}" == "1" ]] && return 0
  if [[ "${ALLOW_HOST:-0}" != "1" ]]; then
    print -u2 -- "ABORT: run this script inside the Tart VM via ./scripts/vm.sh run (or set ALLOW_HOST=1 when idle)"
    exit 2
  fi
  require_idle
}
