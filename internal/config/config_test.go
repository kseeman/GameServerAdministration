package config

import (
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
)

// repoRoot locates the checkout this test file lives in.
func repoRoot(t *testing.T) string {
	t.Helper()
	_, thisFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot determine test file location")
	}
	return filepath.Clean(filepath.Join(filepath.Dir(thisFile), "..", ".."))
}

func testRepo(t *testing.T) *Repo {
	t.Helper()
	r, err := NewRepo(repoRoot(t))
	if err != nil {
		t.Fatalf("NewRepo: %v", err)
	}
	return r
}

func TestNames(t *testing.T) {
	// Pinned against get_container_name / get_volume_name in
	// scripts/shared/server-utils.sh. If these ever disagree, the TUI would
	// silently operate on the wrong container.
	if got, want := ContainerName("palworld", "main", "production"), "palworld-production-main"; got != want {
		t.Errorf("ContainerName = %q, want %q", got, want)
	}
	if got, want := VolumeName("palworld", "main", "production"), "palworld-vol-production-main"; got != want {
		t.Errorf("VolumeName = %q, want %q", got, want)
	}
}

func TestValidEnvironment(t *testing.T) {
	for _, env := range []string{"staging", "production"} {
		if !ValidEnvironment(env) {
			t.Errorf("ValidEnvironment(%q) = false, want true", env)
		}
	}
	for _, env := range []string{"", "prod", "dev", "Staging"} {
		if ValidEnvironment(env) {
			t.Errorf("ValidEnvironment(%q) = true, want false", env)
		}
	}
}

// TestPortsMatchBash is the load-bearing test: it runs the real bash
// get_port_assignments for every configured instance and requires the Go
// implementation to agree exactly.
func TestPortsMatchBash(t *testing.T) {
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("bash not available")
	}
	if _, err := exec.LookPath("jq"); err != nil {
		t.Skip("jq not available: get_port_assignments would use its hardcoded fallback")
	}
	r := testRepo(t)
	games, err := r.Games()
	if err != nil {
		t.Fatalf("Games: %v", err)
	}
	if len(games) == 0 {
		t.Fatal("no games discovered")
	}

	checked := 0
	for _, game := range games {
		for _, env := range Environments {
			cfg, err := r.LoadEnvConfig(game, env)
			if err != nil {
				t.Fatalf("LoadEnvConfig(%s, %s): %v", game, env, err)
			}
			for _, inst := range cfg.InstanceNames() {
				want := bashPorts(t, r, game, inst, env)
				got := cfg.PortsFor(inst)
				// Compare the numbers only: Bases is presentation metadata
				// that has no bash counterpart.
				if got.Game != want.Game || got.Query != want.Query ||
					got.RCON != want.RCON || got.RESTAPI != want.RESTAPI {
					t.Errorf("%s/%s/%s: PortsFor = %d/%d/%d/%d, bash says %d/%d/%d/%d",
						game, env, inst,
						got.Game, got.Query, got.RCON, got.RESTAPI,
						want.Game, want.Query, want.RCON, want.RESTAPI)
				}
				checked++
			}
		}
	}
	t.Logf("compared %d instances against bash", checked)
}

// bashPorts sources server-utils.sh and calls the real function.
func bashPorts(t *testing.T, r *Repo, game, instance, env string) Ports {
	t.Helper()
	script := "source " + filepath.Join(r.Root, "scripts", "shared", "server-utils.sh") +
		" >/dev/null 2>&1; get_port_assignments " + game + " " + instance + " " + env
	out, err := exec.Command("bash", "-c", script).Output()
	if err != nil {
		t.Fatalf("bash get_port_assignments %s %s %s: %v", game, instance, env, err)
	}
	fields := strings.Fields(string(out))
	if len(fields) != 4 {
		t.Fatalf("expected 4 ports from bash, got %q", string(out))
	}
	nums := make([]int, 4)
	for i, f := range fields {
		n, err := strconv.Atoi(f)
		if err != nil {
			t.Fatalf("non-numeric port %q in %q", f, string(out))
		}
		nums[i] = n
	}
	return Ports{Game: nums[0], Query: nums[1], RCON: nums[2], RESTAPI: nums[3]}
}

func TestPortsKnownValues(t *testing.T) {
	// Independent of bash: ARK production applies offset * 10 to base 7790.
	r := testRepo(t)
	cfg, err := r.LoadEnvConfig("ark", "production")
	if err != nil {
		t.Skipf("ark production config unavailable: %v", err)
	}
	for inst, want := range map[string]int{"island": 7790, "extinction": 7860} {
		if got := cfg.PortsFor(inst).Game; got != want {
			t.Errorf("ark/%s game port = %d, want %d", inst, got, want)
		}
	}
	// ARK has no REST API port; a computed value there is meaningless.
	if cfg.PortsFor("island").HasRESTAPI() {
		t.Error("ark should report no REST API port")
	}
	if !cfg.PortsFor("island").HasRCON() {
		t.Error("ark should report an RCON port")
	}
}

// smalland and windrose configure only a game port. Rendering base+offset for
// the others would show a plausible-looking number for a port that does not
// exist.
func TestGamesWithOnlyAGamePort(t *testing.T) {
	r := testRepo(t)
	for _, game := range []string{"smalland", "windrose"} {
		cfg, err := r.LoadEnvConfig(game, "staging")
		if err != nil {
			t.Skipf("%s staging unavailable: %v", game, err)
		}
		p := cfg.PortsFor("test")
		if p.Game == 0 {
			t.Errorf("%s should have a game port", game)
		}
		if p.HasQuery() || p.HasRCON() || p.HasRESTAPI() {
			t.Errorf("%s reported query/rcon/rest ports it does not configure: %+v", game, p)
		}
	}
}

func TestUnknownInstanceUsesZeroOffset(t *testing.T) {
	r := testRepo(t)
	cfg, err := r.LoadEnvConfig("ark", "production")
	if err != nil {
		t.Skipf("ark production config unavailable: %v", err)
	}
	if got, want := cfg.PortsFor("does-not-exist").Game, cfg.NetworkConfig.BasePorts.Game; got != want {
		t.Errorf("unknown instance = %d, want base %d", got, want)
	}
}

func TestAllEnvConfigsParse(t *testing.T) {
	r := testRepo(t)
	games, err := r.Games()
	if err != nil {
		t.Fatalf("Games: %v", err)
	}
	for _, game := range games {
		for _, env := range Environments {
			cfg, err := r.LoadEnvConfig(game, env)
			if err != nil {
				t.Errorf("LoadEnvConfig(%s, %s): %v", game, env, err)
				continue
			}
			if len(cfg.Instances) == 0 {
				t.Errorf("%s/%s has no instances", game, env)
			}
			if cfg.NetworkConfig.BasePorts.Game == 0 {
				t.Errorf("%s/%s has no base game port", game, env)
			}
		}
	}
}

func TestPresetLineage(t *testing.T) {
	r := testRepo(t)
	// boosted-pve inherits default.json; the chain must terminate.
	got := r.PresetLineage("ark", "boosted-pve")
	if len(got) < 2 || got[0] != "boosted-pve" {
		t.Fatalf("PresetLineage(ark, boosted-pve) = %v, want it to start at boosted-pve and have a parent", got)
	}
	if got[len(got)-1] != "default" {
		t.Errorf("PresetLineage(ark, boosted-pve) = %v, want it to terminate at default", got)
	}
}

func TestPresetsListed(t *testing.T) {
	r := testRepo(t)
	games, err := r.Games()
	if err != nil {
		t.Fatalf("Games: %v", err)
	}
	for _, game := range games {
		presets, err := r.Presets(game)
		if err != nil {
			t.Errorf("Presets(%s): %v", game, err)
			continue
		}
		if len(presets) == 0 {
			t.Errorf("Presets(%s) returned nothing; every game should have at least default", game)
		}
	}
}

func TestBackupDirHasNoGameSegment(t *testing.T) {
	// Documents the collision the backup browser has to work around: two games
	// with a same-named instance resolve to the same directory.
	r := testRepo(t)
	pal, err := r.LoadEnvConfig("palworld", "staging")
	if err != nil {
		t.Skipf("palworld staging unavailable: %v", err)
	}
	ark, err := r.LoadEnvConfig("ark", "staging")
	if err != nil {
		t.Skipf("ark staging unavailable: %v", err)
	}
	if r.BackupDir(pal, "test") != r.BackupDir(ark, "test") {
		t.Skip("backup directories are namespaced by game; the browser's meta.game filter is now belt-and-braces")
	}
}
