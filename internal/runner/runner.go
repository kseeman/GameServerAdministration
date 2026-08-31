// Package runner invokes scripts/core/server-manager.sh and streams its output.
//
// Every mutation the TUI performs goes through here. The runner deliberately
// knows nothing about what an operation does — it builds an argv, streams the
// subprocess, and reports the exit code. All game behavior stays in the bash
// plugin system.
package runner

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"

	"github.com/kseeman/GameServerAdministration/internal/config"
)

// Op is a server-manager.sh operation.
type Op string

const (
	OpStart       Op = "start"
	OpStop        Op = "stop"
	OpRestart     Op = "restart"
	OpStatus      Op = "status"
	OpHealth      Op = "health"
	OpBackup      Op = "backup"
	OpRestore     Op = "restore"
	OpConfigSwap  Op = "config-swap"
	OpListBackups Op = "list-backups"
	OpValidate    Op = "validate"
)

// Mutating reports whether an operation changes server state. Only these take a
// lock and require confirmation.
func (o Op) Mutating() bool {
	switch o {
	case OpStart, OpStop, OpRestart, OpBackup, OpRestore, OpConfigSwap:
		return true
	}
	return false
}

// Destructive reports whether an operation can lose data. Restore wipes
// SaveGames/ and Config/ wholesale before replacing them.
func (o Op) Destructive() bool { return o == OpRestore }

// Request is one invocation.
type Request struct {
	Op       Op
	Game     string
	Instance string
	Env      string

	// Preset is required for config-swap and optional for start.
	Preset string

	// Backup is the archive basename, required for restore. server-manager.sh
	// globs the backup directories, so a bare filename is enough.
	Backup string

	DryRun bool
}

// Args builds the argv for server-manager.sh.
//
// --force is always passed: the TUI runs its own confirmation, and without it
// the script's safety_confirmation() would block on a `read` the TUI cannot
// answer. Note this skips only that prompt — run_safety_checklist still runs
// and can still refuse the operation.
func (r Request) Args() []string {
	args := []string{string(r.Op), "--game", r.Game, "--env", r.Env}

	// list and validate are game+env only; passing --instance is harmless but
	// omitted to match the documented surface.
	if r.Op != OpValidate {
		args = append(args, "--instance", r.Instance)
	}

	switch r.Op {
	case OpConfigSwap:
		args = append(args, "--preset", r.Preset)
	case OpStart:
		// restart deliberately never receives --preset: server-manager.sh:241
		// silently reroutes `restart --preset X` into a config-swap, which
		// would make the TUI's confirmation text a lie.
		if r.Preset != "" {
			args = append(args, "--preset", r.Preset)
		}
		if r.Backup != "" {
			args = append(args, "--backup", r.Backup)
		}
	case OpRestore:
		args = append(args, "--backup", r.Backup)
	}

	if r.DryRun {
		args = append(args, "--dry-run")
	}
	if r.Op.Mutating() {
		args = append(args, "--force")
	}
	return args
}

// Validate catches missing flags before we spawn anything, so the user gets a
// clear message instead of the script's usage dump.
func (r Request) Validate() error {
	if r.Game == "" {
		return fmt.Errorf("no game selected")
	}
	if !config.ValidEnvironment(r.Env) {
		return fmt.Errorf("invalid environment %q", r.Env)
	}
	if r.Op != OpValidate && r.Instance == "" {
		return fmt.Errorf("no instance selected")
	}
	if r.Op == OpConfigSwap && r.Preset == "" {
		return fmt.Errorf("config-swap requires a preset")
	}
	if r.Op == OpRestore && r.Backup == "" {
		return fmt.Errorf("restore requires a backup file")
	}
	return nil
}

// Describe renders the equivalent CLI command, so the output pane always shows
// exactly what was run.
func (r Request) Describe(scriptPath string) string {
	return scriptPath + " " + strings.Join(r.Args(), " ")
}

// Key identifies the instance a request acts on, for locking.
func (r Request) Key() string {
	return r.Game + "-" + r.Env + "-" + r.Instance
}

// Runner executes requests against a repo.
type Runner struct {
	Repo *config.Repo
}

func New(repo *config.Repo) *Runner { return &Runner{Repo: repo} }

// Result is the outcome of a finished run.
type Result struct {
	ExitCode int
	Err      error
}

// OK reports success. Success is the exit code and nothing else: all of the
// script's log output goes to stdout with ANSI colour and [LEVEL] prefixes, so
// parsing it for words like "error" would be wrong in both directions.
func (r Result) OK() bool { return r.Err == nil && r.ExitCode == 0 }

// Start launches a request, writing interleaved stdout and stderr into lines as
// they arrive, and delivering the outcome on the returned channel.
//
// The caller cancels via ctx. Cancellation signals the process group, so the
// bash script and its docker children go down together rather than leaving an
// orphaned `docker compose` behind.
func (rn *Runner) Start(ctx context.Context, req Request, lines chan<- string) (<-chan Result, error) {
	if err := req.Validate(); err != nil {
		return nil, err
	}

	lock, err := acquire(rn.Repo, req)
	if err != nil {
		return nil, err
	}

	script := rn.Repo.ServerManager()
	cmd := exec.CommandContext(ctx, script, req.Args()...)
	cmd.Dir = rn.Repo.Root
	// server-utils.sh sources .env relative to REPO_ROOT, so inheriting the
	// environment is enough; secrets never pass through the TUI.
	cmd.Env = os.Environ()
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		// Negative pid signals the whole process group.
		return syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
	}

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		lock.release()
		return nil, err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		lock.release()
		return nil, err
	}

	if err := cmd.Start(); err != nil {
		lock.release()
		return nil, fmt.Errorf("starting %s: %w", script, err)
	}

	var wg sync.WaitGroup
	wg.Add(2)
	go pump(&wg, stdout, lines)
	go pump(&wg, stderr, lines)

	done := make(chan Result, 1)
	go func() {
		defer lock.release()
		wg.Wait() // drain both pipes before reaping, so no output is lost
		err := cmd.Wait()
		res := Result{}
		var exitErr *exec.ExitError
		switch {
		case err == nil:
		case asExitError(err, &exitErr):
			res.ExitCode = exitErr.ExitCode()
		default:
			res.Err = err
			res.ExitCode = -1
		}
		done <- res
		close(done)
	}()

	return done, nil
}

func asExitError(err error, target **exec.ExitError) bool {
	e, ok := err.(*exec.ExitError)
	if ok {
		*target = e
	}
	return ok
}

// pump forwards a pipe line by line. ANSI escapes are passed through untouched
// so the output pane renders the script's own colouring.
func pump(wg *sync.WaitGroup, r io.Reader, lines chan<- string) {
	defer wg.Done()
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		lines <- scanner.Text()
	}
}

// --- locking ---------------------------------------------------------------

// lock is an advisory per-instance flock.
//
// The repo has no locking of its own, and cron runs scheduled-backup.sh and
// scheduled-config-swap.sh against these same instances. This stops the TUI
// from colliding with itself; it cannot stop cron, which is why the UI also
// surfaces the crontab.
type lock struct{ f *os.File }

func acquire(repo *config.Repo, req Request) (*lock, error) {
	if !req.Op.Mutating() {
		return &lock{}, nil // reads need no lock
	}
	dir := filepath.Join(repo.Root, ".state", "locks")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, fmt.Errorf("creating lock directory: %w", err)
	}
	path := filepath.Join(dir, req.Key()+".lock")
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return nil, fmt.Errorf("opening lock file: %w", err)
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return nil, fmt.Errorf("another operation is already running on %s", req.Key())
	}
	return &lock{f: f}, nil
}

func (l *lock) release() {
	if l == nil || l.f == nil {
		return
	}
	syscall.Flock(int(l.f.Fd()), syscall.LOCK_UN)
	l.f.Close()
	l.f = nil
}
