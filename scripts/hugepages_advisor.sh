#!/usr/bin/env bash
# Suggest a vm.nr_hugepages value for the running PostgreSQL instance.
#
# Preferred: ask PostgreSQL itself (v15+ exposes shared_memory_size_in_huge_pages).
# Fallback:  VmPeak of the postmaster / Hugepagesize (the classic recipe from
#            the PostgreSQL docs), which slightly over-estimates.
#
# Usage: sudo scripts/hugepages_advisor.sh [PGDATA]
set -euo pipefail

PGDATA="${1:-${PGDATA:-}}"
if [[ -z "$PGDATA" ]]; then
    PGDATA="$(sudo -u postgres psql -tAc 'SHOW data_directory;' 2>/dev/null || true)"
fi
[[ -n "$PGDATA" ]] || { echo "PGDATA is not set and could not be queried" >&2; exit 1; }

PIDFILE="$PGDATA/postmaster.pid"
HP_KB="$(awk '/^Hugepagesize/ {print $2}' /proc/meminfo)"
echo "Hugepagesize: ${HP_KB} kB"

pg_hp="$(sudo -u postgres psql -tAc 'SHOW shared_memory_size_in_huge_pages;' 2>/dev/null || true)"
if [[ "$pg_hp" =~ ^[0-9]+$ && "$pg_hp" -gt 0 ]]; then
    echo "PostgreSQL reports it needs $pg_hp huge pages for shared memory."
    NEEDED="$pg_hp"
else
    sudo test -e "$PIDFILE" || { echo "Cannot find $PIDFILE - is PostgreSQL running?" >&2; exit 1; }
    PG_PID="$(sudo head -1 "$PIDFILE")"
    read -r PG_MEM PG_UNIT < <(awk '/^VmPeak/ {print $2, $3}' "/proc/$PG_PID/status")
    [[ "$PG_UNIT" == kB ]] || { echo "unexpected VmPeak unit '$PG_UNIT'" >&2; exit 1; }
    NEEDED=$(( (PG_MEM + HP_KB - 1) / HP_KB ))   # round up
    echo "postmaster (pid $PG_PID) VmPeak: ${PG_MEM} kB"
fi

echo "Advised number of huge pages: $NEEDED"
echo "Apply with:  sudo sysctl -w vm.nr_hugepages=$NEEDED"
echo "Persist via: echo 'vm.nr_hugepages=$NEEDED' | sudo tee /etc/sysctl.d/60-hugepages.conf"
