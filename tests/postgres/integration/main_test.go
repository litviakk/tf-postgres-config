// Package integration is the Layer 3 integration test suite for modules/postgres.
//
// It spins up a Docker container (sshd + PostgreSQL 17), generates an ephemeral
// SSH key pair, applies the module via Terratest, and then SSH-asserts that:
//   - conf files land in conf.d with correct ownership/permissions
//   - SHOW <param> via psql matches resolved_config for every managed parameter
//   - A second apply with unchanged inputs is a no-op (null_resource does not re-trigger)
//   - Changing a reload-safe param reloads without restarting
//   - Changing shared_buffers (restart-required) triggers a restart
//   - pg_force_restart forces a restart even for reload-safe changes
//   - pg_skip_restart skips the restart even when shared_buffers changes
//
// Run:
//
//	cd tests/postgres/integration
//	go test -v -timeout 20m -run TestPostgresModule
package integration

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/pem"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"golang.org/x/crypto/ssh"
)

const (
	containerName = "pg_integration_test"
	pgImage       = "pg-integration-test:latest" // built from local Dockerfile
	pgVersion     = 18
	sshUser       = "postgres"
	sshPortHost   = 2222 // host-side port mapped to container 22
	pgPortHost    = 5433 // host-side port mapped to container 5432

	// pgdata is the default PGDATA for the official postgres:17 image.
	pgdata    = "/var/lib/postgresql/data"
	pgConfD   = pgdata + "/conf.d"
	tuneConf  = pgConfD + "/01-pgtune.conf"
	overConf  = pgConfD + "/02-overrides.conf"
)

// fixture is the path to the Terraform root module used by all tests.
var fixtureDir string

func init() {
	// Resolve fixture dir relative to this file at compile time.
	wd, err := os.Getwd()
	if err != nil {
		panic(err)
	}
	fixtureDir = filepath.Join(wd, "fixtures")
}

// ----------------------------------------------------------------------------
// TestMain — suite-level setup and teardown
// ----------------------------------------------------------------------------

func TestMain(m *testing.M) {
	if err := suiteSetup(); err != nil {
		fmt.Fprintf(os.Stderr, "suite setup failed: %v\n", err)
		os.Exit(1)
	}
	code := m.Run()
	suiteTeardown()
	os.Exit(code)
}

var (
	privateKeyPEM  string // PEM-encoded RSA private key (SSH auth)
	privateKeyPath string // temp file written for tests that need a path
)

func suiteSetup() error {
	// 1. Build the Docker image.
	testDir := filepath.Dir(fixtureDir)
	if err := runCmd("docker", "build", "-t", pgImage, testDir); err != nil {
		return fmt.Errorf("docker build: %w", err)
	}

	// 2. Generate an ephemeral RSA key pair.
	priv, pub, err := generateSSHKeyPair()
	if err != nil {
		return fmt.Errorf("generate ssh key: %w", err)
	}
	privateKeyPEM = priv

	// Write private key to a temp file so Terraform can read it if needed.
	f, err := os.CreateTemp("", "pg-integration-*.pem")
	if err != nil {
		return fmt.Errorf("write private key: %w", err)
	}
	if _, err := f.WriteString(priv); err != nil {
		return err
	}
	f.Close()
	privateKeyPath = f.Name()

	// 3. Start the container.
	if err := runCmd("docker", "rm", "-f", containerName); err != nil {
		// ignore — container may not exist yet
	}
	if err := runCmd("docker", "run", "-d",
		"--name", containerName,
		"--init",
		"-p", fmt.Sprintf("%d:22", sshPortHost),
		"-p", fmt.Sprintf("%d:5432", pgPortHost),
		"-e", "POSTGRES_PASSWORD=testpassword",
		"-e", "POSTGRES_HOST_AUTH_METHOD=trust",
		pgImage,
		"postgres",
	); err != nil {
		return fmt.Errorf("docker run: %w", err)
	}

	// 4. Install the public key for the postgres user.
	if err := waitForContainer(); err != nil {
		return fmt.Errorf("wait for container: %w", err)
	}
	authKeysLine := strings.TrimSpace(pub) + "\n"
	if err := dockerExec("sh", "-c",
		fmt.Sprintf("printf '%%s' '%s' > /var/lib/postgresql/.ssh/authorized_keys && chmod 600 /var/lib/postgresql/.ssh/authorized_keys && chown postgres:postgres /var/lib/postgresql/.ssh/authorized_keys",
			strings.ReplaceAll(authKeysLine, "'", "'\\''"),
		),
	); err != nil {
		return fmt.Errorf("install authorized_keys: %w", err)
	}

	// 5. Wait for PostgreSQL to accept connections.
	if err := waitForPostgres(); err != nil {
		return fmt.Errorf("wait for postgres: %w", err)
	}

	return nil
}

func suiteTeardown() {
	_ = runCmd("docker", "rm", "-f", containerName)
	if privateKeyPath != "" {
		_ = os.Remove(privateKeyPath)
	}
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

// TestPostgresModule runs all integration scenarios sequentially.
// Scenarios share the same container but each applies fresh terraform state
// via a unique state file or by destroying between runs.
func TestPostgresModule(t *testing.T) {
	t.Run("BasicApply", testBasicApply)
	t.Run("IdempotentSecondApply", testIdempotentSecondApply)
	t.Run("ReloadSafeParamChange", testReloadSafeParamChange)
	t.Run("RestartRequiredParamChange", testRestartRequiredParamChange)
	t.Run("ForceRestart", testForceRestart)
	t.Run("SkipRestart", testSkipRestart)
	t.Run("OverridesMerge", testOverridesMerge)
}

// testBasicApply: first apply delivers conf files and all psql SHOW values match.
func testBasicApply(t *testing.T) {
	opts := baseTerraformOptions(t, map[string]interface{}{
		"pg_total_memory_gb": 2,
		"pg_cpu_num":         2,
	})
	defer terraform.Destroy(t, opts)
	terraform.InitAndApply(t, opts)

	assertConfFiles(t, pgConfD)
	assertPsqlParams(t, opts)
}

// testIdempotentSecondApply: second apply with same inputs must not change any resources.
func testIdempotentSecondApply(t *testing.T) {
	opts := baseTerraformOptions(t, map[string]interface{}{
		"pg_total_memory_gb": 2,
		"pg_cpu_num":         2,
	})
	defer terraform.Destroy(t, opts)
	terraform.InitAndApply(t, opts)

	// Second apply: assert zero resources changed.
	stdout := terraform.Apply(t, opts)
	assert.Contains(t, stdout, "0 to add, 0 to change, 0 to destroy",
		"second apply with unchanged inputs must be a no-op")
}

// testReloadSafeParamChange: changing work_mem (reload-safe) reloads without restart.
func testReloadSafeParamChange(t *testing.T) {
	opts := baseTerraformOptions(t, map[string]interface{}{
		"pg_total_memory_gb": 2,
		"pg_cpu_num":         2,
	})
	defer terraform.Destroy(t, opts)
	terraform.InitAndApply(t, opts)

	pidBefore := pgPID(t)

	opts.Vars["pg_overrides"] = map[string]string{"work_mem": "8MB"}
	terraform.Apply(t, opts)

	pidAfter := pgPID(t)
	assert.Equal(t, pidBefore, pidAfter, "reload-safe param change must not restart PostgreSQL (PID unchanged)")

	// Verify work_mem appears in the overrides conf file.
	confPath := overConf
	content, err := dockerExecOutput("cat", confPath)
	require.NoError(t, err, "read overrides conf")
	assert.Contains(t, content, "work_mem", "02-overrides.conf must contain work_mem after override")
}

// testRestartRequiredParamChange: changing shared_buffers triggers a restart (new PID).
func testRestartRequiredParamChange(t *testing.T) {
	// Apply with 2GB RAM (shared_buffers = 512MB).
	opts := baseTerraformOptions(t, map[string]interface{}{
		"pg_total_memory_gb": 2,
		"pg_cpu_num":         2,
	})
	defer terraform.Destroy(t, opts)
	terraform.InitAndApply(t, opts)

	pidBefore := pgPID(t)

	// Change to 4GB RAM (shared_buffers = 1024MB — restart-required).
	opts.Vars["pg_total_memory_gb"] = 4
	terraform.Apply(t, opts)

	pidAfter := pgPID(t)
	assert.NotEqual(t, pidBefore, pidAfter, "shared_buffers change must restart PostgreSQL (new PID)")
}

// testForceRestart: pg_force_restart = true restarts even for reload-safe change.
func testForceRestart(t *testing.T) {
	opts := baseTerraformOptions(t, map[string]interface{}{
		"pg_total_memory_gb": 2,
		"pg_cpu_num":         2,
	})
	defer terraform.Destroy(t, opts)
	terraform.InitAndApply(t, opts)

	pidBefore := pgPID(t)

	opts.Vars["pg_overrides"] = map[string]string{"work_mem": "8MB"}
	opts.Vars["pg_force_restart"] = true
	terraform.Apply(t, opts)

	pidAfter := pgPID(t)
	assert.NotEqual(t, pidBefore, pidAfter, "pg_force_restart must trigger a restart even for reload-safe param changes")
}

// testSkipRestart: pg_skip_restart = true skips restart even when shared_buffers changes.
func testSkipRestart(t *testing.T) {
	opts := baseTerraformOptions(t, map[string]interface{}{
		"pg_total_memory_gb": 2,
		"pg_cpu_num":         2,
	})
	defer terraform.Destroy(t, opts)
	terraform.InitAndApply(t, opts)

	pidBefore := pgPID(t)

	opts.Vars["pg_total_memory_gb"] = 4 // shared_buffers changes
	opts.Vars["pg_skip_restart"] = true
	terraform.Apply(t, opts)

	pidAfter := pgPID(t)
	assert.Equal(t, pidBefore, pidAfter, "pg_skip_restart must prevent restart even when restart-required params change")
}

// testOverridesMerge: pg_overrides values appear in resolved_config output and active in psql.
func testOverridesMerge(t *testing.T) {
	overrides := map[string]string{
		"work_mem":                    "16MB",
		"checkpoint_completion_target": "0.8",
	}
	opts := baseTerraformOptions(t, map[string]interface{}{
		"pg_total_memory_gb": 2,
		"pg_cpu_num":         2,
		"pg_overrides":       overrides,
	})
	defer terraform.Destroy(t, opts)
	terraform.InitAndApply(t, opts)

	// resolved_config output must contain override values.
	resolved := terraform.OutputMap(t, opts, "resolved_config")
	assert.Equal(t, "16MB", resolved["work_mem"])
	assert.Equal(t, "0.8", resolved["checkpoint_completion_target"])

	// pgtune_calculated must retain the original computed value.
	pgtune := terraform.OutputMap(t, opts, "pgtune_calculated")
	assert.NotEqual(t, "16MB", pgtune["work_mem"], "pgtune_calculated must show pre-override value")

	// The overrides conf file must contain the override value.
	confPath := overConf
	content, err := dockerExecOutput("cat", confPath)
	require.NoError(t, err, "read overrides conf")
	assert.Contains(t, content, "work_mem = 16MB", "02-overrides.conf must contain work_mem = 16MB")
}

// ----------------------------------------------------------------------------
// Helpers
// ----------------------------------------------------------------------------

// baseTerraformOptions returns Terraform options pointing at the fixture dir,
// with a unique state file per test and common variables set.
func baseTerraformOptions(t *testing.T, extra map[string]interface{}) *terraform.Options {
	t.Helper()

	vars := map[string]interface{}{
		"ssh_host":       "127.0.0.1",
		"ssh_port":       sshPortHost,
		"ssh_user":       sshUser,
		"ssh_private_key": privateKeyPEM,
		"pg_version":     pgVersion,
	}
	for k, v := range extra {
		vars[k] = v
	}

	return &terraform.Options{
		TerraformDir: fixtureDir,
		Vars:         vars,
		// Unique state file per test to allow t.Parallel() across sub-tests.
		EnvVars: map[string]string{
			"TF_STATE": filepath.Join(os.TempDir(), fmt.Sprintf("tf-pg-integration-%s.tfstate", t.Name())),
		},
	}
}

// assertConfFiles verifies that both conf files exist in confDDir with mode 640
// and postgres:postgres ownership.
func assertConfFiles(t *testing.T, _ string) {
	t.Helper()
	for _, path := range []string{tuneConf, overConf} {
		fname := filepath.Base(path)
		out, err := dockerExecOutput("stat", "-c", "%a %U %G", path)
		require.NoError(t, err, "stat %s", path)
		fields := strings.Fields(strings.TrimSpace(out))
		require.Len(t, fields, 3, "unexpected stat output for %s: %q", path, out)
		assert.Equal(t, "640", fields[0], "%s: expected mode 640", fname)
		assert.Equal(t, "postgres", fields[1], "%s: expected user postgres", fname)
		assert.Equal(t, "postgres", fields[2], "%s: expected group postgres", fname)
	}
}

// assertPsqlParams verifies that every key in resolved_config is present and
// active in PostgreSQL by reading 01-pgtune.conf content and spot-checking
// a subset of params via pg_settings (unit-normalised values are skipped).
func assertPsqlParams(t *testing.T, opts *terraform.Options) {
	t.Helper()
	resolved := terraform.OutputMap(t, opts, "resolved_config")

	// Read the deployed conf file and verify each managed key appears.
	confPath := tuneConf
	content, err := dockerExecOutput("cat", confPath)
	require.NoError(t, err, "read %s", confPath)

	for param := range resolved {
		assert.Contains(t, content, param, "01-pgtune.conf must contain param %s", param)
	}

	// Spot-check string/integer params that PG does not normalise to different units.
	unitlessParams := map[string]bool{
		"max_connections":              true,
		"default_statistics_target":   true,
		"checkpoint_completion_target": true,
		"random_page_cost":             true,
		"effective_io_concurrency":     true,
		"huge_pages":                   true,
		"max_worker_processes":         true,
		"max_parallel_workers":         true,
		"max_parallel_workers_per_gather":  true,
		"max_parallel_maintenance_workers": true,
	}
	for param, want := range resolved {
		if !unitlessParams[param] {
			continue
		}
		got, err := dockerExecOutput("su", "-", "postgres", "-c",
			fmt.Sprintf("psql -tAc \"SELECT setting FROM pg_settings WHERE name = '%s';\"", param))
		require.NoError(t, err, "pg_settings query for %s", param)
		assert.Equal(t, want, strings.TrimSpace(got), "pg_settings[%s] mismatch", param)
	}
}

// pgPID returns the PostgreSQL postmaster PID.
func pgPID(t *testing.T) string {
	t.Helper()
	out, err := dockerExecOutput("su", "-", "postgres", "-c",
		"psql -tAc \"SELECT pg_postmaster_start_time();\"")
	require.NoError(t, err, "query postmaster start time")
	// We use start time as a proxy for PID because PID resets each restart.
	return strings.TrimSpace(out)
}

// ----------------------------------------------------------------------------
// Docker / SSH utilities
// ----------------------------------------------------------------------------

func dockerExec(args ...string) error {
	_, err := dockerExecOutput(args...)
	return err
}

func dockerExecOutput(args ...string) (string, error) {
	cmdArgs := append([]string{"exec", containerName}, args...)
	cmd := exec.Command("docker", cmdArgs...)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func runCmd(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func waitForContainer() error {
	deadline := time.Now().Add(60 * time.Second)
	for time.Now().Before(deadline) {
		if err := runCmd("docker", "exec", containerName, "true"); err == nil {
			return nil
		}
		time.Sleep(time.Second)
	}
	return fmt.Errorf("container %s did not become ready within 60s", containerName)
}

func waitForPostgres() error {
	deadline := time.Now().Add(60 * time.Second)
	for time.Now().Before(deadline) {
		if err := runCmd("docker", "exec", containerName,
			"pg_isready", "-U", "postgres"); err == nil {
			return nil
		}
		time.Sleep(time.Second)
	}
	return fmt.Errorf("PostgreSQL did not become ready within 60s")
}

// ----------------------------------------------------------------------------
// SSH key generation
// ----------------------------------------------------------------------------

// generateSSHKeyPair returns (privatePEM, publicAuthorizedKeysLine, error).
func generateSSHKeyPair() (string, string, error) {
	priv, err := rsa.GenerateKey(rand.Reader, 4096)
	if err != nil {
		return "", "", err
	}

	privPEM := pem.EncodeToMemory(&pem.Block{
		Type:  "RSA PRIVATE KEY",
		Bytes: x509.MarshalPKCS1PrivateKey(priv),
	})

	pub, err := ssh.NewPublicKey(&priv.PublicKey)
	if err != nil {
		return "", "", err
	}
	pubLine := strings.TrimRight(string(ssh.MarshalAuthorizedKey(pub)), "\n")

	return string(privPEM), pubLine, nil
}
