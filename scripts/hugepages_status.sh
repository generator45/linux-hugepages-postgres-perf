#!/usr/bin/env bash
# Verify which page size PostgreSQL's shared memory is actually backed by.
# Run it while the server is up (ideally during a benchmark) - a "2 MB" result
# is only trustworthy if HugePages_Total - HugePages_Free (+ Rsvd) is non-zero
# and the shared-memory mapping of the postmaster shows KernelPageSize: 2048 kB.
set -euo pipefail

echo "== Kernel huge page pool (/proc/meminfo)"
grep -E '^(HugePages_|Hugepagesize|AnonHugePages)' /proc/meminfo

echo
echo "== Transparent huge pages"
echo "enabled: $(cat /sys/kernel/mm/transparent_hugepage/enabled)"
echo "defrag : $(cat /sys/kernel/mm/transparent_hugepage/defrag)"

echo
echo "== PostgreSQL settings"
sudo -u postgres psql -tAc "SELECT name || ' = ' || setting || COALESCE(' ' || unit, '')
                            FROM pg_settings
                            WHERE name IN ('huge_pages', 'huge_page_size', 'shared_buffers',
                                           'shared_memory_size', 'shared_memory_size_in_huge_pages')
                            ORDER BY name;" 2>/dev/null || echo "(could not query PostgreSQL)"

echo
echo "== Page size of the largest mappings of the postmaster"
PGDATA="$(sudo -u postgres psql -tAc 'SHOW data_directory;' 2>/dev/null || true)"
if [[ -n "$PGDATA" ]] && sudo test -e "$PGDATA/postmaster.pid"; then
    PG_PID="$(sudo head -1 "$PGDATA/postmaster.pid")"
    sudo awk '
        /^[0-9a-f]+-[0-9a-f]+ / { name = ($6 == "" ? "[anon]" : $6) }
        /^Size:/                { size = $2 }
        /^KernelPageSize:/      { printf "%10d kB  page=%5d kB  %s\n", size, $2, name }
    ' "/proc/$PG_PID/smaps" | sort -rn | head -5
else
    echo "(postmaster not found)"
fi
