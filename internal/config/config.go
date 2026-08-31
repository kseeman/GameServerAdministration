// Package config reads the repo's declarative game configuration: the
// per-environment JSON under games/<game>/environments/ and the presets under
// games/<game>/presets/.
//
// Everything here is a read. Mutations go through scripts/core/server-manager.sh
// (see internal/runner) so that the bash plugin system stays the only
// implementation of game behavior.
package config

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Environment names accepted by validate_environment() in
// scripts/shared/server-utils.sh:99. Nothing else is legal.
const (
	EnvStaging    = "staging"
	EnvProduction = "production"
)

// Environments lists the valid environments in display order.
var Environments = []string{EnvStaging, EnvProduction}

// ValidEnvironment mirrors validate_environment (server-utils.sh:99-108).
func ValidEnvironment(env string) bool {
	return env == EnvStaging || env == EnvProduction
}

// Repo is a handle on a checkout of the GameServerAdministration repo.
type Repo struct {
	Root string
}

// NewRepo returns a Repo rooted at root, verifying it looks like the real thing.
func NewRepo(root string) (*Repo, error) {
	abs, err := filepath.Abs(root)
	if err != nil {
		return nil, err
	}
	for _, marker := range []string{"games", filepath.Join("scripts", "core", "server-manager.sh")} {
		if _, err := os.Stat(filepath.Join(abs, marker)); err != nil {
			return nil, fmt.Errorf("%s does not look like a GameServerAdministration checkout: missing %s", abs, marker)
		}
	}
	return &Repo{Root: abs}, nil
}

// ServerManager is the path to the bash entry point every mutation goes through.
func (r *Repo) ServerManager() string {
	return filepath.Join(r.Root, "scripts", "core", "server-manager.sh")
}

// EnvConfigPath mirrors get_game_env_config (server-utils.sh:46-50).
func (r *Repo) EnvConfigPath(game, env string) string {
	return filepath.Join(r.Root, "games", game, "environments", env+".json")
}

// PresetDir is where a game's presets live.
func (r *Repo) PresetDir(game string) string {
	return filepath.Join(r.Root, "games", game, "presets")
}

// StatePath is the file holding the active preset name for one server.
//
// Note the component order is game-env-instance, which differs from the
// container name's game-env-instance only by the separator context; it is
// written by <game>_save_active_preset and read by the automation scripts.
func (r *Repo) StatePath(game, instance, env string) string {
	return filepath.Join(r.Root, ".state", fmt.Sprintf("%s-%s-%s.preset", game, env, instance))
}

// Games lists the game directories present in the checkout, sorted.
// This matches how server-manager.sh discovers games (a listing of games/*/).
func (r *Repo) Games() ([]string, error) {
	entries, err := os.ReadDir(filepath.Join(r.Root, "games"))
	if err != nil {
		return nil, err
	}
	var games []string
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		// A directory only counts as a game if it has at least one env config.
		for _, env := range Environments {
			if _, err := os.Stat(r.EnvConfigPath(e.Name(), env)); err == nil {
				games = append(games, e.Name())
				break
			}
		}
	}
	sort.Strings(games)
	return games, nil
}

// EnvConfig is one games/<game>/environments/<env>.json file.
//
// Only the fields the TUI reads are modelled; unknown keys are ignored so that
// adding a key to the JSON never breaks the app.
type EnvConfig struct {
	Game          GameInfo                `json:"game"`
	NetworkConfig NetworkConfig           `json:"network_config"`
	DockerConfig  DockerConfig            `json:"docker_config"`
	BackupConfig  BackupConfig            `json:"backup_config"`
	Instances     map[string]InstanceInfo `json:"instances"`

	// ARK-only.
	ClusterConfig *ClusterConfig `json:"cluster_config,omitempty"`

	// Filled in by LoadEnvConfig, not present in the JSON.
	GameName string `json:"-"`
	Env      string `json:"-"`
}

type GameInfo struct {
	Name        string      `json:"name"`
	DockerImage string      `json:"docker_image"`
	HealthCheck HealthCheck `json:"health_check"`
}

// HealthCheck.Type varies per game and the checks are not equivalent — see
// HealthCheckDescription.
type HealthCheck struct {
	Type string `json:"type"`
}

type NetworkConfig struct {
	BasePorts             BasePorts `json:"base_ports"`
	PortOffsetPerInstance int       `json:"port_offset_per_instance"`
	PublicIP              string    `json:"public_ip"`
	Region                string    `json:"region"`
	RCONEnabled           bool      `json:"rcon_enabled"`
}

type BasePorts struct {
	Game    int `json:"game_port"`
	Query   int `json:"query_port"`
	RCON    int `json:"rcon_port"`
	RESTAPI int `json:"restapi_port"`
}

type DockerConfig struct {
	RestartPolicy string `json:"restart_policy"`
	MemoryLimit   string `json:"memory_limit"`
	CPULimit      string `json:"cpu_limit"`
}

type BackupConfig struct {
	Retention int    `json:"backup_retention"`
	Schedule  string `json:"backup_schedule"`
	Location  string `json:"backup_location"`
}

type ClusterConfig struct {
	ClusterID     string `json:"cluster_id"`
	ClusterVolume string `json:"cluster_volume"`
}

type InstanceInfo struct {
	Description   string `json:"description"`
	DefaultPreset string `json:"default_preset"`
	PortOffset    int    `json:"port_offset"`
	MaxPlayers    int    `json:"max_players"`

	// ARK-only.
	Map string `json:"map,omitempty"`
}

// LoadEnvConfig reads and decodes one environment config.
func (r *Repo) LoadEnvConfig(game, env string) (*EnvConfig, error) {
	if !ValidEnvironment(env) {
		return nil, fmt.Errorf("invalid environment %q: must be staging or production", env)
	}
	path := r.EnvConfigPath(game, env)
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading %s: %w", path, err)
	}
	var cfg EnvConfig
	if err := json.Unmarshal(raw, &cfg); err != nil {
		return nil, fmt.Errorf("parsing %s: %w", path, err)
	}
	cfg.GameName = game
	cfg.Env = env
	return &cfg, nil
}

// InstanceNames returns the configured instances for this environment, sorted.
func (c *EnvConfig) InstanceNames() []string {
	names := make([]string, 0, len(c.Instances))
	for name := range c.Instances {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

// Ports is a resolved port assignment for one instance.
//
// A base port of 0 means the game does not use that port at all: ARK has no
// REST API, and smalland and windrose have only a game port. The arithmetic
// still produces base+offset for those, which is a meaningless number, so the
// Has* predicates below report which values are real. Bash has no equivalent —
// get_port_assignments always echoes four numbers — so this is presentation
// only and does not change what gets passed to any script.
type Ports struct {
	Game    int
	Query   int
	RCON    int
	RESTAPI int

	// Bases records the configured base_ports, so a zero base stays
	// distinguishable from a computed port that happens to be low.
	Bases BasePorts
}

func (p Ports) HasQuery() bool   { return p.Bases.Query > 0 }
func (p Ports) HasRCON() bool    { return p.Bases.RCON > 0 }
func (p Ports) HasRESTAPI() bool { return p.Bases.RESTAPI > 0 }

// PortsFor mirrors get_port_assignments (server-utils.sh:280-316) exactly:
//
//	port = base + (instance.port_offset * network_config.port_offset_per_instance)
//
// An unknown instance resolves to offset 0, matching the jq `// 0` default.
func (c *EnvConfig) PortsFor(instance string) Ports {
	offset := 0
	if inst, ok := c.Instances[instance]; ok {
		offset = inst.PortOffset
	}
	// jq's `// 1` default: a missing multiplier means "add the raw offset".
	multiplier := c.NetworkConfig.PortOffsetPerInstance
	if multiplier == 0 {
		multiplier = 1
	}
	total := offset * multiplier
	b := c.NetworkConfig.BasePorts
	return Ports{
		Game:    b.Game + total,
		Query:   b.Query + total,
		RCON:    b.RCON + total,
		RESTAPI: b.RESTAPI + total,
		Bases:   b,
	}
}

// ContainerName mirrors get_container_name (server-utils.sh:186-201).
//
// Deliberately computed rather than read from naming_conventions.container_pattern:
// the bash ignores that pattern too, so following it would let the TUI drift from
// reality the moment someone edits the JSON.
func ContainerName(game, instance, env string) string {
	return fmt.Sprintf("%s-%s-%s", game, env, instance)
}

// VolumeName mirrors get_volume_name (server-utils.sh:168-183). Same caveat as
// ContainerName about naming_conventions.volume_pattern.
func VolumeName(game, instance, env string) string {
	return fmt.Sprintf("%s-vol-%s-%s", game, env, instance)
}

// BackupDir resolves backup_config.backup_location for an instance, relative to
// the repo root.
//
// Note this path contains no game segment, so instances of the same name in
// different games share a directory (all six games define a staging "test").
// Attribute archives via the .meta.json sidecar's game field, never the path.
func (r *Repo) BackupDir(c *EnvConfig, instance string) string {
	loc := c.BackupConfig.Location
	if loc == "" {
		loc = "./backups/" + c.Env + "/{instance}/"
	}
	loc = strings.ReplaceAll(loc, "{instance}", instance)
	loc = strings.TrimPrefix(loc, "./")
	return filepath.Join(r.Root, filepath.Clean(loc))
}

// ActivePreset reads .state/<game>-<env>-<instance>.preset.
//
// A missing file is not an error: it means no start or config-swap has recorded
// a preset yet. The caller gets "" and should display it as unknown.
func (r *Repo) ActivePreset(game, instance, env string) string {
	raw, err := os.ReadFile(r.StatePath(game, instance, env))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(raw))
}

// HealthCheckDescription explains what `health` actually verifies for a game, so
// the UI can avoid implying that every green result means the same thing.
func HealthCheckDescription(game, checkType string) string {
	switch game {
	case "ark":
		return "RCON ListPlayers"
	case "minecraft":
		return "docker mc-health (starting counts as pass)"
	case "palworld":
		return "REST API /v1/api/info (needs admin_password secret)"
	case "pixark":
		return "docker health"
	case "smalland", "windrose":
		return "container running only"
	}
	if checkType != "" {
		return checkType
	}
	return "unknown"
}

// HasNativeRestart reports whether a game implements <game>_restart_server.
// When it does not, server-manager.sh falls back to stop + sleep 5 + start
// (server-manager.sh:262-268), which is slower and re-runs the safety checklist.
func HasNativeRestart(game string) bool {
	switch game {
	case "ark", "minecraft", "palworld":
		return true
	}
	return false
}

// SupportsHotConfigSwap reports whether a config-swap can complete without
// restarting the container. Only ARK attempts this, and only when every changed
// key is in its hot-swappable allowlist; it silently falls back to a cold swap
// otherwise (games/ark/scripts/game-specific-logic.sh:384-441).
func SupportsHotConfigSwap(game string) bool {
	return game == "ark"
}
