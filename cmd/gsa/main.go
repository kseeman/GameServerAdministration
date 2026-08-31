// Command gsa is a terminal app for orchestrating the game servers in this
// repo.
//
// It reads state directly (environment JSON, .state preset files, docker ps)
// and performs every mutation by invoking scripts/core/server-manager.sh, so
// the bash plugin system remains the only implementation of game behavior.
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/kseeman/GameServerAdministration/internal/config"
	"github.com/kseeman/GameServerAdministration/internal/dockerx"
	"github.com/kseeman/GameServerAdministration/internal/ui"
)

func main() {
	var (
		root   = flag.String("repo-root", "", "path to the GameServerAdministration checkout (default: auto-detect)")
		env    = flag.String("env", "", "start filtered to one environment (staging or production)")
		checkO = flag.Bool("check", false, "verify the repo and docker are readable, then exit")
	)
	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, "gsa — terminal UI for the game server fleet\n\nUsage:\n  gsa [flags]\n\nFlags:\n")
		flag.PrintDefaults()
	}
	flag.Parse()

	repoRoot, err := resolveRoot(*root)
	if err != nil {
		fatal(err)
	}
	repo, err := config.NewRepo(repoRoot)
	if err != nil {
		fatal(err)
	}

	if *env != "" && !config.ValidEnvironment(*env) {
		fatal(fmt.Errorf("invalid --env %q: must be staging or production", *env))
	}

	docker := dockerx.New()

	if *checkO {
		check(repo, docker, *env)
		return
	}

	model := ui.New(repo, docker, *env)
	// The alt screen keeps the user's scrollback intact, which matters when
	// you are already several commands deep in an SSH session.
	p := tea.NewProgram(model, tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fatal(err)
	}
}

// resolveRoot finds the checkout: an explicit flag, then the executable's
// location (bin/gsa inside the repo), then the working directory and its
// parents.
func resolveRoot(explicit string) (string, error) {
	if explicit != "" {
		return explicit, nil
	}

	if exe, err := os.Executable(); err == nil {
		if root, ok := walkUp(filepath.Dir(exe)); ok {
			return root, nil
		}
	}
	if wd, err := os.Getwd(); err == nil {
		if root, ok := walkUp(wd); ok {
			return root, nil
		}
	}
	return "", fmt.Errorf("could not locate a GameServerAdministration checkout; pass --repo-root")
}

// walkUp climbs from dir looking for the repo markers.
func walkUp(dir string) (string, bool) {
	for {
		if _, err := os.Stat(filepath.Join(dir, "scripts", "core", "server-manager.sh")); err == nil {
			if _, err := os.Stat(filepath.Join(dir, "games")); err == nil {
				return dir, true
			}
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", false
		}
		dir = parent
	}
}

// check is a non-interactive smoke test, useful over SSH before launching the
// full UI and in the Makefile's verification step.
func check(repo *config.Repo, docker *dockerx.Client, env string) {
	fmt.Printf("repo root:  %s\n", repo.Root)

	games, err := repo.Games()
	if err != nil {
		fatal(err)
	}
	fmt.Printf("games:      %d (%v)\n", len(games), games)

	envs := config.Environments
	if env != "" {
		envs = []string{env}
	}

	total := 0
	for _, game := range games {
		for _, e := range envs {
			cfg, err := repo.LoadEnvConfig(game, e)
			if err != nil {
				continue
			}
			total += len(cfg.Instances)
		}
	}
	fmt.Printf("instances:  %d\n", total)

	if docker.Available() {
		containers, err := docker.PS()
		if err != nil {
			fmt.Printf("docker:     reachable, but ps failed: %v\n", err)
		} else {
			fmt.Printf("docker:     reachable (%d containers)\n", len(containers))
		}
	} else {
		fmt.Printf("docker:     unavailable — the dashboard will show every instance as absent\n")
	}
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "gsa:", err)
	os.Exit(1)
}
