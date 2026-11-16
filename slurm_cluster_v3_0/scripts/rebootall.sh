#!/bin/bash
# =============================================================================
# rebootall.sh  -  run on the HEAD node as your NORMAL user (not root / sudo):
#
#   bash rebootall.sh              (asks at the end whether to reboot the head)
#   bash rebootall.sh --no-head    (workers only, never touches the head)
#
# Reboots every worker node (and, if you say yes, the head last).
#   - asks for the password once and uses it for sudo on every node
#   - skips nodes that do not answer SSH and tells you which ones
#   - warns if Slurm jobs are running (a reboot kills them)
#   - reboots all reachable nodes in parallel
# =============================================================================

CUSER=${CUSER:-elec_cluster}
PREFIX=${PREFIX:-node}
START=${START:-0}
END=${END:-14}

SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes -o LogLevel=ERROR"

# Options:  --no-head  reboot only the worker nodes, never ask about the head
NO_HEAD=0
for arg in "$@"; do
  case "$arg" in
    --no-head) NO_HEAD=1 ;;
    -h|--help) echo "Usage: rebootall [--no-head]"; echo "  --no-head   reboot only the worker nodes, never ask about the head"; exit 0 ;;
    *) echo "Unknown option: $arg (try --help)" >&2; exit 1 ;;
  esac
done

if [ "$EUID" -eq 0 ]; then
  echo "Run this as your normal user (not root / not with sudo)." >&2
  exit 1
fi

read -r -p "Cluster user [$CUSER]: " IN; CUSER=${IN:-$CUSER}
read -r -p "Node name prefix [$PREFIX]: " IN; PREFIX=${IN:-$PREFIX}
read -r -p "First node index [$START]: " IN; START=${IN:-$START}
read -r -p "Last node index [$END]: " IN; END=${IN:-$END}
read -r -s -p "Password (same on all machines): " PASS; echo
trap 'unset PASS' EXIT

[[ "$START" =~ ^[0-9]+$ && "$END" =~ ^[0-9]+$ && "$END" -ge "$START" ]] \
  || { echo "Invalid node range $START..$END." >&2; exit 1; }
[ -n "$PASS" ] || { echo "Password cannot be empty." >&2; exit 1; }

# Warn about running Slurm jobs.
if command -v squeue >/dev/null 2>&1; then
  RUNNING=$(squeue -h -t R 2>/dev/null | wc -l)
  if [ "$RUNNING" -gt 0 ]; then
    echo "WARNING: $RUNNING Slurm job(s) are running. Rebooting will kill them."
    squeue -t R 2>/dev/null | head -n 10
  fi
fi

read -r -p "Reboot ${PREFIX}${START} .. ${PREFIX}${END}? [y/N]: " OK
[[ "$OK" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }

# Each reboot is scheduled 2 seconds ahead in the background, so ssh returns
# normally and the exit status tells us whether sudo (the password) worked.
reboot_node() {
  local N=$1
  if ! ssh $SSH_OPTS "$CUSER@$N" true 2>/dev/null; then
    echo "[SKIP] $N: no SSH answer (off, no route, or no key login)"
    return
  fi
  if printf '%s\n' "$PASS" | ssh $SSH_OPTS "$CUSER@$N" \
       "sudo -S -p '' sh -c '(sleep 2; systemctl reboot) >/dev/null 2>&1 &'" 2>/dev/null; then
    echo "[ OK ] $N: reboot sent"
  else
    echo "[FAIL] $N: sudo failed (wrong password, or $CUSER may not use sudo)"
  fi
}

for i in $(seq "$START" "$END"); do
  reboot_node "${PREFIX}${i}" &
done
wait

# The head last, only if you want it.
echo
if [ "$NO_HEAD" -eq 1 ]; then
  echo "Head not rebooted (--no-head)."
else
  read -r -p "Also reboot the head (this machine) now? [y/N]: " OK
  if [[ "$OK" =~ ^[Yy]$ ]]; then
    printf '%s\n' "$PASS" | sudo -S -p '' systemctl reboot
    exit 0
  fi
  echo "Head not rebooted."
fi
echo "When the nodes are back: sinfo   (if a node stays down: sudo scontrol update nodename=<node> state=resume)"
