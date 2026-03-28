# Module Spec: `modules/postgres`

Version: 6.0
Terraform/OpenTofu: >= 1.5
Required providers: `hashicorp/null` >= 3.0
Target OS: Linux (Debian/Ubuntu with `pg_ctlcluster`)
Target PostgreSQL: 16, 17, 18

---

## Managed Parameters

This module computes and manages the following PostgreSQL parameters.
All other `postgresql.conf` parameters are untouched.

| Parameter | Category | Restart | What it controls |
|---|---|---|---|
| `max_connections` | Connections | yes | Maximum concurrent client connections |
| `shared_buffers` | Memory | yes | PostgreSQL's dedicated shared memory cache |
| `effective_cache_size` | Memory | no | Planner estimate of total cache available (shared buffers + OS page cache) |
| `maintenance_work_mem` | Memory | no | Memory for VACUUM, CREATE INDEX, ALTER TABLE, and other maintenance |
| `work_mem` | Memory | no | Per-operation memory for sorts, hash joins, and similar operations |
| `huge_pages` | Memory | yes | Use OS huge pages to reduce TLB pressure on shared_buffers |
| `wal_buffers` | WAL | yes | Shared memory for WAL records before flush to disk |
| `min_wal_size` | WAL | no | Minimum WAL retention on disk |
| `max_wal_size` | WAL | no | WAL size threshold that triggers a checkpoint |
| `checkpoint_completion_target` | WAL | no | Fraction of checkpoint interval over which to spread I/O |
| `default_statistics_target` | Planner | no | Number of rows sampled when computing planner statistics |
| `random_page_cost` | Planner | no | Estimated cost of a non-sequential page fetch (relative to seq_page_cost) |
| `effective_io_concurrency` | Planner | no | Expected number of concurrent disk I/O operations the OS can handle |
| `max_worker_processes` | Parallelism | yes | Total background worker process slots |
| `max_parallel_workers_per_gather` | Parallelism | no | Maximum parallel workers per query Gather node |
| `max_parallel_workers` | Parallelism | no | Total worker processes available for parallel queries |
| `max_parallel_maintenance_workers` | Parallelism | no | Parallel workers for maintenance operations (e.g. CREATE INDEX) |

**Restart** = parameter has `postmaster` context and requires a PostgreSQL
restart to take effect. Parameters marked "no" are applied immediately on
reload (or even per-session).

The four parallelism parameters are **omitted entirely** when `pg_cpu_num = 1`.

---

## What This Module Does

One responsibility: **compute optimal PostgreSQL performance parameters and
deliver them to a running Linux instance.**

Given hardware facts (RAM, CPU, storage type), the module:

1. Calculates the parameters listed above using the pgtune algorithm
   (ported from [le0pard/pgtune](https://github.com/le0pard/pgtune), web
   workload profile)
2. Writes computed values to `conf.d/01-pgtune.conf`
3. Writes caller-supplied overrides to `conf.d/02-overrides.conf`
4. Runs pre-flight checks to verify the PostgreSQL environment
5. Applies with `pg_ctlcluster reload`, followed by `restart` only when
   changed parameters require shared-memory reallocation
6. Exposes the full resolved parameter map so callers can detect
   restart-requiring changes at **plan time** on subsequent applies

## What This Module Does Not Do

The following are explicitly out of scope:

- Creating the host or container (`incus_instance`, `aws_instance`, etc.)
- Installing PostgreSQL (Packer base image concern)
- `pg_hba.conf` — authentication rules, separate lifecycle from tuning
- Base `postgresql.conf` settings: `listen_addresses`, `ssl`, `wal_level`,
  `max_wal_senders`, `shared_preload_libraries`, logging parameters
- Role, database, schema management (`cyrilgdn/postgresql` provider)
- Backup configuration (pgBackRest module)
- HA / replication (Patroni module)
- SSH bastion/jump host support — the module assumes the Terraform runner
  can reach `ssh_host` directly. If bastion support is needed in the future,
  the `null_resource` connection block supports `bastion_host`,
  `bastion_user`, and `bastion_private_key` natively

This module owns exactly two files on the target:

```
/etc/postgresql/<pg_version>/<pg_cluster_name>/conf.d/01-pgtune.conf
/etc/postgresql/<pg_version>/<pg_cluster_name>/conf.d/02-overrides.conf
```

---

## Configuration Layering

PostgreSQL loads configuration in layers. Later values override earlier ones.
This module uses the `conf.d` include mechanism to manage performance
parameters without touching any other config file.

```
Layer 1: postgresql.conf               ← base config (image / Ansible / other module)
Layer 2: conf.d/01-pgtune.conf         ← this module: algorithm-computed values
Layer 3: conf.d/02-overrides.conf      ← this module: caller-supplied pg_overrides
Layer 4: conf.d/03-*.conf …            ← other drop-in config (if any)
Layer 5: postgresql.auto.conf          ← ALTER SYSTEM (runtime, not managed)
```

**What this means in practice:**

- `01-pgtune.conf` contains the raw algorithm output. A DBA on the host
  can read this file to see exactly what the formulas computed.
- `02-overrides.conf` contains only the parameters from `pg_overrides`.
  It loads after pgtune, so override values win via PostgreSQL's own config
  layering. A DBA can see at a glance which values were manually chosen
  vs. computed.
- Parameters this module **does not set** retain their values from
  `postgresql.conf` untouched.
- `ALTER SYSTEM` writes to `postgresql.auto.conf`, which loads last and
  overrides everything including `conf.d/`. The pre-flight check prints a
  notice if `postgresql.auto.conf` sets any parameters that this module
  also manages.

**Decision framework for callers:**

| Situation | Where to set it |
|---|---|
| Performance parameter, hardware-derived | Let pgtune calculate it (default) |
| Performance parameter, measured override | `pg_overrides` → written to `02-overrides.conf` |
| Non-performance parameter (ssl, logging, wal_level) | `postgresql.conf` via base image or another module |
| One-off runtime adjustment | `ALTER SYSTEM` or `SET` |

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

### Rules applying to all variables

- All variables set `nullable = false` — no variable accepts `null`
- Required variables (no `default`) must be explicitly set by the caller
- Integer-constrained variables validate `var.x == floor(var.x)`

---

### PostgreSQL version

```hcl
variable "pg_version" {
  type        = number
  nullable    = false
  description = <<-EOT
    PostgreSQL major version. Controls:
    - The pg_ctlcluster command version argument
    - The derived conf.d path when conf_d_dir is not overridden
  EOT

  validation {
    condition     = contains([16, 17, 18], var.pg_version)
    error_message = "pg_version must be one of: 16, 17, 18."
  }
}
```

---

### pgtune inputs

```hcl
variable "pg_total_memory_gb" {
  type        = number
  nullable    = false
  description = <<-EOT
    Total RAM available to the PostgreSQL host, in GB. Accepts fractional
    values (e.g. 0.5 for 512MB, 4.0 for 4GB). This is the primary sizing
    input — all memory parameters and auto-calculated max_connections
    derive from it.

    The pgtune algorithm is not designed for hosts below 256MB (0.25) or
    above 100GB. A warning output is emitted outside those bounds but the
    module still computes values.
  EOT

  validation {
    condition     = var.pg_total_memory_gb > 0
    error_message = "pg_total_memory_gb must be a positive number."
  }
}

variable "pg_cpu_num" {
  type        = number
  nullable    = false
  default     = 2
  description = <<-EOT
    Number of CPU threads visible to PostgreSQL
    (threads-per-core × cores-per-socket × sockets).

    Parallel worker settings are derived as ceil(cpu_num / 2), capped at 4.
    The cap conservatively accounts for hyperthreading — physical cores
    drive useful parallelism, not logical thread count. Over-counting
    logical CPUs is safe due to the cap.

    When pg_cpu_num = 1, all parallel worker parameters are omitted from
    the rendered config entirely.
  EOT

  validation {
    condition     = var.pg_cpu_num >= 1 && var.pg_cpu_num == floor(var.pg_cpu_num)
    error_message = "pg_cpu_num must be a positive integer."
  }
}

variable "pg_connection_num" {
  type        = number
  nullable    = false
  default     = 0
  description = <<-EOT
    Maximum number of client connections. Must be a non-negative integer.

    When 0 (default), the module calculates connections automatically:

      auto_connections = min(200, max_safe_connections)

    where max_safe_connections is derived from available memory to
    guarantee work_mem >= 4MB (PostgreSQL's default). The cap of 200 is
    the pgtune recommendation for general web/application workloads.

    On small hosts the formula limits connections below 200 to preserve
    adequate work_mem. On hosts with >= ~3GB RAM (varies with CPU count),
    the 200 cap takes effect and work_mem grows above 4MB.

    When set explicitly (> 0), the module uses the provided value without
    RAM-based limiting. A warning is emitted if the resulting work_mem
    falls below 4MB.
  EOT

  validation {
    condition     = var.pg_connection_num >= 0 && var.pg_connection_num == floor(var.pg_connection_num)
    error_message = "pg_connection_num must be a non-negative integer (0 = auto)."
  }
}

variable "pg_hd_type" {
  type        = string
  nullable    = false
  default     = "ssd"
  description = <<-EOT
    Storage type. Controls random_page_cost and effective_io_concurrency.

      hdd — Spinning disk.
              random_page_cost = 4, effective_io_concurrency = 2
      ssd — SATA or NVMe SSD, local flash.
              random_page_cost = 1.1, effective_io_concurrency = 200
      san — Network-attached block storage, including cloud block storage
            (AWS EBS, Azure Premium SSD, GCP PD-SSD).
              random_page_cost = 1.1, effective_io_concurrency = 300
            Note: cloud block storage has rate-limited rather than
            latency-limited I/O. The random_page_cost of 1.1 is optimistic
            for some configurations — use pg_overrides to tune if needed.

    When in doubt between ssd and san for cloud-backed storage, use san.
  EOT

  validation {
    condition     = contains(["hdd", "ssd", "san"], var.pg_hd_type)
    error_message = "pg_hd_type must be one of: hdd, ssd, san."
  }
}
```

---

### Override and state tracking

```hcl
variable "pg_overrides" {
  type        = map(string)
  nullable    = false
  default     = {}
  description = <<-EOT
    Per-parameter overrides written to conf.d/02-overrides.conf.
    Any key present here takes priority over the pgtune-calculated value
    for the same parameter in conf.d/01-pgtune.conf.

    Keys must be exact postgresql.conf parameter names from the managed
    parameters list. Keys that do not match a managed parameter are
    ignored and produce a warning.

    Values must be valid postgresql.conf strings:
      memory:  "2GB", "512MB", "64kB"
      numeric: "300", "1.1", "0.9"

    When pg_cpu_num = 1, parallel parameters are omitted from
    01-pgtune.conf. Overrides for omitted parameters are also ignored —
    an override cannot introduce a parameter the algorithm has excluded.

    Example:
      pg_overrides = {
        work_mem       = "32MB"
        shared_buffers = "3GB"
      }
  EOT
}

variable "current_pg_config" {
  type        = map(string)
  nullable    = false
  default     = {}
  description = <<-EOT
    The resolved parameter map from the last successful apply. Used to
    detect which parameters have changed and whether those changes require
    a PostgreSQL restart.

    On first apply: leave as the default empty map. All restart-requiring
    parameters are treated as new and a restart fires — correct for initial
    provisioning.

    On subsequent applies: pass output.resolved_config from the previous
    apply. The module diffs new resolved values against this map at plan
    time, producing output.restart_required when restart-requiring params
    have changed.

    Never manually construct this map. Always source it from
    output.resolved_config. Manually constructed values cause spurious
    or missed restarts.

    Wiring pattern in the calling module:

      variable "pg_applied_config" {
        type    = map(string)
        default = {}
      }

      module "postgres" {
        source            = "../../modules/postgres"
        current_pg_config = var.pg_applied_config
        # ... other vars
      }

      output "pg_applied_config" {
        value = module.postgres.resolved_config
      }
  EOT
}
```

---

### SSH delivery

```hcl
variable "ssh_host" {
  type        = string
  nullable    = false
  description = "IP address or hostname of the PostgreSQL host."
}

variable "ssh_user" {
  type        = string
  nullable    = false
  default     = "ubuntu"
  description = <<-EOT
    SSH user on the PostgreSQL host. Must have passwordless sudo for:
    1. File operations in the conf.d directory (cp, chown, chmod)
    2. Running pg_ctlcluster as the postgres unix user

    Typical sudoers entries on the base image:
      <ssh_user> ALL=(ALL) NOPASSWD: /usr/bin/cp, /bin/chown, /bin/chmod
      <ssh_user> ALL=(postgres) NOPASSWD: /usr/bin/pg_ctlcluster
  EOT
}

variable "ssh_private_key" {
  type        = string
  nullable    = false
  sensitive   = true
  description = <<-EOT
    Contents of the SSH private key (not a filesystem path).
    Use file() in the caller when reading from disk:
      ssh_private_key = file("~/.ssh/id_ed25519")
  EOT
}

variable "ssh_port" {
  type     = number
  nullable = false
  default  = 22

  validation {
    condition     = var.ssh_port > 0 && var.ssh_port <= 65535 && var.ssh_port == floor(var.ssh_port)
    error_message = "ssh_port must be a valid integer port number (1-65535)."
  }
}

variable "pg_cluster_name" {
  type        = string
  nullable    = false
  default     = "main"
  description = <<-EOT
    PostgreSQL cluster name for pg_ctlcluster. On standard Debian/Ubuntu
    installations this is always 'main'.
  EOT
}

variable "conf_d_dir" {
  type        = string
  nullable    = false
  default     = ""
  description = <<-EOT
    Absolute path to the conf.d directory on the host.
    When empty (default), derived as:
      /etc/postgresql/<pg_version>/<pg_cluster_name>/conf.d
    Override only for non-standard installation layouts.
  EOT
}
```

---

## `locals.tf`

### Conventions

- All intermediate memory values are in **kibibytes (KiB)** unless the name
  ends in `_mb` or `_gb`
- Names prefixed with `_` are internal intermediates not referenced outside
  `locals.tf`
- `local.pgtune` holds calculated values — used for `01-pgtune.conf` and as
  the base for override resolution
- `local.resolved` is the authoritative map of effective values — used for
  restart detection and outputs

---

### Section A — Constants and derived paths

```hcl
locals {
  # Byte counts for unit conversion. Used as multipliers/divisors to convert
  # between units. Example: total_memory_kb = memory_gb * _gb / _kb
  _kb = 1024          # bytes in 1 KiB
  _mb = 1048576       # bytes in 1 MiB
  _gb = 1073741824    # bytes in 1 GiB

  conf_d_dir           = var.conf_d_dir != "" ? var.conf_d_dir : "/etc/postgresql/${var.pg_version}/${var.pg_cluster_name}/conf.d"
  pgtune_file_path     = "${local.conf_d_dir}/01-pgtune.conf"
  overrides_file_path  = "${local.conf_d_dir}/02-overrides.conf"

  # Total memory in KiB. Fractional GB is supported — no integer truncation here.
  _total_memory_kb = floor(var.pg_total_memory_gb * local._gb / local._kb)
}
```

---

### Section B — Parameter calculations

#### Parallel worker intermediates (used by `max_connections` and `work_mem`)

Calculated first because `max_connections` depends on `parallel_factor`.

```hcl
  _parallel_enabled    = var.pg_cpu_num >= 2
  _half_cpu            = ceil(var.pg_cpu_num / 2)
  _wpg_capped          = min(local._half_cpu, 4)
  _wm_parallel_factor  = local._parallel_enabled ? local._wpg_capped : 1
```

---

#### `max_connections`

```
pgtune_cap           = 200
max_safe_connections = floor((total_memory_kb - shared_buffers_kb) / (3 × parallel_factor × 4096))
auto_connections     = min(pgtune_cap, max_safe_connections)
max_connections      = pg_connection_num > 0 ? pg_connection_num : auto_connections
```

The `max_safe_connections` formula is derived by inverting the `work_mem`
formula and solving for the number of connections that yield exactly 4MB
(PostgreSQL's default `work_mem`):

```
work_mem = floor((total_kb - shared_buffers_kb) / (connections × 3) / parallel_factor)

Setting work_mem = 4096 kB and solving for connections:

connections = floor((total_kb - shared_buffers_kb) / (3 × parallel_factor × 4096))
```

This ensures auto-calculated connections never push `work_mem` below
PostgreSQL's own default. On small hosts, connections scale down with RAM.
On hosts with enough RAM (varies with CPU count), the pgtune cap of 200
takes effect and `work_mem` grows above 4MB.

When `pg_connection_num > 0`, the caller's explicit value is used without
RAM-based limiting — the `work_mem` warning catches any resulting issues.

```hcl
  _pgtune_max_connections = 200
  _shared_buffers_kb      = floor(local._total_memory_kb / 4)

  _max_safe_connections = floor(
    (local._total_memory_kb - local._shared_buffers_kb)
    / (3 * local._wm_parallel_factor * 4096)
  )
  _max_connections = (
    var.pg_connection_num > 0
    ? var.pg_connection_num
    : min(local._pgtune_max_connections, local._max_safe_connections)
  )
```

---

#### `shared_buffers`

```
shared_buffers = floor(total_memory_kb / 4)
```

One quarter of total RAM. Standard pgtune recommendation.

```hcl
  # _shared_buffers_kb is defined above (needed by max_connections).
```

---

#### `effective_cache_size`

```
effective_cache_size = floor(total_memory_kb × 0.75)
```

Three quarters of total RAM. Tells the planner how much data it can expect
to find in the OS page cache + shared buffers combined.

```hcl
  _effective_cache_size_kb = floor(local._total_memory_kb * 0.75)
```

---

#### `maintenance_work_mem`

```
raw                  = floor(total_memory_kb / 16)
maintenance_work_mem = min(raw, 2GB)
```

```hcl
  _mwm_raw_kb              = floor(local._total_memory_kb / 16)
  _mwm_cap_kb              = floor(2 * local._gb / local._kb)
  _maintenance_work_mem_kb = min(local._mwm_raw_kb, local._mwm_cap_kb)
```

---

#### `wal_buffers`

```
raw = floor(shared_buffers × 0.03)
if 14MB ≤ raw < 16MB → round up to 16MB
wal_buffers = max(32kB, min(raw, 16MB))
```

The 3% formula is PostgreSQL's own auto-tuning heuristic (used when
`wal_buffers = -1`). It frequently produces a value in the 14-15MB range on
moderately sized hosts (e.g. 3% of 512MB `shared_buffers` = 15.7MB).

The round-up from 14-15MB to 16MB and the 16MB cap are both rooted in
diminishing returns: `wal_buffers` is a ring buffer of WAL pages in shared
memory, flushed on every commit (`synchronous_commit = on`, the default) and
at least every `wal_writer_delay` (200ms). Under normal operation the buffer
rarely accumulates more than a few MB of unflushed data. Beyond 16MB,
additional buffer space goes effectively unused.

The minimum of 32kB prevents trivially small buffers on very low-memory hosts.

```hcl
  _wal_buf_3pct_kb = floor(local._shared_buffers_kb * 3 / 100)
  _wal_buf_max_kb  = floor(16 * local._mb / local._kb)
  _wal_buf_near_kb = floor(14 * local._mb / local._kb)
  _wal_buffers_kb  = max(32,
    local._wal_buf_3pct_kb >= local._wal_buf_near_kb && local._wal_buf_3pct_kb < local._wal_buf_max_kb
    ? local._wal_buf_max_kb
    : min(local._wal_buf_3pct_kb, local._wal_buf_max_kb)
  )
```

---

#### `checkpoint_completion_target`

```
value = "0.9"
```

Fixed at 0.9. PostgreSQL 17 changed the default from 0.5 to 0.9, reflecting
the consensus that 0.9 is better for virtually all workloads — it spreads
checkpoint I/O more evenly and prevents write spikes. Setting 0.9 on PG 16
provides the same benefit ahead of the default change.

```hcl
  _checkpoint_completion_target = "0.9"
```

---

#### `min_wal_size` / `max_wal_size`

Fixed values. Not RAM-derived — reflects typical checkpoint frequency for
general web/application workloads. All supported versions (16-18) use these
parameters.

```
min_wal_size = 1024MB
max_wal_size = 4096MB
```

```hcl
  _min_wal_size_mb = 1024
  _max_wal_size_mb = 4096
```

---

#### `default_statistics_target`

```
value = 100
```

PostgreSQL's default. Appropriate for general workloads. Analytical queries
may benefit from higher values (e.g. 500) via `pg_overrides` or per-column
`ALTER TABLE ... SET STATISTICS`.

```hcl
  _default_statistics_target = 100
```

---

#### `random_page_cost`

```
value = { hdd:"4", ssd:"1.1", san:"1.1" }[hd_type]
```

```hcl
  _random_page_cost = { hdd = "4", ssd = "1.1", san = "1.1" }[var.pg_hd_type]
```

---

#### `effective_io_concurrency`

Always emitted. Linux is the only supported OS.

```
value = { hdd:2, ssd:200, san:300 }[hd_type]
```

```hcl
  _effective_io_concurrency = { hdd = 2, ssd = 200, san = 300 }[var.pg_hd_type]
```

---

#### `huge_pages`

```
value = "try"
```

Always set to `try`. PostgreSQL attempts to use OS huge pages and falls back
to standard pages if the kernel is not configured for them. No downside —
when huge pages are available they reduce TLB pressure for `shared_buffers`.

```hcl
  _huge_pages = "try"
```

---

#### Parallel worker settings

All four parameters apply to all supported versions (16-18).
All four are omitted (empty string) when `pg_cpu_num = 1`.

```
max_worker_processes             = pg_cpu_num                   (or omitted)
max_parallel_workers_per_gather  = min(ceil(pg_cpu_num / 2), 4) (or omitted)
max_parallel_workers             = pg_cpu_num                   (or omitted)
max_parallel_maintenance_workers = min(ceil(pg_cpu_num / 2), 4) (or omitted)
```

The cap of 4 reflects diminishing returns beyond 4 parallel workers for
most query shapes, and conservatively handles hyperthreaded CPUs.

```hcl
  _max_worker_processes             = local._parallel_enabled ? tostring(var.pg_cpu_num) : ""
  _max_parallel_workers_per_gather  = local._parallel_enabled ? tostring(local._wpg_capped) : ""
  _max_parallel_workers             = local._parallel_enabled ? tostring(var.pg_cpu_num) : ""
  _max_parallel_maintenance_workers = local._parallel_enabled ? tostring(min(local._half_cpu, 4)) : ""
```

---

#### `work_mem`

```
base      = floor((total_memory_kb - shared_buffers_kb) / (max_connections × 3) / parallel_factor)
work_mem  = max(4MB, base)
```

The denominator of `max_connections × 3` reflects that a single connection
can allocate `work_mem` multiple times concurrently (e.g. a query plan with
multiple sort and hash join nodes). This leaves headroom against OOM kills.

The floor of 4MB is PostgreSQL's compiled default. Below 4MB, most sort and
hash operations spill to disk. When `pg_connection_num = 0` (auto), the
`max_connections` formula already guarantees `work_mem >= 4MB`, so the floor
only activates when `pg_connection_num` is set explicitly to a high value.

```hcl
  _wm_base_kb       = floor(
    (local._total_memory_kb - local._shared_buffers_kb)
    / (local._max_connections * 3)
    / local._wm_parallel_factor
  )
  _wm_calculated_kb = local._wm_base_kb
  _work_mem_kb      = max(4096, local._wm_calculated_kb)
```

---

### Section C — pgtune map

Collects all calculated values as postgresql.conf-formatted strings.
Memory values use `MB` suffix. Parameters that do not apply produce empty
strings and will be omitted from the rendered config by the template.

```hcl
  pgtune = {
    max_connections                  = tostring(local._max_connections)
    shared_buffers                   = "${floor(local._shared_buffers_kb / 1024)}MB"
    effective_cache_size             = "${floor(local._effective_cache_size_kb / 1024)}MB"
    maintenance_work_mem             = "${floor(local._maintenance_work_mem_kb / 1024)}MB"
    work_mem                         = "${floor(local._work_mem_kb / 1024)}MB"
    wal_buffers                      = "${floor(local._wal_buffers_kb / 1024)}MB"
    min_wal_size                     = "${local._min_wal_size_mb}MB"
    max_wal_size                     = "${local._max_wal_size_mb}MB"
    checkpoint_completion_target     = local._checkpoint_completion_target
    default_statistics_target        = tostring(local._default_statistics_target)
    random_page_cost                 = local._random_page_cost
    effective_io_concurrency         = tostring(local._effective_io_concurrency)
    huge_pages                       = local._huge_pages
    max_worker_processes             = local._max_worker_processes
    max_parallel_workers_per_gather  = local._max_parallel_workers_per_gather
    max_parallel_workers             = local._max_parallel_workers
    max_parallel_maintenance_workers = local._max_parallel_maintenance_workers
  }
```

---

### Section D — Value resolution and overrides

The resolved map represents the effective value for each parameter — what
PostgreSQL will use after loading both `01-pgtune.conf` and
`02-overrides.conf`. Used for restart detection and outputs.

```hcl
  resolved = {
    for param, pgtune_val in local.pgtune :
    param => (
      pgtune_val == ""
      ? ""
      : coalesce(lookup(var.pg_overrides, param, null), pgtune_val)
    )
  }
```

Active overrides are the subset of `pg_overrides` that will actually be
written to `02-overrides.conf`. An override is active when the parameter
exists in the pgtune map with a non-empty value.

```hcl
  _active_overrides = {
    for param, val in var.pg_overrides :
    param => val
    if lookup(local.pgtune, param, "") != ""
  }

  _unknown_overrides = [
    for param in keys(var.pg_overrides) :
    param
    if !contains(keys(local.pgtune), param)
  ]
```

---

### Section E — Restart detection

#### Parameters requiring restart

These parameters have `postmaster` context in PostgreSQL 16-18: they allocate
shared memory or set process limits at server start and cannot be changed via
`SIGHUP` or at session level. Changing them requires a full restart.

```hcl
  _restart_required_params = toset([
    "shared_buffers",
    "max_connections",
    "wal_buffers",
    "max_worker_processes",
    "huge_pages",
  ])
```

Parameters **not** in this list despite being tuned by this module:

- `max_parallel_workers` — `user` context, changeable per-session
- `max_parallel_maintenance_workers` — `user` context, changeable per-session

These are reload-safe (and even session-safe) across all supported versions.
No restart is triggered when they change.

#### Diff against current state

```hcl
  params_needing_restart = {
    for param in local._restart_required_params :
    param => {
      old = lookup(var.current_pg_config, param, null)
      new = local.resolved[param]
    }
    if (
      local.resolved[param] != ""
      ? lookup(var.current_pg_config, param, null) != local.resolved[param]
      : lookup(var.current_pg_config, param, null) != null
    )
  }
```

The conditional handles two cases:

- **Parameter is active** (`resolved != ""`): restart if old value differs
  from new value. `old = null` means first apply or a newly introduced
  parameter.
- **Parameter is omitted** (`resolved == ""`): restart only if the parameter
  was previously active (`old != null`). This covers the case where
  `pg_cpu_num` changes from >=2 to 1 and `max_worker_processes` is removed
  from the config — PostgreSQL retains the runtime value until restarted.
  When both old and new are absent, no restart fires.

Empty map means no restart-requiring parameters changed — reload only.

---

### Section F — Rendered configs and change hash

```hcl
  rendered_pgtune_config = templatefile(
    "${path.module}/templates/postgresql_tune.conf.tftpl",
    merge(local.pgtune, {
      _pg_version = var.pg_version
      _memory_gb  = var.pg_total_memory_gb
      _cpu_num    = var.pg_cpu_num
      _hd_type    = var.pg_hd_type
    })
  )

  rendered_overrides_config = templatefile(
    "${path.module}/templates/postgresql_overrides.conf.tftpl",
    { overrides = local._active_overrides }
  )

  rendered_preflight = templatefile(
    "${path.module}/templates/preflight.sh.tftpl",
    {
      pg_version     = var.pg_version
      pg_cluster     = var.pg_cluster_name
      conf_d_dir     = local.conf_d_dir
      managed_params = join("|", keys(local.pgtune))
    }
  )

  config_hash = sha256("${local.rendered_pgtune_config}${local.rendered_overrides_config}")
```

The `config_hash` covers both files. A change to either pgtune inputs or
`pg_overrides` triggers the provisioner chain.

---

### Section G — Warnings

Exposed via `output.warnings`. Non-blocking.

```hcl
  warnings = compact([
    var.pg_total_memory_gb < 0.25
      ? "pgtune is not optimised for hosts below 256MB RAM"
      : "",
    var.pg_total_memory_gb > 100
      ? "pgtune is not optimised for hosts above 100GB RAM"
      : "",
    local._wm_calculated_kb < 4096
      ? "calculated work_mem (${local._wm_calculated_kb}kB) is below PostgreSQL's 4MB default — 4MB floor applied but may cause memory pressure under peak load with ${local._max_connections} connections. Reduce pg_connection_num or increase pg_total_memory_gb."
      : "",
    length(local._unknown_overrides) > 0
      ? "pg_overrides contains keys not in the managed parameter list: ${join(", ", local._unknown_overrides)}. These are ignored."
      : "",
  ])
```

---

## `templates/preflight.sh.tftpl`

Pre-flight checks run before writing config files. The script verifies the
PostgreSQL environment is ready and notes any `ALTER SYSTEM` values that
overlap with managed parameters.

```bash
#!/bin/bash
set -e

# Verify pg_ctlcluster is available
command -v pg_ctlcluster >/dev/null 2>&1 || {
  echo "ERROR: pg_ctlcluster not found. Is postgresql-common installed?"
  exit 1
}

# Verify cluster is running
if ! pg_lsclusters -h | grep -qE "^${pg_version}[[:space:]]+${pg_cluster}[[:space:]]+.*online"; then
  echo "ERROR: PostgreSQL cluster ${pg_version}/${pg_cluster} is not running."
  exit 1
fi

# Verify conf.d directory exists
if [ ! -d "${conf_d_dir}" ]; then
  echo "ERROR: conf.d directory not found: ${conf_d_dir}"
  exit 1
fi

# Note any ALTER SYSTEM values for managed parameters
AUTO_CONF="/etc/postgresql/${pg_version}/${pg_cluster}/postgresql.auto.conf"
if [ -f "$AUTO_CONF" ]; then
  FOUND=$(grep -iE "^[[:space:]]*(${managed_params})[[:space:]]*=" "$AUTO_CONF" 2>/dev/null || true)
  if [ -n "$FOUND" ]; then
    echo "Notice: postgresql.auto.conf sets parameters also managed by this module:"
    echo "$FOUND"
    echo "ALTER SYSTEM values take precedence over conf.d/. To clear: ALTER SYSTEM RESET <param>;"
  fi
fi
```

The first three checks exit non-zero and halt the apply. The ALTER SYSTEM
check is informational — it prints a notice and continues.

---

## `templates/postgresql_tune.conf.tftpl`

Contains the algorithm-computed values. Receives `local.pgtune` (plus
metadata keys) as its variable scope.

Parameters with empty-string values are omitted with `%{ if ... ~}`
directives. The `~` trims surrounding whitespace so omitted lines leave no
blank lines in the output.

```
# postgresql.conf — performance tuning (PostgreSQL ${_pg_version})
# Managed by Terraform. Do not edit manually.
# Overwritten on every terraform apply.
# Algorithm: https://github.com/le0pard/pgtune
# Inputs: ${_memory_gb}GB RAM, ${_cpu_num} CPUs, ${_hd_type}

# Connections
max_connections = ${max_connections}

# Memory
shared_buffers           = ${shared_buffers}
effective_cache_size     = ${effective_cache_size}
maintenance_work_mem     = ${maintenance_work_mem}
work_mem                 = ${work_mem}
huge_pages               = ${huge_pages}

# WAL
wal_buffers                  = ${wal_buffers}
min_wal_size                 = ${min_wal_size}
max_wal_size                 = ${max_wal_size}
checkpoint_completion_target = ${checkpoint_completion_target}

# Planner
default_statistics_target = ${default_statistics_target}
random_page_cost          = ${random_page_cost}
effective_io_concurrency  = ${effective_io_concurrency}

# Parallelism
%{ if max_worker_processes != "" ~}
max_worker_processes             = ${max_worker_processes}
max_parallel_workers_per_gather  = ${max_parallel_workers_per_gather}
max_parallel_workers             = ${max_parallel_workers}
max_parallel_maintenance_workers = ${max_parallel_maintenance_workers}
%{ endif ~}
```

---

## `templates/postgresql_overrides.conf.tftpl`

Contains caller-supplied overrides. Loaded after `01-pgtune.conf` — values
here take precedence over computed values via PostgreSQL's own config
layering.

When `pg_overrides` is empty, only the header comment is rendered.

```
# postgresql.conf — manual overrides
# Managed by Terraform via pg_overrides variable.
# Loaded after 01-pgtune.conf — values here take precedence.
# Do not edit manually — overwritten on every terraform apply.
%{ for param, value in overrides ~}
${param} = ${value}
%{ endfor ~}
```

---

## `main.tf`

Two resources with separate triggers provide independent control over
pre-flight checks and config delivery.

### `pg_preflight` — environment validation

Triggers on host, port, PostgreSQL version, or cluster name changes.
Runs on first apply and whenever the target host changes. Does **not**
re-run when only config values change.

```hcl
resource "null_resource" "pg_preflight" {
  triggers = {
    host    = var.ssh_host
    port    = var.ssh_port
    version = var.pg_version
    cluster = var.pg_cluster_name
  }

  connection {
    type        = "ssh"
    host        = var.ssh_host
    port        = var.ssh_port
    user        = var.ssh_user
    private_key = var.ssh_private_key
  }

  provisioner "file" {
    content     = local.rendered_preflight
    destination = "/tmp/pg-preflight.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/pg-preflight.sh && /tmp/pg-preflight.sh",
      "rm -f /tmp/pg-preflight.sh",
    ]
  }
}
```

### `pg_config` — config delivery and apply

Triggers on config content hash or host change. Depends on `pg_preflight`
so environment is validated before first config delivery.

```hcl
resource "null_resource" "pg_config" {
  depends_on = [null_resource.pg_preflight]

  triggers = {
    config_hash = local.config_hash
    host        = var.ssh_host
  }

  connection {
    type        = "ssh"
    host        = var.ssh_host
    port        = var.ssh_port
    user        = var.ssh_user
    private_key = var.ssh_private_key
  }

  provisioner "file" {
    content     = local.rendered_pgtune_config
    destination = "/tmp/01-pgtune.conf"
  }

  provisioner "file" {
    content     = local.rendered_overrides_config
    destination = "/tmp/02-overrides.conf"
  }

  provisioner "remote-exec" {
    inline = concat(
      [
        "sudo cp /tmp/01-pgtune.conf /tmp/02-overrides.conf ${local.conf_d_dir}/",
        "sudo chown postgres:postgres ${local.pgtune_file_path} ${local.overrides_file_path}",
        "sudo chmod 644 ${local.pgtune_file_path} ${local.overrides_file_path}",
        "rm -f /tmp/01-pgtune.conf /tmp/02-overrides.conf",
      ],
      ["sudo -u postgres pg_ctlcluster ${var.pg_version} ${var.pg_cluster_name} reload"],
      length(local.params_needing_restart) > 0
        ? ["sudo -u postgres pg_ctlcluster ${var.pg_version} ${var.pg_cluster_name} restart"]
        : []
    )
  }
}
```

### Execution model

| What changed | preflight runs? | config deploys? | reload? | restart? |
|---|---|---|---|---|
| First apply | yes | yes | yes | yes (all params new) |
| Host changes | yes | yes | yes | yes (new host) |
| pgtune input changes (RAM, CPU, storage) | no | yes | yes | if restart param changed |
| Only `pg_overrides` changes | no | yes | yes | if restart param changed |
| Override changes `work_mem` | no | yes | yes | no (reload-only) |
| Override changes `shared_buffers` | no | yes | yes | yes |
| `pg_version` or `pg_cluster_name` changes | yes | yes | yes | yes (new path) |
| Nothing changes | no | no | no | no |

The `host` trigger in `pg_config` ensures config is re-delivered when the
target changes, even if the config content is identical (new host needs the
files). The `depends_on` guarantees preflight runs before config delivery
on first apply and host changes.

### Reload before restart

Reload always fires before restart. This validates config syntax before
committing to a restart that briefly interrupts connections. A syntax error
in the rendered config causes reload to fail and halts the provisioner before
the restart is issued.

---

## `outputs.tf`

```hcl
output "resolved_config" {
  value       = { for k, v in local.resolved : k => v if v != "" }
  description = <<-EOT
    The effective parameter map after pgtune calculation and pg_overrides
    merge. Represents what PostgreSQL uses after loading both
    01-pgtune.conf and 02-overrides.conf.

    Only contains active parameters — omitted parameters (e.g. parallel
    settings when pg_cpu_num = 1) are excluded. Feed back into
    var.current_pg_config on the next apply to enable plan-time restart
    detection.
  EOT
}

output "pgtune_calculated" {
  value       = { for k, v in local.pgtune : k => v if v != "" }
  description = "Raw pgtune values before override merge (contents of 01-pgtune.conf). Omitted parameters excluded."
}

output "effective_overrides" {
  value = {
    for param, override_val in var.pg_overrides :
    param => {
      pgtune   = lookup(local.pgtune, param, "(not a managed parameter)")
      override = override_val
      active   = lookup(local.pgtune, param, "") != ""
    }
  }
  description = <<-EOT
    Status of each pg_overrides key. Shows the pgtune-computed value,
    the override value, and whether the override is active (written to
    02-overrides.conf). active=false when the parameter is not managed
    or was omitted by the algorithm.
  EOT
}

output "restart_required" {
  value       = length(local.params_needing_restart) > 0 ? local.params_needing_restart : null
  description = <<-EOT
    Non-null when parameter changes require a PostgreSQL restart.
    Each key is a parameter name. Each value has 'old' (last applied,
    null on first apply) and 'new' (about to be applied).
    Visible in terraform plan output. Null when no restart-requiring
    parameters changed.
  EOT
}

output "config_file_paths" {
  value = {
    pgtune    = local.pgtune_file_path
    overrides = local.overrides_file_path
  }
  description = "Absolute paths of both config files written to the host."
}

output "warnings" {
  value       = local.warnings
  description = "Advisory warnings about configuration inputs. Non-empty when memory is outside optimised bounds, work_mem is below 4MB, or pg_overrides contains unrecognised keys."
}
```

---

## Correctness Verification

Verify the pgtune math in `terraform console` against these known-correct
outputs before wiring up SSH delivery. All values are exact (produced by
the formulas in this spec).

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

The second explicit row exercises the 4MB floor: the formula yields 436kB
but the floor applies. This also triggers the work_mem warning.

Note: the auto-connections formula ties `work_mem` to exactly 4MB on hosts
where `max_safe_connections < 200`. This is by design — the formula inverts
the `work_mem` constraint.

---

## Caller Example

```hcl
variable "pg_applied_config" {
  type    = map(string)
  default = {}
}

module "postgres" {
  source = "../../modules/postgres"

  pg_version = 18

  ssh_host        = incus_instance.pg_primary.ipv4_address
  ssh_user        = "ubuntu"
  ssh_private_key = file("~/.ssh/id_ed25519")

  pg_total_memory_gb = 4
  pg_cpu_num         = 2
  pg_hd_type         = "ssd"
  pg_connection_num  = 50

  pg_overrides = {
    work_mem = "16MB"
  }

  current_pg_config = var.pg_applied_config
}

output "pg_applied_config" {
  value       = module.postgres.resolved_config
  description = "Pass into var.pg_applied_config on next apply."
}
```

This produces two files on the host:

**`/etc/postgresql/18/main/conf.d/01-pgtune.conf`** — algorithm output:
```
work_mem = 20MB
```

**`/etc/postgresql/18/main/conf.d/02-overrides.conf`** — caller override:
```
work_mem = 16MB
```

PostgreSQL loads `02-overrides.conf` after `01-pgtune.conf`, so `work_mem`
is effectively `16MB`. The `effective_overrides` output shows both values:

```hcl
{
  work_mem = {
    pgtune   = "20MB"
    override = "16MB"
    active   = true
  }
}
```
