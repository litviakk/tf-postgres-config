# Module Spec: `modules/postgres`

Version: 7.0
Terraform/OpenTofu: >= 1.6
Required providers: `hashicorp/null` >= 3.0
Target OS: Linux (any distro with `pg_ctl` and `psql` in PATH)
Target PostgreSQL: 16, 17, 18

---

## Responsibility

Compute optimal PostgreSQL performance parameters from hardware facts (RAM, CPU, storage) and deliver them to a running Linux instance via SSH.

1. Calculate parameters using the pgtune algorithm (web workload profile, ported from [le0pard/pgtune](https://github.com/le0pard/pgtune))
2. Write computed values to `conf.d/01-pgtune.conf`
3. Write caller-supplied overrides to `conf.d/02-overrides.conf`
4. Run pre-flight checks
5. Apply with `pg_ctl reload`; restart only when changed parameters require it
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
| `pg_version` | number | required | 16 \| 17 \| 18 | Controls `pg_ctl` version arg and conf.d path |
| `pg_total_memory_gb` | number | required | > 0, fractional OK | Primary sizing input. Warning outside 0.25–100GB range |
| `pg_cpu_num` | number | 2 | positive integer ≥ 1 | When 1, all parallel params omitted entirely |
| `pg_connection_num` | number | 0 | non-negative integer | 0 = auto; explicit value bypasses RAM-based limiting; warning if work_mem < 4MB results |
| `pg_hd_type` | string | `"ssd"` | hdd \| ssd \| san | Controls `random_page_cost` and `effective_io_concurrency` |
| `pg_overrides` | map(string) | `{}` | keys = managed param names; values = valid postgresql.conf strings | Written to `02-overrides.conf`; unrecognised keys ignored with warning |
| `ssh_host` | string | required | — | IP or hostname of the target |
| `ssh_user` | string | `"ubuntu"` | — | Must have passwordless sudo for file ops and `pg_ctl` |
| `ssh_use_agent` | bool | `false` | — | Use local SSH agent for auth; recommended for production. When `true`, `ssh_private_key` is ignored |
| `ssh_private_key` | string | `""` | sensitive | Key file contents (not a path); use `file()` in caller. Required when `ssh_use_agent = false`. Stored in Terraform state (connection block values are persisted); use an encrypted remote state backend. Never place in a resource trigger |
| `ssh_port` | number | 22 | integer 1–65535 | — |
| `conf_d_dir` | string | `""` | absolute path or empty | When empty, the preflight script reads the `include_dir` value from `postgresql.conf` on the target and uses that path. When set, skips discovery and uses the given path directly. `config_file_paths` output reflects the resolved path after apply |
| `pg_user` | string | `"postgres"` | — | OS user owner applied to both conf files after delivery |
| `pg_group` | string | `"postgres"` | — | OS group owner applied to both conf files after delivery |
| `pg_force_restart` | bool | `false` | — | Always restart after config delivery, regardless of changed params |
| `pg_skip_restart` | bool | `false` | — | Never restart, even when restart-required params changed |

Mutual exclusion of `pg_force_restart` and `pg_skip_restart` is enforced via a `precondition` on the `pg_config` resource (not a variable `validation` block, since each block can only reference its own variable):

```hcl
lifecycle {
  precondition {
    condition     = !(var.pg_force_restart && var.pg_skip_restart)
    error_message = "pg_force_restart and pg_skip_restart cannot both be true."
  }
}
```

### Warnings

Terraform/OpenTofu 1.6+ `check` blocks emit non-fatal warnings that do not block apply. Use them for the following conditions:

| Condition | check block name |
|---|---|
| `pg_total_memory_gb` outside 0.25–100 GB | `warn_memory_range` |
| `pg_connection_num > 0` results in `work_mem < 4MB` | `warn_low_work_mem` |
| `pg_overrides` contains keys not in the managed parameter list | `warn_unrecognized_override_keys` |

Variable `validation` blocks (which are always fatal errors) are used only for hard constraints: invalid types, out-of-range integers, unsupported enum values.

---

## `locals.tf`

All intermediate memory values are in **MB**. `pgtune` holds calculated values; `resolved` is the effective map after overrides.

### Parameter formulas

| Parameter | Formula | Notes |
|---|---|---|
| `_parallel_enabled` | `pg_cpu_num >= 2` | — |
| `_wpg_capped` | `min(ceil(pg_cpu_num / 2), 4)` | Cap of 4 for diminishing returns / hyperthreading |
| `_wm_parallel_factor` | `_wpg_capped` if parallel enabled, else `1` | — |
| `shared_buffers` | `floor(total_memory_mb / 4)` | ¼ RAM |
| `effective_cache_size` | `floor(total_memory_mb × 0.75)` | ¾ RAM |
| `maintenance_work_mem` | `min(floor(total_memory_mb / 16), 2048)` | — |
| `max_connections` | `pg_connection_num > 0 ? pg_connection_num : min(200, floor((total_mb − shared_buffers_mb) / (3 × parallel_factor × 4)))` | Auto formula guarantees work_mem ≥ 4MB |
| `work_mem` | `max(4, floor((total_mb − shared_buffers_mb) / (max_connections × 3) / parallel_factor))` | ×3 denominator for multi-node query plans |
| `wal_buffers` | `pg_total_memory_gb > 16 ? 64 : pg_total_memory_gb >= 4 ? 32 : 16` | Stepped: 16/32/64MB at 4GB and 16GB RAM thresholds |
| `min_wal_size` | `1024` (fixed) | — |
| `max_wal_size` | `4096` (fixed) | — |
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

`restart_params_snapshot` is a local that extracts the restart-required subset of `resolved` (i.e. `{for k, v in local.resolved : k => v if contains(local.restart_required_params, k)}`). It is JSON-encoded and stored as a trigger on `pg_config` so that `terraform plan` shows a diff when any restart-required param changes. The authoritative restart decision at apply time is made by querying `pg_settings WHERE pending_restart = true`.

---

## `templates/preflight.sh.tftpl`

Runs before config delivery. Receives: `pg_version`, `conf_d_dir` (empty string when path should be auto-discovered), `pg_user`, `pg_group`, managed param names.

**Checks (exit non-zero on failure):**
- `pg_ctl` and `psql` binaries are present
- PostgreSQL is running and accepting local connections (verified implicitly by the `SHOW data_directory` query)
- `conf.d` directory exists at the configured path and is writable by the SSH user (or sudo is available)
- Files to be written (`01-pgtune.conf`, `02-overrides.conf`) will be created as `<pg_user>:<pg_group>` with mode `640`; preflight verifies that `chown`/`chmod` will succeed (i.e., the SSH user has passwordless sudo)
- `postgresql.conf` contains an active `include_dir` directive — without this, the module's conf files are silently ignored by PostgreSQL. When `conf_d_dir` is empty, the value of `include_dir` is extracted here and used as the working `conf.d` path for the rest of the script and the delivery step. When `conf_d_dir` is explicitly set, verify that `include_dir` in `postgresql.conf` matches it and exit non-zero if they differ
- Query the data directory via `sudo -u <pg_user> psql -tAc "SHOW data_directory;"` and store it for use in subsequent `pg_ctl` calls. Exit non-zero if the query fails

**Informational (non-blocking, emit to stdout):**
- If `postgresql.conf` contains active (non-commented) managed parameters, emit a notice. These settings are overridden by `conf.d/` because `include_dir` is processed after inline assignments in a standard Debian/Ubuntu `postgresql.conf`. A default Debian/Ubuntu install is fully supported; this notice is informational only
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
wal_buffers                  = 32MB
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

Triggers: `ssh_host`, `ssh_port`, `ssh_user`, `pg_version`, `conf_d_dir`, `pg_user`, `pg_group`. Runs pre-flight script via SSH; does not re-run on config-only changes.

### `pg_config` — config delivery and apply

Triggers: `config_hash`, `restart_params_snapshot`, `ssh_host`. Depends on `pg_preflight`. Receives: `pg_user`, `pg_group`, `pg_force_restart`, `pg_skip_restart`, `conf_d_dir`, `data_dir` (discovered by preflight).

**Delivery sequence:**

1. Back up existing conf files (if present) to `/tmp/01-pgtune.conf.bak` and `/tmp/02-overrides.conf.bak`
2. Write new `01-pgtune.conf` and `02-overrides.conf`
3. Set ownership `<pg_user>:<pg_group>` and mode `640` on both files
4. Run `sudo -u <pg_user> pg_ctl reload -D $data_dir` — validates config syntax before any restart
5. Query `sudo -u <pg_user> psql -tAc "SELECT name FROM pg_settings WHERE pending_restart = true;"` — PostgreSQL's authoritative list of parameters that took effect in config but require a restart to activate
6. If the query returns any rows (or `pg_force_restart = true`) and `pg_skip_restart = false`: run `sudo -u <pg_user> pg_ctl restart -D $data_dir`
7. On any failure in steps 3–6: restore backups, re-run reload to return to last known-good state, then exit non-zero

**Rollback:** Terraform has no native rollback for `null_resource` provisioners. Rollback is handled inside the provisioner script (step 7 above). If the provisioner exits non-zero, Terraform marks the resource as tainted; the next `apply` retries from scratch. The old config is restored before exit so PostgreSQL remains operational.

### Execution model

| What changed | preflight runs? | config deploys? | reload? | restart? |
|---|---|---|---|---|
| First apply | yes | yes | yes | yes |
| Host changes | yes | yes | yes | yes |
| pgtune input changes (RAM, CPU, storage) | no | yes | yes | if restart param changed |
| Only `pg_overrides` changes | no | yes | yes | if restart param changed |
| Override changes `work_mem` | no | yes | yes | no |
| Override changes `shared_buffers` | no | yes | yes | yes |
| `pg_version` changes | yes | yes | yes | yes |
| `ssh_user`, `pg_user`, `pg_group`, or `conf_d_dir` changes | yes | yes | yes | if restart param changed |
| Nothing changes | no | no | no | no |

---

## `outputs.tf`

| Output | Type | Description |
|---|---|---|
| `resolved_config` | `map(string)` | Effective parameter map after pgtune + overrides merge. |
| `pgtune_calculated` | `map(string)` | Raw pgtune values before override merge (contents of `01-pgtune.conf`). |
| `effective_overrides` | `map(object)` | Per-key status of `pg_overrides`: `pgtune`, `override`, `active` values. |
| `config_file_paths` | `object` | Absolute paths of both conf files on the host. |

`resolved_config`, `pgtune_calculated`, and `effective_overrides` are derived entirely from `locals` and are fully known at plan time. Plan-time visibility of restart-required param changes is provided by the `restart_params_snapshot` trigger diff shown in `terraform plan` output. The rendered file content is not shown during plan (template rendering happens inside the provisioner at apply time).

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
| 8GB | 4 | ssd | 2048MB | 200 | 5MB |
| 32GB | 16 | ssd | 8192MB | 200 | 10MB |

---

## Testing

Three layers, each with a distinct scope and infrastructure requirement.

### Layer 1 — Formula unit tests (no infrastructure)

Use native `terraform test` (supported from TF/OpenTofu 1.6). Tests live in `modules/postgres/tests/` and exercise `locals.tf` only — no SSH, no provisioners.

Each test case sets input variables and asserts output values match the Correctness Verification table. Cover:

- All rows in the auto-connections and explicit-connections tables
- `wal_buffers` stepped values: 16MB (< 4GB RAM), 32MB (4–16GB), 64MB (> 16GB)
- `pg_cpu_num = 1`: all parallel params absent from `pgtune_calculated`
- `pg_overrides` merge: override key appears in `resolved_config`, `pgtune_calculated` retains original
- `params_needing_restart`: verify correct keys flagged for restart-required vs reload-safe param changes
- `check` block warnings fire correctly (memory out of range, low work_mem, unrecognized override key)

### Layer 2 — Preflight script tests (Docker, no Terraform)

Run `preflight.sh` directly against a Dockerised PostgreSQL instance. Use `bats` (Bash Automated Testing System) or a plain shell test runner. No Terraform state involved.

Test scenarios:

| Scenario | Expected outcome |
|---|---|
| Healthy cluster, correct `include_dir` | Exit 0 |
| `pg_ctl` or `psql` binary absent | Exit non-zero |
| Cluster in `stopped` state | Exit non-zero |
| `conf.d` directory missing | Exit non-zero |
| `postgresql.conf` has no `include_dir` | Exit non-zero |
| `conf_d_dir` set but mismatches `include_dir` | Exit non-zero |
| SSH user lacks sudo | Exit non-zero |
| Active managed params in `postgresql.conf` | Exit 0, warning emitted |
| Managed params in `postgresql.auto.conf` | Exit 0, notice emitted |

### Layer 3 — Integration tests (Docker + Terraform)

Full module apply against a Dockerised PostgreSQL instance. Use Terratest (Go) or `terraform test` with a real SSH target.

Each test applies the module and then SSHes in to assert the runtime state directly:

- `01-pgtune.conf` and `02-overrides.conf` exist at the resolved `conf_d_dir` path
- File ownership is `<pg_user>:<pg_group>` and mode is `640`
- `SHOW <param>` via `psql` matches `resolved_config` for every managed parameter
- A second apply with unchanged inputs: no files rewritten, no reload, no restart (`null_resource` does not re-trigger)
- Changing a reload-safe param: reload occurs, no restart
- Changing `shared_buffers`: restart occurs
- `pg_force_restart = true` with only a reload-safe param change: restart still occurs
- `pg_skip_restart = true` with `shared_buffers` changed: reload occurs, no restart
- Rollback: corrupt `02-overrides.conf` mid-apply; verify PostgreSQL returns to last known-good config and apply exits non-zero
