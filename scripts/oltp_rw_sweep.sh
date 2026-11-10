#!/usr/bin/env bash
# Throughput / latency sweep with sysbench oltp_read_write on PostgreSQL.
# Sweeps table size x client threads; one log per run is written to
# data/oltp_read_write/<page-mode>/run_ts<rows>_th<threads>.log
#
# Usage:
#   scripts/oltp_rw_sweep.sh 4k     # huge_pages = off
#   scripts/oltp_rw_sweep.sh 2mb    # huge_pages = on
set -euo pipefail

PAGE_MODE="${1:?usage: $0 <4k|2mb>}"
case "$PAGE_MODE" in 4k|2mb) ;; *) echo "page mode must be 4k or 2mb" >&2; exit 2 ;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-sbtest}"
PGPASSWORD="${PGPASSWORD:-pass}"
PGDB="${PGDB:-sbtest}"
export PGPASSWORD

SYSBENCH_LUA="${SYSBENCH_LUA:-oltp_read_write}"
TABLES="${TABLES:-10}"
read -r -a TABLE_SIZES <<< "${TABLE_SIZES:-100000 500000}"
read -r -a THREADS <<< "${THREADS:-16 32 64}"
TIME="${TIME:-120}"
WARMUP="${WARMUP:-20}"
RAND_TYPE="${RAND_TYPE:-uniform}"

OUT_DIR="${OUT_DIR:-$REPO_ROOT/data/oltp_read_write/$PAGE_MODE}"
mkdir -p "$OUT_DIR"

sb_common=(
    --db-driver=pgsql
    --pgsql-host="$PGHOST" --pgsql-port="$PGPORT"
    --pgsql-user="$PGUSER" --pgsql-password="$PGPASSWORD" --pgsql-db="$PGDB"
    --tables="$TABLES"
)

hp="$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDB" -tAc 'SHOW huge_pages;')"
echo "[INFO] page mode=$PAGE_MODE, postgres huge_pages=$hp, output=$OUT_DIR"
if [[ "$PAGE_MODE" == 2mb && "$hp" != on ]] || [[ "$PAGE_MODE" == 4k && "$hp" == on ]]; then
    echo "[ERROR] huge_pages=$hp does not match page mode $PAGE_MODE (see docs/setup.md)" >&2
    exit 1
fi

for table_size in "${TABLE_SIZES[@]}"; do
    echo "[INFO] Preparing ${TABLES} tables x ${table_size} rows"
    sysbench "$SYSBENCH_LUA" "${sb_common[@]}" --table-size="$table_size" cleanup >/dev/null 2>&1 || true
    sysbench "$SYSBENCH_LUA" "${sb_common[@]}" --table-size="$table_size" prepare

    for threads in "${THREADS[@]}"; do
        log_file="$OUT_DIR/run_ts${table_size}_th${threads}.log"
        echo "[INFO] Running table_size=${table_size}, threads=${threads} -> $log_file"
        sysbench "$SYSBENCH_LUA" "${sb_common[@]}" \
            --table-size="$table_size" \
            --threads="$threads" \
            --time="$TIME" \
            --warmup-time="$WARMUP" \
            --report-interval=0 \
            --rand-type="$RAND_TYPE" \
            run | tee "$log_file"
    done

    sysbench "$SYSBENCH_LUA" "${sb_common[@]}" --table-size="$table_size" cleanup || true
done

echo "[INFO] Done. Analyse with: python3 analysis/analyze.py"
