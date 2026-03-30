# tf-postgres-config

Terraform/OpenTofu module that SSH-delivers pgtune-computed PostgreSQL configuration to a running Linux instance.

Computes optimal performance parameters from hardware facts (RAM, CPU, storage type) using the [pgtune](https://github.com/le0pard/pgtune) algorithm and writes them to two `conf.d` drop-in files on the target host. Handles reload and restart automatically.

## Requirements

- Terraform / OpenTofu >= 1.6
- Provider `hashicorp/null` >= 3.0
- Target: Linux host with PostgreSQL 16, 17, or 18; `pg_ctl` and `psql` in PATH; SSH user with passwordless sudo

## Usage

```hcl
module "postgres" {
  source = "path/to/modules/postgres"

  pg_version         = 17
  pg_total_memory_gb = 8
  pg_cpu_num         = 4
  pg_hd_type         = "ssd"

  ssh_host        = "10.0.0.5"
  ssh_user        = "ubuntu"
  ssh_private_key = file("~/.ssh/id_rsa")
}
```

### Key variables

| Variable | Default | Description |
|---|---|---|
| `pg_version` | required | PostgreSQL major version: 16, 17, or 18 |
| `pg_total_memory_gb` | required | Total system RAM in GB (fractional OK) |
| `pg_cpu_num` | `2` | Number of CPUs; parallelism params omitted when `1` |
| `pg_connection_num` | `0` | Max connections; `0` = auto (RAM-based) |
| `pg_hd_type` | `"ssd"` | Storage type: `hdd`, `ssd`, or `san` |
| `pg_overrides` | `{}` | Manual parameter overrides written to `02-overrides.conf` |
| `ssh_host` | required | IP or hostname of the target |
| `ssh_user` | `"ubuntu"` | SSH user with passwordless sudo |
| `ssh_private_key` | `""` | Private key contents; omit when `ssh_use_agent = true` |
| `ssh_use_agent` | `false` | Use local SSH agent for auth |
| `ssh_port` | `22` | SSH port |
| `pg_force_restart` | `false` | Always restart after delivery |
| `pg_skip_restart` | `false` | Never restart, even when restart-required params change |

### Outputs

| Output | Description |
|---|---|
| `resolved_config` | Effective parameter map (pgtune + overrides) |
| `pgtune_calculated` | Raw pgtune values before override merge |
| `effective_overrides` | Per-key status: pgtune, override, and active values |
| `config_file_paths` | Absolute paths of both conf files on the target |

## What it manages

Two files on the target host:

```
<conf.d>/01-pgtune.conf     # computed pgtune values
<conf.d>/02-overrides.conf  # pg_overrides values
```

The `conf.d` path is auto-discovered from `include_dir` in `postgresql.conf`, or set explicitly via `conf_d_dir`.

## Testing

Three layers. Run them all with `make test`, or individually:

```sh
make unit          # Layer 1: terraform test — formula unit tests, no infrastructure
make preflight     # Layer 2: bats — preflight.sh against a live Docker PG container
make integration   # Layer 3: Terratest Go — full apply against a Docker SSH target
```

Run a single unit test file:

```sh
make unit UNIT_FILTER=sizing.tftest.hcl
```

### Prerequisites by layer

| Layer | Requires |
|---|---|
| unit | `terraform` >= 1.6 |
| preflight | `terraform` >= 1.6, `bats-core` >= 1.7, `docker` |
| integration | `go` >= 1.22, `docker`, `terraform` >= 1.6 |

### Other make targets

```sh
make build-image       # build the Docker image for integration tests only
make tf-init           # terraform init in modules/postgres
make clean             # remove .terraform caches and test fixture state
make clean-intg        # remove integration container and temp state files
```

## Repo structure

```
modules/postgres/          # the module
  variables.tf
  locals.tf                # pgtune math layer (all values in MB)
  main.tf                  # null_resource provisioners
  outputs.tf
  templates/
    preflight.sh.tftpl
    config_delivery.sh.tftpl
    postgresql_tune.conf.tftpl
    postgresql_overrides.conf.tftpl
  tests/
    unit/                  # terraform test files
    preflight/             # bats test + render fixture
tests/postgres/
  integration/             # Terratest Go suite + Dockerfile
Makefile
```
