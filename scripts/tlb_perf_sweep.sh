#!/usr/bin/env bash
# Run sysbench oltp_point_select against PostgreSQL while sampling hardware
# TLB/cycle counters of all postgres processes with `perf stat`.
#
# Sweeps: dataset size x shared_buffers x client threads.
# One log file per run is written to data/point_select_perf/<page-mode>/.
#
# Usage:
#   scripts/tlb_perf_sweep.sh 4k      # with huge_pages = off  in postgresql.conf
#   scripts/tlb_perf_sweep.sh 2mb     # with huge_pages = on   (see docs/setup.md)
#
# Every connection setting can be overridden from the environment, e.g.
#   PG_PASS=secret THREAD_COUNTS="8 32" scripts/tlb_perf_sweep.sh 2mb
set -euo pipefail

PAGE_MODE="${1:?usage: $0 <4k|2mb>}"
case "$PAGE_MODE" in 4k|2mb) ;; *) echo "page mode must be 4k or 2mb" >&2; exit 2 ;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

PG_USER="${PG_USER:-sbtest}"
PG_PASS="${PG_PASS:-pass}"
PG_DB="${PG_DB:-sbtest}"
PG_HOST="${PG_HOST:-localhost}"
PG_PORT="${PG_PORT:-5432}"

SB_SCRIPT="oltp_point_select"
RESULTS_DIR="${RESULTS_DIR:-$REPO_ROOT/data/point_select_perf/$PAGE_MODE}"

WARMUP_TIME="${WARMUP_TIME:-30}"
RUN_TIME="${RUN_TIME:-60}"
# perf starts after warm-up and stops before sysbench finishes, so it only
# observes steady state: [PERF_START_DELAY, PERF_START_DELAY + PERF_DURATION]
PERF_START_DELAY="${PERF_START_DELAY:-35}"
PERF_DURATION="${PERF_DURATION:-50}"
if (( PERF_START_DELAY < WARMUP_TIME || PERF_START_DELAY + PERF_DURATION > WARMUP_TIME + RUN_TIME )); then
    echo "perf window must lie inside the measured (post-warm-up) interval" >&2; exit 2
fi

# Dataset i = DATASET_LABELS[i] built from DATASET_TABLES[i] x DATASET_ROWS[i] rows
# and benchmarked with every shared_buffers value in SB_SIZES_<i>.
# Keep these IDENTICAL between the 4k and 2mb sweeps, otherwise runs cannot be paired.
DATASET_LABELS=(500MB 2GB 4GB)
DATASET_TABLES=(4 4 4)
DATASET_ROWS=(650000 2600000 5200000)
SB_SIZES_0="${SB_SIZES_0:-256MB 1GB}"   # below / above dataset size
SB_SIZES_1="${SB_SIZES_1:-1GB 3GB}"
SB_SIZES_2="${SB_SIZES_2:-2GB 4GB}"
read -r -a THREAD_COUNTS <<< "${THREAD_COUNTS:-4 16 64}"

PERF_EVENTS="dTLB-loads,dTLB-load-misses,iTLB-loads,iTLB-load-misses,cycles,instructions,cache-misses"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
sep() { echo "================================================================"; }

sb_common=(
    --db-driver=pgsql
    --pgsql-host="$PG_HOST" --pgsql-port="$PG_PORT"
    --pgsql-user="$PG_USER" --pgsql-password="$PG_PASS" --pgsql-db="$PG_DB"
)

preflight_checks() {
    local cmd
    for cmd in sysbench perf psql pgrep; do
        command -v "$cmd" >/dev/null || { echo "missing dependency: $cmd" >&2; exit 1; }
    done
    mkdir -p "$RESULTS_DIR"
    local hp
    hp="$(sudo -u postgres psql -tAc 'SHOW huge_pages;')"
    log "page mode=$PAGE_MODE  postgres huge_pages=$hp  THP=$(cat /sys/kernel/mm/transparent_hugepage/enabled)"
    if [[ "$PAGE_MODE" == 2mb && "$hp" != on ]]; then
        echo "2mb mode requires huge_pages = on (not '$hp'); 'try' silently falls back to 4 KB pages" >&2
        exit 1
    fi
    if [[ "$PAGE_MODE" == 4k && "$hp" == on ]]; then
        echo "4k mode requires huge_pages = off" >&2; exit 1
    fi
}

find_pg_conf() { sudo -u postgres psql -tAc "SHOW config_file;"; }

set_shared_buffers() {
    local size="$1" conf="$2"
    [[ -f "${conf}.bk_benchmark" ]] || sudo cp "$conf" "${conf}.bk_benchmark"
    # `sed -i` succeeds even when nothing matches, so test for the key explicitly.
    if sudo grep -qE '^[#[:space:]]*shared_buffers' "$conf"; then
        sudo sed -i -E "s|^[#[:space:]]*shared_buffers.*|shared_buffers = $size|" "$conf"
    else
        echo "shared_buffers = $size" | sudo tee -a "$conf" >/dev/null
    fi
}

restart_pg() {
    sudo systemctl restart postgresql || sudo service postgresql restart
    # wait until the server accepts connections instead of a fixed sleep
    local i
    for i in $(seq 1 30); do
        PGPASSWORD="$PG_PASS" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -qtAc 'SELECT 1' >/dev/null 2>&1 && return 0
        sleep 1
    done
    echo "PostgreSQL did not come back up (huge page reservation too small?)" >&2
    exit 1
}

restore_pg_conf() {
    local conf
    conf="$(find_pg_conf)" || return 0
    if [[ -f "${conf}.bk_benchmark" ]]; then
        sudo cp "${conf}.bk_benchmark" "$conf"
        sudo rm -f "${conf}.bk_benchmark"
        restart_pg
    fi
}

prepare_dataset() {
    sysbench "$SB_SCRIPT" "${sb_common[@]}" --tables="$1" --table-size="$2" --threads=16 prepare
}

cleanup_dataset() {
    sysbench "$SB_SCRIPT" "${sb_common[@]}" --tables="$1" --table-size="$2" cleanup || true
}

write_header() {
    {
        echo "========================================================="
        echo "Page mode      : $PAGE_MODE"
        echo "Dataset        : $1"
        echo "Tables         : $2"
        echo "Rows/Table     : $3"
        echo "shared_buffers : $4"
        echo "Threads        : $5"
        echo "Timestamp      : $(date)"
        echo "Kernel         : $(uname -r)"
        echo "HugePages      : $(grep -E '^HugePages_(Total|Free|Rsvd)' /proc/meminfo | tr -s ' ' | paste -sd' ')"
        echo "========================================================="
    } > "$6"
}

# Fixed-format summary, consumed by print_final_summary below.
append_summary() {
    local file="$1" tps dtlb ipc
    tps=$(grep -oP 'transactions:\s+\d+\s+\(\K[0-9.]+(?= per sec\.\))' "$file" | tail -1 || true)
    dtlb=$(grep -oP 'dTLB-load-misses\s+#\s+\K[0-9.]+(?=%)' "$file" | head -1 || true)
    ipc=$(grep -oP '#\s+\K[0-9.]+(?=\s+insn per cycle)' "$file" | head -1 || true)
    {
        echo ""
        echo "================ SUMMARY ================"
        echo "SUMMARY_TPS=${tps:-NA}"
        echo "SUMMARY_DTLB_MISS_PCT=${dtlb:-NA}"
        echo "SUMMARY_IPC=${ipc:-NA}"
        echo "========================================"
    } >> "$file"
}

run_benchmark() {
    local label="$1" tables="$2" rows="$3" sb_size="$4" threads="$5"
    local file="${RESULTS_DIR}/r_${label}_${threads}t_${sb_size}.txt"
    local sb_out perf_out
    sb_out="$(mktemp)"; perf_out="$(mktemp)"

    sep; log "RUN | $PAGE_MODE | $label | sb=$sb_size | threads=$threads"; sep
    write_header "$label" "$tables" "$rows" "$sb_size" "$threads" "$file"

    sysbench "$SB_SCRIPT" "${sb_common[@]}" \
        --tables="$tables" --table-size="$rows" --threads="$threads" \
        --time="$RUN_TIME" --warmup-time="$WARMUP_TIME" \
        run > "$sb_out" 2>&1 &
    local sb_pid=$!

    sleep "$PERF_START_DELAY"
    # Backends for the sysbench connections exist by now, so they are included.
    local pids
    pids="$(pgrep -d, -u postgres postgres)"
    sudo perf stat -e "$PERF_EVENTS" --pid="$pids" --timeout $((PERF_DURATION * 1000)) \
        > "$perf_out" 2>&1 || true

    wait "$sb_pid"

    # Write sections sequentially so sysbench and perf output never interleave.
    { echo -e "\n==== SYSBENCH ====\n"; cat "$sb_out"; echo -e "\n==== PERF ====\n"; cat "$perf_out"; } >> "$file"
    rm -f "$sb_out" "$perf_out"
    append_summary "$file"
    sleep 5
}

print_final_summary() {
    sep; echo "FINAL SUMMARY ($PAGE_MODE)"; sep
    printf "%-30s %12s %10s %8s\n" "Run" "TPS" "dTLB miss%" "IPC"
    local file
    for file in "${RESULTS_DIR}"/r_*.txt; do
        [[ -f "$file" ]] || continue
        printf "%-30s %12s %10s %8s\n" "$(basename "$file" .txt)" \
            "$(sed -n 's/^SUMMARY_TPS=//p' "$file")" \
            "$(sed -n 's/^SUMMARY_DTLB_MISS_PCT=//p' "$file")" \
            "$(sed -n 's/^SUMMARY_IPC=//p' "$file")"
    done
    echo "Full analysis: python3 analysis/analyze.py"
}

main() {
    preflight_checks
    local pg_conf i sb threads sb_list
    pg_conf="$(find_pg_conf)"

    for i in "${!DATASET_LABELS[@]}"; do
        local label="${DATASET_LABELS[$i]}" tables="${DATASET_TABLES[$i]}" rows="${DATASET_ROWS[$i]}"
        sb_list="SB_SIZES_$i"
        cleanup_dataset "$tables" "$rows"
        prepare_dataset "$tables" "$rows"
        for sb in ${!sb_list}; do
            set_shared_buffers "$sb" "$pg_conf"
            restart_pg
            for threads in "${THREAD_COUNTS[@]}"; do
                run_benchmark "$label" "$tables" "$rows" "$sb" "$threads"
            done
        done
        cleanup_dataset "$tables" "$rows"
    done

    restore_pg_conf
    print_final_summary
}

export PGPASSWORD="$PG_PASS"
trap 'restore_pg_conf; exit 1' INT TERM
main "$@"
