// Package inventory joins the three read sources — environment config, the
// .state preset files, and Docker — into one flat list of instances for the
// dashboard.
package inventory

import (
	"sort"

	"github.com/kseeman/GameServerAdministration/internal/config"
	"github.com/kseeman/GameServerAdministration/internal/dockerx"
)

// Instance is one row of the dashboard: a game/instance/env triple plus
// everything known about it.
type Instance struct {
	Game     string
	Name     string
	Env      string
	Info     config.InstanceInfo
	Ports    config.Ports
	Preset   string // from .state; "" means never recorded
	Default  string // instance's default_preset from the env config
	Docker   dockerx.Container
	Exists   bool // a container by this name exists (running or not)
	Volume   string
	Cfg      *config.EnvConfig
	HasVol   bool
	VolKnown bool // whether HasVol was actually determined
}

// Container is the container name server-manager.sh would use.
func (i Instance) Container() string {
	return config.ContainerName(i.Game, i.Name, i.Env)
}

// Running reports whether the container is up.
func (i Instance) Running() bool { return i.Exists && i.Docker.Running() }

// Key is a stable identifier for the instance across refreshes.
func (i Instance) Key() string { return i.Game + "/" + i.Env + "/" + i.Name }

// DisplayPreset is the active preset, or "unknown" when nothing has recorded one.
func (i Instance) DisplayPreset() string {
	if i.Preset == "" {
		return "unknown"
	}
	return i.Preset
}

// Status is a coarse state for sorting and coloring.
type Status int

const (
	StatusStopped Status = iota
	StatusStarting
	StatusRunning
	StatusUnhealthy
	StatusMissing // no container has ever been created
)

func (i Instance) Status() Status {
	if !i.Exists {
		return StatusMissing
	}
	if !i.Docker.Running() {
		return StatusStopped
	}
	switch i.Docker.Health() {
	case "unhealthy":
		return StatusUnhealthy
	case "starting":
		return StatusStarting
	}
	return StatusRunning
}

func (s Status) String() string {
	switch s {
	case StatusRunning:
		return "running"
	case StatusStarting:
		return "starting"
	case StatusUnhealthy:
		return "unhealthy"
	case StatusStopped:
		return "stopped"
	default:
		return "absent"
	}
}

// Snapshot is one full read of the fleet.
type Snapshot struct {
	Instances []Instance

	// DockerOK is false when the daemon could not be reached. Every instance
	// then reads as absent, which the UI must label as "docker unavailable"
	// rather than implying the servers are down.
	DockerOK    bool
	DockerError error
}

// Load reads the whole fleet. Games and environments are enumerated from the
// repo; Docker is consulted once for all of them.
func Load(repo *config.Repo, docker *dockerx.Client) (*Snapshot, error) {
	games, err := repo.Games()
	if err != nil {
		return nil, err
	}

	snap := &Snapshot{DockerOK: true}
	containers, err := docker.PS()
	if err != nil {
		snap.DockerOK = false
		snap.DockerError = err
		containers = map[string]dockerx.Container{}
	}

	for _, game := range games {
		for _, env := range config.Environments {
			cfg, err := repo.LoadEnvConfig(game, env)
			if err != nil {
				// A game missing one environment is normal; skip it quietly.
				continue
			}
			for _, name := range cfg.InstanceNames() {
				inst := Instance{
					Game:    game,
					Name:    name,
					Env:     env,
					Info:    cfg.Instances[name],
					Ports:   cfg.PortsFor(name),
					Preset:  repo.ActivePreset(game, name, env),
					Default: cfg.Instances[name].DefaultPreset,
					Volume:  config.VolumeName(game, name, env),
					Cfg:     cfg,
				}
				if ct, ok := containers[inst.Container()]; ok {
					inst.Docker = ct
					inst.Exists = true
				}
				snap.Instances = append(snap.Instances, inst)
			}
		}
	}

	sort.Slice(snap.Instances, func(a, b int) bool {
		x, y := snap.Instances[a], snap.Instances[b]
		if x.Game != y.Game {
			return x.Game < y.Game
		}
		// Production first: it is what you are usually worried about.
		if x.Env != y.Env {
			return x.Env > y.Env
		}
		return x.Name < y.Name
	})
	return snap, nil
}

// Counts summarises a snapshot for the header line.
//
// "absent" is kept separate from "stopped": an instance that has never had a
// container built is a different situation from one that was stopped, and
// folding them together would overstate how much of the fleet is deployed.
func (s *Snapshot) Counts() (running, stopped, absent, total int) {
	for _, i := range s.Instances {
		total++
		switch {
		case i.Running():
			running++
		case i.Exists:
			stopped++
		default:
			absent++
		}
	}
	return
}
