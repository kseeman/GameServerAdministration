package config

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Preset is one games/<game>/presets/<name>.json file.
//
// Only metadata is modelled. The TUI never merges or applies presets — that is
// <game>_resolve_preset's job in bash — it only needs enough to let you pick one
// and understand where it came from.
type Preset struct {
	Name     string         `json:"-"` // filename without .json, i.e. what --preset takes
	Metadata PresetMetadata `json:"metadata"`
}

type PresetMetadata struct {
	Name        string `json:"name"`
	Description string `json:"description"`
	Version     string `json:"version"`
	Created     string `json:"created"`

	// Inherits is a *filename* ("default.json"), not a preset name, resolved
	// against the same game's presets directory. Merging is single-level:
	// parent game_settings overlaid with the child's overrides.
	Inherits string `json:"inherits"`
}

// InheritsPreset returns the parent preset's name (filename minus .json), or ""
// if this preset has no parent.
func (p Preset) InheritsPreset() string {
	return strings.TrimSuffix(p.Metadata.Inherits, ".json")
}

// Title is the human label for a preset, falling back to its filename.
func (p Preset) Title() string {
	if p.Metadata.Name != "" {
		return p.Metadata.Name
	}
	return p.Name
}

// Presets lists a game's presets, sorted by name.
//
// A preset file that fails to parse is skipped rather than failing the whole
// listing: one malformed file should not make the picker unusable.
func (r *Repo) Presets(game string) ([]Preset, error) {
	dir := r.PresetDir(game)
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var presets []Preset
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		p, err := r.LoadPreset(game, strings.TrimSuffix(e.Name(), ".json"))
		if err != nil {
			continue
		}
		presets = append(presets, *p)
	}
	sort.Slice(presets, func(i, j int) bool { return presets[i].Name < presets[j].Name })
	return presets, nil
}

// LoadPreset reads a single preset by name (no .json suffix).
func (r *Repo) LoadPreset(game, name string) (*Preset, error) {
	path := filepath.Join(r.PresetDir(game), name+".json")
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var p Preset
	if err := json.Unmarshal(raw, &p); err != nil {
		return nil, fmt.Errorf("parsing %s: %w", path, err)
	}
	p.Name = name
	return &p, nil
}

// PresetLineage returns the inheritance chain starting at name and walking up
// through metadata.inherits, e.g. ["boosted-pve", "default"].
//
// It stops on a missing parent and guards against a cycle, so a hand-edited
// preset that points at itself cannot hang the UI.
func (r *Repo) PresetLineage(game, name string) []string {
	var chain []string
	seen := map[string]bool{}
	for name != "" && !seen[name] {
		seen[name] = true
		chain = append(chain, name)
		p, err := r.LoadPreset(game, name)
		if err != nil {
			break
		}
		name = p.InheritsPreset()
	}
	return chain
}
