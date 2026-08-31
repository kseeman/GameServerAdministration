package runner

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/kseeman/GameServerAdministration/internal/config"
)

// fakeRepo builds a checkout whose server-manager.sh is a stub script we
// control, so the tests exercise the runner without touching real servers.
func fakeRepo(t *testing.T, script string) *config.Repo {
	t.Helper()
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "games"), 0o755); err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(root, "scripts", "core")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "server-manager.sh"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	repo, err := config.NewRepo(root)
	if err != nil {
		t.Fatal(err)
	}
	return repo
}

func run(t *testing.T, repo *config.Repo, req Request) (Result, []string) {
	t.Helper()
	rn := New(repo)
	lines := make(chan string, 256)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	done, err := rn.Start(ctx, req, lines)
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	var collected []string
	for {
		select {
		case l := <-lines:
			collected = append(collected, l)
		case res := <-done:
			// Drain anything still buffered.
			for {
				select {
				case l := <-lines:
					collected = append(collected, l)
				default:
					return res, collected
				}
			}
		}
	}
}

func TestArgsAlwaysForceMutations(t *testing.T) {
	// Without --force, safety_confirmation() blocks on a read the TUI cannot
	// answer, hanging the operation forever.
	for _, op := range []Op{OpStart, OpStop, OpRestart, OpBackup, OpRestore, OpConfigSwap} {
		req := Request{Op: op, Game: "palworld", Instance: "main", Env: "staging", Preset: "casual", Backup: "x.tar.gz"}
		if !contains(req.Args(), "--force") {
			t.Errorf("%s args lack --force: %v", op, req.Args())
		}
	}
}

func TestArgsReadsAreNotForced(t *testing.T) {
	for _, op := range []Op{OpStatus, OpHealth, OpListBackups, OpValidate} {
		req := Request{Op: op, Game: "palworld", Instance: "main", Env: "staging"}
		if contains(req.Args(), "--force") {
			t.Errorf("read-only %s should not pass --force: %v", op, req.Args())
		}
	}
}

// server-manager.sh:241 silently turns `restart --preset X` into a config-swap.
// The TUI must never trigger that, or its confirmation text would describe an
// operation different from the one that runs.
func TestRestartNeverCarriesPreset(t *testing.T) {
	req := Request{Op: OpRestart, Game: "ark", Instance: "island", Env: "production", Preset: "boosted"}
	if contains(req.Args(), "--preset") {
		t.Errorf("restart must not pass --preset, got %v", req.Args())
	}
}

func TestConfigSwapCarriesPreset(t *testing.T) {
	req := Request{Op: OpConfigSwap, Game: "ark", Instance: "island", Env: "production", Preset: "boosted"}
	args := req.Args()
	if !contains(args, "--preset") || !contains(args, "boosted") {
		t.Errorf("config-swap lost its preset: %v", args)
	}
}

func TestValidateCatchesMissingFlags(t *testing.T) {
	cases := map[string]Request{
		"config-swap without preset": {Op: OpConfigSwap, Game: "ark", Instance: "island", Env: "production"},
		"restore without backup":     {Op: OpRestore, Game: "ark", Instance: "island", Env: "production"},
		"bad environment":            {Op: OpStop, Game: "ark", Instance: "island", Env: "prod"},
		"no game":                    {Op: OpStop, Instance: "island", Env: "production"},
		"no instance":                {Op: OpStop, Game: "ark", Env: "production"},
	}
	for name, req := range cases {
		if err := req.Validate(); err == nil {
			t.Errorf("%s: Validate returned nil, want an error", name)
		}
	}
}

// A non-zero exit must read as failure even though the script printed cheerful
// [SUCCESS] lines first — success is the exit code, never the text.
func TestFailureDetectedByExitCodeNotText(t *testing.T) {
	repo := fakeRepo(t, `#!/bin/bash
echo -e "\033[0;32m[SUCCESS]\033[0m Everything looks great"
echo "[ERROR] Container already exists"
exit 1
`)
	res, lines := run(t, repo, Request{Op: OpStart, Game: "palworld", Instance: "main", Env: "staging"})
	if res.OK() {
		t.Error("Result.OK() true for a script that exited 1")
	}
	if res.ExitCode != 1 {
		t.Errorf("ExitCode = %d, want 1", res.ExitCode)
	}
	joined := strings.Join(lines, "\n")
	if !strings.Contains(joined, "Container already exists") {
		t.Errorf("failure reason not streamed to the caller; got:\n%s", joined)
	}
	// ANSI must survive so the pane renders the script's own colouring.
	if !strings.Contains(joined, "\033[") {
		t.Error("ANSI escapes were stripped from the stream")
	}
}

func TestStdoutAndStderrBothStreamed(t *testing.T) {
	repo := fakeRepo(t, `#!/bin/bash
echo "from stdout"
echo "from stderr" >&2
exit 0
`)
	res, lines := run(t, repo, Request{Op: OpStatus, Game: "palworld", Instance: "main", Env: "staging"})
	if !res.OK() {
		t.Fatalf("expected success, got %+v", res)
	}
	joined := strings.Join(lines, "\n")
	for _, want := range []string{"from stdout", "from stderr"} {
		if !strings.Contains(joined, want) {
			t.Errorf("missing %q in stream:\n%s", want, joined)
		}
	}
}

// The runner must not drop trailing output when the process exits promptly.
func TestNoOutputLostAtExit(t *testing.T) {
	repo := fakeRepo(t, `#!/bin/bash
for i in $(seq 1 200); do echo "line $i"; done
exit 0
`)
	_, lines := run(t, repo, Request{Op: OpStatus, Game: "palworld", Instance: "main", Env: "staging"})
	if len(lines) != 200 {
		t.Errorf("got %d lines, want 200", len(lines))
	}
	if lines[len(lines)-1] != "line 200" {
		t.Errorf("last line = %q, want %q", lines[len(lines)-1], "line 200")
	}
}

// Two mutating operations on one instance must not overlap; cron already races
// us and the repo has no locking of its own.
func TestConcurrentMutationsBlocked(t *testing.T) {
	repo := fakeRepo(t, `#!/bin/bash
sleep 2
exit 0
`)
	rn := New(repo)
	req := Request{Op: OpBackup, Game: "palworld", Instance: "main", Env: "staging"}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	lines := make(chan string, 64)
	go func() {
		for range lines {
		}
	}()

	first, err := rn.Start(ctx, req, lines)
	if err != nil {
		t.Fatalf("first Start: %v", err)
	}
	if _, err := rn.Start(ctx, req, lines); err == nil {
		t.Error("second concurrent mutation was allowed on the same instance")
	}

	// A different instance is unaffected.
	other := req
	other.Instance = "test"
	if _, err := rn.Start(ctx, other, lines); err != nil {
		t.Errorf("lock on main wrongly blocked instance test: %v", err)
	}

	<-first
	// After release, the instance is usable again.
	if _, err := rn.Start(ctx, req, lines); err != nil {
		t.Errorf("lock not released after completion: %v", err)
	}
}

func TestReadsAreNotLocked(t *testing.T) {
	repo := fakeRepo(t, "#!/bin/bash\nsleep 1\n")
	rn := New(repo)
	req := Request{Op: OpStatus, Game: "palworld", Instance: "main", Env: "staging"}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	lines := make(chan string, 64)
	go func() {
		for range lines {
		}
	}()
	if _, err := rn.Start(ctx, req, lines); err != nil {
		t.Fatalf("first read: %v", err)
	}
	if _, err := rn.Start(ctx, req, lines); err != nil {
		t.Errorf("concurrent read blocked: %v", err)
	}
}

func TestDryRunPassedThrough(t *testing.T) {
	req := Request{Op: OpConfigSwap, Game: "ark", Instance: "island", Env: "production", Preset: "boosted", DryRun: true}
	if !contains(req.Args(), "--dry-run") {
		t.Errorf("dry-run flag lost: %v", req.Args())
	}
}

func contains(hay []string, needle string) bool {
	for _, s := range hay {
		if s == needle {
			return true
		}
	}
	return false
}
