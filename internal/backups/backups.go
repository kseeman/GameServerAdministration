// Package backups reads the backup archives on disk and their .meta.json
// sidecars.
//
// The important constraint: backup directories are backups/<env>/<instance>/
// with no game segment, and archive filenames contain no game either. All six
// games define a staging instance named "test", so a single directory holds
// archives from several games side by side. The sidecar's "game" field is the
// only reliable attribution, so that is what this package filters on — never
// the filename.
package backups

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/kseeman/GameServerAdministration/internal/config"
)

// Meta is a .meta.json sidecar.
//
// Fields vary by game — Palworld writes world_id, ARK writes map, Minecraft
// omits preset_location — so everything optional is a pointer-free zero value
// and callers check for emptiness.
type Meta struct {
	Game        string `json:"game"`
	Instance    string `json:"instance"`
	Environment string `json:"environment"`
	WorldID     string `json:"world_id"`
	Map         string `json:"map"`
	Preset      string `json:"active_preset"`
	BackupName  string `json:"backup_name"`

	// Timestamp is UTC ISO-8601 with a Z suffix, unlike the local-time stamp
	// embedded in the filename. Always display this one.
	Timestamp string `json:"timestamp"`

	Container string `json:"container_name"`
	Volume    string `json:"volume_name"`
	Method    string `json:"backup_method"`

	// Scope is "cluster" for ARK's per-environment cluster archives, which have
	// a different shape entirely and are not per-instance restores.
	Scope string `json:"scope"`
}

// Backup is one archive plus whatever metadata could be attributed to it.
type Backup struct {
	Path    string // absolute path to the .tar.gz
	File    string // basename; server-manager.sh --backup accepts this alone
	Size    int64
	ModTime time.Time
	Meta    Meta
	HasMeta bool
}

// Attributed reports whether this archive can be tied to a specific game.
// Legacy archives predate the sidecars and cannot be.
func (b Backup) Attributed() bool { return b.HasMeta && b.Meta.Game != "" }

// BelongsTo reports whether the archive is safe to restore onto the given
// game and instance.
//
// Unattributed archives return false: the whole point of the check is that
// restoring an ARK archive onto a Palworld volume is a data-loss event, and a
// one-keypress UI must not offer it as if it were fine.
func (b Backup) BelongsTo(game, instance string) bool {
	if !b.Attributed() {
		return false
	}
	if !strings.EqualFold(b.Meta.Game, game) {
		return false
	}
	// The sidecar records its instance too; when present it must agree.
	if b.Meta.Instance != "" && b.Meta.Instance != instance {
		return false
	}
	return true
}

// IsCluster reports whether this is an ARK cluster-scope archive rather than a
// per-instance one. Those restore through scripts/automation/ark-cluster-restore.sh,
// not through server-manager.sh restore.
func (b Backup) IsCluster() bool { return b.Meta.Scope == "cluster" }

// When returns the sidecar's UTC timestamp, falling back to the file mtime.
// The second return reports whether the value came from the sidecar.
func (b Backup) When() (time.Time, bool) {
	if b.Meta.Timestamp != "" {
		if t, err := time.Parse(time.RFC3339, b.Meta.Timestamp); err == nil {
			return t, true
		}
	}
	return b.ModTime, false
}

// DisplayPreset is the preset the archive was taken under.
func (b Backup) DisplayPreset() string {
	if b.Meta.Preset != "" {
		return b.Meta.Preset
	}
	return "unknown"
}

// HumanSize renders Size compactly.
func (b Backup) HumanSize() string {
	const unit = 1024
	if b.Size < unit {
		return fmt.Sprintf("%dB", b.Size)
	}
	div, exp := int64(unit), 0
	for n := b.Size / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f%cB", float64(b.Size)/float64(div), "KMGTPE"[exp])
}

// List returns every archive in an instance's backup directory, newest first,
// regardless of which game produced it. Callers that intend to restore must
// filter with ListFor.
func List(repo *config.Repo, cfg *config.EnvConfig, instance string) ([]Backup, error) {
	return listDir(repo.BackupDir(cfg, instance))
}

// ListFor returns only the archives that belong to the given game and instance,
// newest first. This is what the restore picker uses.
func ListFor(repo *config.Repo, cfg *config.EnvConfig, game, instance string) ([]Backup, error) {
	all, err := List(repo, cfg, instance)
	if err != nil {
		return nil, err
	}
	var out []Backup
	for _, b := range all {
		if b.BelongsTo(game, instance) && !b.IsCluster() {
			out = append(out, b)
		}
	}
	return out, nil
}

// ListCluster returns the ARK per-environment cluster archives for an
// environment, newest first. These live in backups/<env>/_cluster/.
func ListCluster(repo *config.Repo, env string) ([]Backup, error) {
	return listDir(filepath.Join(repo.Root, "backups", env, "_cluster"))
}

// ListEmergency returns the full-volume archives create_emergency_backup writes
// before config swaps. They have no sidecars at all.
func ListEmergency(repo *config.Repo) ([]Backup, error) {
	return listDir(filepath.Join(repo.Root, "backups", "emergency"))
}

func listDir(dir string) ([]Backup, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil // no backups yet is not an error
		}
		return nil, err
	}

	var out []Backup
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".tar.gz") {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		b := Backup{
			Path:    filepath.Join(dir, e.Name()),
			File:    e.Name(),
			Size:    info.Size(),
			ModTime: info.ModTime(),
		}
		// The sidecar sits alongside the archive with .tar.gz swapped for
		// .meta.json.
		metaPath := strings.TrimSuffix(b.Path, ".tar.gz") + ".meta.json"
		if raw, err := os.ReadFile(metaPath); err == nil {
			if err := json.Unmarshal(raw, &b.Meta); err == nil {
				b.HasMeta = true
			}
		}
		out = append(out, b)
	}

	sort.Slice(out, func(i, j int) bool {
		ti, _ := out[i].When()
		tj, _ := out[j].When()
		if ti.Equal(tj) {
			return out[i].File > out[j].File
		}
		return ti.After(tj)
	})
	return out, nil
}

// Latest returns the most recent attributed backup for a game and instance, or
// nil when there is none.
func Latest(repo *config.Repo, cfg *config.EnvConfig, game, instance string) *Backup {
	list, err := ListFor(repo, cfg, game, instance)
	if err != nil || len(list) == 0 {
		return nil
	}
	return &list[0]
}
