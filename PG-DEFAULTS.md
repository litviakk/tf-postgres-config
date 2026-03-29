# PostgreSQL Compiled Defaults vs Module Computed Values

## Default Parameter Values (PG 16 / 17 / 18)

| Parameter | PG Default | Context | Notes |
|---|---|---|---|
| max_connections | 100 | postmaster (restart) | |
| shared_buffers | 128MB | postmaster (restart) | |
| effective_cache_size | 4GB | user (no restart) | Planner hint only, no memory allocated |
| maintenance_work_mem | 64MB | user (no restart) | |
| work_mem | 4MB | user (no restart) | Per-operation, not per-connection. A single query can allocate work_mem multiple times (one per sort/hash node) |
| huge_pages | try | postmaster (restart) | Falls back to standard pages if kernel not configured |
| wal_buffers | -1 (auto: ~3% of shared_buffers) | postmaster (restart) | Auto minimum 64kB, effective max ~16MB |
| min_wal_size | 80MB | sighup (reload) | |
| max_wal_size | 1GB | sighup (reload) | |
| checkpoint_completion_target | 0.5 (PG16), 0.9 (PG17+) | sighup (reload) | Changed in PG 17 |
| default_statistics_target | 100 | user (no restart) | |
| random_page_cost | 4.0 | user (no restart) | Calibrated for HDD; too high for SSD |
| effective_io_concurrency | 1 | user (no restart) | Linux only; 0 on Windows/Mac |
| max_worker_processes | 8 | postmaster (restart) | |
| max_parallel_workers_per_gather | 2 | user (no restart) | |
| max_parallel_workers | 8 | user (no restart) | Bounded by max_worker_processes |
| max_parallel_maintenance_workers | 2 | user (no restart) | |

### Context definitions

- **postmaster**: set at server start only, requires full restart
- **sighup**: changed via config reload (`pg_reload_conf()`)
- **user**: changeable per-session (`SET work_mem = '64MB'`), also responds to reload

## PG Defaults vs Module Output (4GB host, 2 CPUs, SSD)

| Parameter | PG Default | Module Computed | Why |
|---|---|---|---|
| shared_buffers | 128MB | 1024MB | 25% of RAM |
| effective_cache_size | 4GB | 3072MB | 75% of RAM — more accurate than PG's generic 4GB guess |
| maintenance_work_mem | 64MB | 256MB | RAM/16 |
| work_mem | 4MB | 5MB | Scaled for 200 auto connections × 3 concurrency factor |
| max_connections | 100 | 200 | RAM-aware formula caps at 200 |
| random_page_cost | 4.0 | 1.1 | SSD random reads are near-sequential cost |
| effective_io_concurrency | 1 | 200 | SSDs handle many concurrent I/O operations |
| huge_pages | try | try | Same — module makes it explicit |
| wal_buffers | ~3.8MB (auto) | 7MB | 3% of 1024MB shared_buffers, explicit |
| checkpoint_completion_target | 0.5/0.9 | 0.9 | Module always uses 0.9 |

Parameters not in this table (min/max_wal_size, default_statistics_target,
parallel settings) are either unchanged from PG defaults or set to
workload-appropriate fixed values documented in the spec.

## PG Defaults vs Module Output (0.5GB host, 2 CPUs, SSD)

On small hosts, some module values match or are below PG defaults:

| Parameter | PG Default | Module Computed | Notes |
|---|---|---|---|
| shared_buffers | 128MB | 128MB | Tie — 25% of 0.5GB = 128MB |
| effective_cache_size | 4GB | 384MB | Module is more accurate (PG's 4GB is wrong for this host) |
| maintenance_work_mem | 64MB | 32MB | Module is lower but proportionally correct for 0.5GB |
| work_mem | 4MB | 4MB | Tie — formula gives 436kB, 4MB floor applied |
| max_connections | 100 | 32 | Module limits to 32 to keep work_mem at 4MB |

## Version-Specific Differences

| Version | Change | Impact on this module |
|---|---|---|
| PG 17 | `checkpoint_completion_target` default 0.5 → 0.9 | None — module always sets 0.9 |
| PG 17 | `max_parallel_workers` and `max_parallel_maintenance_workers` context confirmed as `user` | Module does not restart for these params |
