# Module Spec: `modules/postgres`

Version: 6.0
Terraform/OpenTofu: >= 1.5
Required providers: `hashicorp/null` >= 3.0
Target OS: Linux (Debian/Ubuntu with `pg_ctlcluster`)
Target PostgreSQL: 16, 17, 18

---

## Responsibility

Compute optimal PostgreSQL performance parameters from hardware facts (RAM, CPU, storage) and deliver them to a running Linux instance via SSH.

1. Calculate parameters using the pgtune algorithm (web workload profile, ported from [le0pard/pgtune](https://github.com/le0pard/pgtune))
2. Write computed values to `conf.d/01-pgtune.conf`
3. Write caller-supplied overrides to `conf.d/02-overrides.conf`
4. Run pre-flight checks
5. Apply with `pg_ctlcluster reload`; restart only when changed parameters require it
6. Expose the resolved parameter map for plan-time restart detection on subsequent applies

**Out of scope:** host/container provisioning, PostgreSQL installation, `pg_hba.conf`, base `postgresql.conf` settings (`listen_addresses`, `ssl`, `wal_level`, etc.), role/database/schema management, backup, HA/replication, SSH bastion.

This module owns exactly two files on the target:

```
/etc/postgresql/<pg_version>/<pg_cluster_name>/conf.d/01-pgtune.conf
/etc/postgresql/<pg_version>/<pg_cluster_name>/conf.d/02-overrides.conf
```

---

## Configuration Layering

```
Layer 1: postgresql.conf               ← base config (not managed)
Layer 2: conf.d/01-pgtune.conf         ← this module: computed values
Layer 3: conf.d/02-overrides.conf      ← this module: pg_overrides
Layer 4: conf.d/03-*.conf …            ← other drop-in config (if any)
Layer 5: postgresql.auto.conf          ← ALTER SYSTEM (takes precedence over conf.d/)
```

---

## Managed Parameters

| Parameter | Category | Restart | What it controls |
|---|---|---|---|
| `max_connections` | Connections | yes | Maximum concurrent client connections |
| `shared_buffers` | Memory | yes | PostgreSQL's dedicated shared memory cache |
| `effective_cache_size` | Memory | no | Planner estimate of total cache available |
| `maintenance_work_mem` | Memory | no | Memory for VACUUM, CREATE INDEX, and maintenance |
| `work_mem` | Memory | no | Per-operation memory for sorts and hash joins |
| `huge_pages` | Memory | yes | Use OS huge pages to reduce TLB pressure |
| `wal_buffers` | WAL | yes | Shared memory for WAL records before flush |
| `min_wal_size` | WAL | no | Minimum WAL retention on disk |
| `max_wal_size` | WAL | no | WAL size threshold that triggers a checkpoint |
| `checkpoint_completion_target` | WAL | no | Fraction of checkpoint interval to spread I/O over |
| `default_statistics_target` | Planner | no | Rows sampled when computing planner statistics |
| `random_page_cost` | Planner | no | Estimated cost of a non-sequential page fetch |
| `effective_io_concurrency` | Planner | no | Expected concurrent disk I/O operations |
| `max_worker_processes` | Parallelism | yes | Total background worker slots |
| `max_parallel_workers_per_gather` | Parallelism | no | Max parallel workers per query Gather node |
| `max_parallel_workers` | Parallelism | no | Total workers available for parallel queries |
| `max_parallel_maintenance_workers` | Parallelism | no | Parallel workers for maintenance (e.g. CREATE INDEX) |

Parallelism parameters are omitted entirely when `pg_cpu_num = 1`.

---

## File Layout

```
modules/postgres/
├── variables.tf
├── locals.tf
├── main.tf
├── outputs.tf
└── templates/
    ├── preflight.sh.tftpl
    ├── postgresql_tune.conf.tftpl
    └── postgresql_overrides.conf.tftpl
```

---

## `variables.tf`

All variables set `nullable = false`. Integer-constrained variables validate `var.x == floor(var.x)`.

| Variable | Type | Default | Constraints | Notes |
|---|---|---|---|---|
| `pg_version` | number | required | 16 \| 17 \| 18 | Controls `pg_ctlcluster` version arg and conf.d path |
| `pg_total_memory_gb` | number | required | > 0, fractional OK | Primary sizing input. Warning outside 0.25–100GB range |
| `pg_cpu_num` | number | 2 | positive integer ≥ 1 | When 1, all parallel params omitted entirely |
| `pg_connection_num` | number | 0 | non-negative integer | 0 = auto; explicit value bypasses RAM-based limiting; warning if work_mem < 4MB results |
| `pg_hd_type` | string | `"ssd"` | hdd \| ssd \| san | Controls `random_page_cost` and `effective_io_concurrency` |
| `pg_overrides` | map(string) | `{}` | keys = managed param names; values = valid postgresql.conf strings | Written to `02-overrides.conf`; unrecognised keys ignored with warning |
| `current_pg_config` | map(string) | `{}` | — | Feed from `output.resolved_config`; empty on first apply triggers full restart [^1] |
| `ssh_host` | string | required | — | IP or hostname of the target |
| `ssh_user` | string | `"ubuntu"` | — | Must have passwordless sudo for file ops and `pg_ctlcluster` |
| `ssh_private_key` | string | required | sensitive | File contents (not a path); use `file()` in caller |
| `ssh_port` | number | 22 | integer 1–65535 | — |
| `pg_cluster_name` | string | `"main"` | — | Standard Debian/Ubuntu default |
| `conf_d_dir` | string | `""` | absolute path or empty | When empty, derived as `/etc/postgresql/<pg_version>/<pg_cluster_name>/conf.d` |

[^1]: Never manually construct this map. Always source from `output.resolved_config`. Wire as: `current_pg_config = var.pg_applied_config` where `pg_applied_config` is fed from the previous apply's `output.resolved_config`.

---

## `locals.tf`

All intermediate memory values are in **KiB**. `pgtune` holds calculated values; `resolved` is the effective map after overrides.

### Parameter formulas

| Parameter | Formula | Notes |
|---|---|---|
| `_parallel_enabled` | `pg_cpu_num >= 2` | — |
| `_wpg_capped` | `min(ceil(pg_cpu_num / 2), 4)` | Cap of 4 for diminishing returns / hyperthreading |
| `_wm_parallel_factor` | `_wpg_capped` if parallel enabled, else `1` | — |
| `shared_buffers` | `floor(total_memory_kb / 4)` | ¼ RAM |
| `effective_cache_size` | `floor(total_memory_kb × 0.75)` | ¾ RAM |
| `maintenance_work_mem` | `min(floor(total_memory_kb / 16), 2GB)` | — |
| `max_connections` | `pg_connection_num > 0 ? pg_connection_num : min(200, floor((total_kb − shared_buffers_kb) / (3 × parallel_factor × 4096)))` | Auto formula guarantees work_mem ≥ 4MB |
| `work_mem` | `max(4096kB, floor((total_kb − shared_buffers_kb) / (max_connections × 3) / parallel_factor))` | ×3 denominator for multi-node query plans |
| `wal_buffers` | `max(32kB, min(shared_buffers × 3%, 16MB))`; values in [14MB, 16MB) round up to 16MB | 3% matches PostgreSQL's own auto-tuning heuristic |
| `min_wal_size` | `1024MB` (fixed) | — |
| `max_wal_size` | `4096MB` (fixed) | — |
| `checkpoint_completion_target` | `0.9` (fixed) | PG17+ default; applied to PG16 for consistency |
| `default_statistics_target` | `100` (fixed) | — |
| `random_page_cost` | `4` (hdd) / `1.1` (ssd / san) | — |
| `effective_io_concurrency` | `2` (hdd) / `200` (ssd) / `300` (san) | — |
| `huge_pages` | `try` (fixed) | — |
| `max_worker_processes` | `pg_cpu_num` (omitted if `pg_cpu_num = 1`) | — |
| `max_parallel_workers_per_gather` | `_wpg_capped` (omitted if `pg_cpu_num = 1`) | — |
| `max_parallel_workers` | `pg_cpu_num` (omitted if `pg_cpu_num = 1`) | — |
| `max_parallel_maintenance_workers` | `_wpg_capped` (omitted if `pg_cpu_num = 1`) | — |

### Restart detection

Restart-required params: `shared_buffers`, `max_connections`, `wal_buffers`, `max_worker_processes`, `huge_pages`. All others are reload-safe.

`params_needing_restart` diffs `resolved` vs `current_pg_config`. Also fires when a restart-required param moves from active to omitted (e.g. `pg_cpu_num` drops to 1).

---

## `templates/preflight.sh.tftpl`

Runs before config delivery. Receives: `pg_version`, `pg_cluster_name`, `conf_d_dir`, managed param names.

**Checks (exit non-zero on failure):**
- `pg_ctlcluster` binary is present
- Cluster `<pg_version>/<pg_cluster_name>` is in `online` state
- `conf.d` directory exists at the configured path

**Informational (non-blocking):**
- If `postgresql.auto.conf` contains any managed parameters, emit a notice (`ALTER SYSTEM` takes precedence over `conf.d/`)

---

## Output Example

Inputs: `pg_version=17`, `pg_total_memory_gb=8`, `pg_cpu_num=4`, `pg_hd_type=ssd`, `pg_overrides={work_mem="32MB"}`.

**`conf.d/01-pgtune.conf`**

```
# postgresql.conf — performance tuning (PostgreSQL 17)
# Managed by Terraform. Do not edit manually.
# Overwritten on every terraform apply.
# Algorithm: https://github.com/le0pard/pgtune
# Inputs: 8GB RAM, 4 CPUs, ssd

# Connections
max_connections = 200

# Memory
shared_buffers           = 2048MB
effective_cache_size     = 6144MB
maintenance_work_mem     = 512MB
work_mem                 = 5MB
huge_pages               = try

# WAL
wal_buffers                  = 16MB
min_wal_size                 = 1024MB
max_wal_size                 = 4096MB
checkpoint_completion_target = 0.9

# Planner
default_statistics_target = 100
random_page_cost          = 1.1
effective_io_concurrency  = 200

# Parallelism
max_worker_processes             = 4
max_parallel_workers_per_gather  = 2
max_parallel_workers             = 4
max_parallel_maintenance_workers = 2
```

**`conf.d/02-overrides.conf`**

```
# postgresql.conf — manual overrides
# Managed by Terraform via pg_overrides variable.
# Loaded after 01-pgtune.conf — values here take precedence.
# Do not edit manually — overwritten on every terraform apply.
work_mem = 32MB
```

---

## `main.tf`

Two `null_resource` resources with separate triggers.

### `pg_preflight` — environment validation

Triggers: `ssh_host`, `ssh_port`, `pg_version`, `pg_cluster_name`. Runs pre-flight script via SSH; does not re-run on config-only changes.

### `pg_config` — config delivery and apply

Triggers: `config_hash`, `ssh_host`. Depends on `pg_preflight`. Uploads both conf files, then runs reload (always) followed by restart if `params_needing_restart` is non-empty. Reload fires first to validate config syntax before committing to a restart.

### Execution model

| What changed | preflight runs? | config deploys? | reload? | restart? |
|---|---|---|---|---|
| First apply | yes | yes | yes | yes |
| Host changes | yes | yes | yes | yes |
| pgtune input changes (RAM, CPU, storage) | no | yes | yes | if restart param changed |
| Only `pg_overrides` changes | no | yes | yes | if restart param changed |
| Override changes `work_mem` | no | yes | yes | no |
| Override changes `shared_buffers` | no | yes | yes | yes |
| `pg_version` or `pg_cluster_name` changes | yes | yes | yes | yes |
| Nothing changes | no | no | no | no |

---

## `outputs.tf`

| Output | Type | Description |
|---|---|---|
| `resolved_config` | `map(string)` | Effective parameter map after pgtune + overrides merge. Feed into `current_pg_config` on next apply. |
| `pgtune_calculated` | `map(string)` | Raw pgtune values before override merge (contents of `01-pgtune.conf`). |
| `effective_overrides` | `map(object)` | Per-key status of `pg_overrides`: `pgtune`, `override`, `active` values. |
| `restart_required` | `map(object) \| null` | Non-null when restart-requiring params changed; each entry has `old` and `new`. |
| `config_file_paths` | `object` | Absolute paths of both conf files on the host. |
| `warnings` | `list(string)` | Advisory warnings: RAM out of range, work_mem < 4MB, unrecognised override keys. |

---

## Correctness Verification

Verify pgtune math in `terraform console` against these known-correct outputs.

Auto connections (`pg_connection_num = 0`):

| RAM | CPUs | storage | shared_buffers | max_connections | work_mem |
|---|---|---|---|---|---|
| 0.5GB | 2 | ssd | 128MB | 32 | 4MB |
| 1GB | 2 | ssd | 256MB | 64 | 4MB |
| 2GB | 2 | ssd | 512MB | 128 | 4MB |
| 4GB | 2 | ssd | 1024MB | 200 | 5MB |
| 4GB | 4 | ssd | 1024MB | 200 | 5MB |
| 8GB | 4 | ssd | 2048MB | 200 | 10MB |
| 16GB | 8 | hdd | 4096MB | 200 | 10MB |
| 32GB | 16 | ssd | 8192MB | 200 | 10MB |

Explicit connections:

| RAM | CPUs | connections | storage | shared_buffers | work_mem |
|---|---|---|---|---|---|
| 4GB | 2 | 50 | ssd | 1024MB | 20MB |
| 0.5GB | 2 | 300 | ssd | 128MB | 4MB |

The second explicit row exercises the 4MB floor (formula yields 436kB; floor applied; triggers work_mem warning).
