# Environment setup

Tested on Ubuntu with PostgreSQL 17, sysbench 1.1.0 and `perf` from `linux-tools-$(uname -r)`.

## 1. Packages

```bash
sudo apt install postgresql sysbench linux-tools-common linux-tools-$(uname -r) python3-venv
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
```

Allow `perf` to read hardware counters of other users' processes (the scripts use `sudo perf`, so this is
only needed for running perf without sudo):

```bash
sudo sysctl -w kernel.perf_event_paranoid=1
```

## 2. Benchmark database and user

```bash
sudo -u postgres psql -c "CREATE USER sbtest WITH PASSWORD 'pass';"
sudo -u postgres psql -c "CREATE DATABASE sbtest OWNER sbtest;"
```

The scripts read `PG_USER` / `PG_PASS` / `PG_DB` / `PG_HOST` / `PG_PORT` (and `PGUSER` / `PGPASSWORD` / … for
`oltp_rw_sweep.sh`) from the environment, so a different password does not require editing them.

## 3. Isolate the variable: disable transparent huge pages

THP can silently back anonymous memory with 2 MB pages even in the "4 KB" runs, which would blur the comparison.

```bash
echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled
```

## 4. 4 KB baseline

In `postgresql.conf` (`sudo -u postgres psql -tAc 'SHOW config_file;'`):

```
huge_pages = off
```

then `sudo systemctl restart postgresql` and run the sweeps with `4k`.

## 5. 2 MB huge pages

1. Set the target `shared_buffers` (the largest one in the sweep) and restart PostgreSQL.
2. Size the explicit huge page pool:
   ```bash
   sudo scripts/hugepages_advisor.sh          # prints the vm.nr_hugepages value to use
   sudo sysctl -w vm.nr_hugepages=<value>
   ```
   Example: `shared_buffers = 4GB` needs roughly 2 100 × 2 MB pages. Reserve them early after boot, before
   memory fragments.
3. In `postgresql.conf` set
   ```
   huge_pages = on
   ```
   Use `on`, not `try`: with `try` PostgreSQL silently falls back to 4 KB pages when the pool is too small,
   and the "2 MB" results would be invalid. With `on` the server refuses to start instead.
4. Restart and verify:
   ```bash
   sudo systemctl restart postgresql
   sudo scripts/hugepages_status.sh   # HugePages_Free must drop / Rsvd rise, smaps shows KernelPageSize 2048 kB
   ```

## 6. Useful one-liners

```bash
sudo -u postgres psql -c "SHOW shared_buffers;"
grep Huge /proc/meminfo
cat /sys/kernel/mm/transparent_hugepage/enabled
```

Manual sysbench run (what the scripts automate):

```bash
sysbench oltp_point_select --db-driver=pgsql --pgsql-user=sbtest --pgsql-password=pass --pgsql-db=sbtest \
  --tables=4 --table-size=650000 prepare
sysbench oltp_point_select --db-driver=pgsql --pgsql-user=sbtest --pgsql-password=pass --pgsql-db=sbtest \
  --tables=4 --table-size=650000 --threads=16 --time=60 --warmup-time=30 run
sudo perf stat -e dTLB-loads,dTLB-load-misses,iTLB-loads,iTLB-load-misses,cycles,instructions,cache-misses \
  --pid=$(pgrep -d, -u postgres postgres) --timeout 50000
sysbench oltp_point_select --db-driver=pgsql --pgsql-user=sbtest --pgsql-password=pass --pgsql-db=sbtest \
  --tables=4 --table-size=650000 cleanup
```
