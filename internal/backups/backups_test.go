package backups

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/kseeman/GameServerAdministration/internal/config"
)

// writeBackup creates an archive and, when meta is non-nil, its sidecar.
func writeBackup(t *testing.T, dir, name string, meta *Meta) {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, name+".tar.gz"), []byte("archive"), 0o644); err != nil {
		t.Fatal(err)
	}
	if meta == nil {
		return
	}
	raw, err := json.Marshal(meta)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, name+".meta.json"), raw, 0o644); err != nil {
		t.Fatal(err)
	}
}

// fakeRepo builds a throwaway checkout with just enough structure for
// config.NewRepo to accept it.
func fakeRepo(t *testing.T) *config.Repo {
	t.Helper()
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "games"), 0o755); err != nil {
		t.Fatal(err)
	}
	smDir := filepath.Join(root, "scripts", "core")
	if err := os.MkdirAll(smDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(smDir, "server-manager.sh"), []byte("#!/bin/bash\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	repo, err := config.NewRepo(root)
	if err != nil {
		t.Fatal(err)
	}
	return repo
}

func stagingCfg(env string) *config.EnvConfig {
	return &config.EnvConfig{
		Env:          env,
		BackupConfig: config.BackupConfig{Location: "./backups/" + env + "/{instance}/"},
	}
}

// TestCrossGameFiltering is the reason this package exists: several games write
// into backups/<env>/test/, and offering the wrong one for restore destroys a
// world.
func TestCrossGameFiltering(t *testing.T) {
	repo := fakeRepo(t)
	cfg := stagingCfg("staging")
	dir := repo.BackupDir(cfg, "test")

	writeBackup(t, dir, "casual_test_staging_20260402_111605", &Meta{
		Game: "palworld", Instance: "test", Environment: "staging",
		Preset: "casual", WorldID: "453E8606", Timestamp: "2026-04-02T16:16:08Z",
	})
	writeBackup(t, dir, "pre-swap_boosted_20260403_124143", &Meta{
		Game: "ark", Instance: "test", Environment: "staging",
		Preset: "boosted", Map: "TheIsland_WP", Timestamp: "2026-04-03T12:41:43Z",
	})
	writeBackup(t, dir, "legacy_test_staging_20260401", nil) // no sidecar

	all, err := List(repo, cfg, "test")
	if err != nil {
		t.Fatal(err)
	}
	if len(all) != 3 {
		t.Fatalf("List returned %d archives, want 3", len(all))
	}

	pal, err := ListFor(repo, cfg, "palworld", "test")
	if err != nil {
		t.Fatal(err)
	}
	if len(pal) != 1 {
		t.Fatalf("palworld got %d archives, want 1: %+v", len(pal), pal)
	}
	if pal[0].Meta.Preset != "casual" {
		t.Errorf("palworld got preset %q, want casual", pal[0].Meta.Preset)
	}

	ark, err := ListFor(repo, cfg, "ark", "test")
	if err != nil {
		t.Fatal(err)
	}
	if len(ark) != 1 {
		t.Fatalf("ark got %d archives, want 1", len(ark))
	}
	if ark[0].Meta.Map != "TheIsland_WP" {
		t.Errorf("ark archive lost its map field: %+v", ark[0].Meta)
	}

	// A game with no archives here must get nothing, not the others'.
	mc, err := ListFor(repo, cfg, "minecraft", "test")
	if err != nil {
		t.Fatal(err)
	}
	if len(mc) != 0 {
		t.Errorf("minecraft got %d archives, want 0: %+v", len(mc), mc)
	}
}

func TestUnattributedNeverOffered(t *testing.T) {
	b := Backup{File: "legacy_main_staging_20260403.tar.gz"}
	if b.Attributed() {
		t.Error("archive without a sidecar reported as attributed")
	}
	for _, game := range []string{"palworld", "ark", ""} {
		if b.BelongsTo(game, "main") {
			t.Errorf("unattributed archive claimed to belong to %q", game)
		}
	}
}

func TestInstanceMismatchRejected(t *testing.T) {
	b := Backup{HasMeta: true, Meta: Meta{Game: "palworld", Instance: "main"}}
	if b.BelongsTo("palworld", "tournament") {
		t.Error("archive from instance main offered for instance tournament")
	}
	if !b.BelongsTo("palworld", "main") {
		t.Error("archive from instance main rejected for instance main")
	}
}

func TestClusterArchivesExcludedFromInstanceRestore(t *testing.T) {
	repo := fakeRepo(t)
	cfg := stagingCfg("staging")
	dir := repo.BackupDir(cfg, "island")
	writeBackup(t, dir, "cluster_staging_20260404_010101", &Meta{
		Game: "ark", Instance: "island", Scope: "cluster", Timestamp: "2026-04-04T01:01:01Z",
	})
	got, err := ListFor(repo, cfg, "ark", "island")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 0 {
		t.Errorf("cluster-scope archive offered for a per-instance restore: %+v", got)
	}
}

func TestSortedNewestFirst(t *testing.T) {
	repo := fakeRepo(t)
	cfg := stagingCfg("staging")
	dir := repo.BackupDir(cfg, "main")
	writeBackup(t, dir, "old", &Meta{Game: "palworld", Instance: "main", Timestamp: "2026-04-01T00:00:00Z"})
	writeBackup(t, dir, "new", &Meta{Game: "palworld", Instance: "main", Timestamp: "2026-04-05T00:00:00Z"})
	writeBackup(t, dir, "mid", &Meta{Game: "palworld", Instance: "main", Timestamp: "2026-04-03T00:00:00Z"})

	got, err := ListFor(repo, cfg, "palworld", "main")
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"new.tar.gz", "mid.tar.gz", "old.tar.gz"}
	for i, w := range want {
		if got[i].File != w {
			t.Errorf("position %d = %s, want %s", i, got[i].File, w)
		}
	}
}

// The sidecar timestamp is UTC while the filename's is local; When() must
// prefer the sidecar and say so.
func TestWhenPrefersSidecar(t *testing.T) {
	b := Backup{
		ModTime: time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC),
		HasMeta: true,
		Meta:    Meta{Timestamp: "2026-04-02T16:16:08Z"},
	}
	got, fromMeta := b.When()
	if !fromMeta {
		t.Fatal("When did not report the sidecar as its source")
	}
	if got.Year() != 2026 || got.Month() != time.April {
		t.Errorf("When = %v, want the sidecar's 2026-04-02", got)
	}

	noMeta := Backup{ModTime: time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC)}
	if _, fromMeta := noMeta.When(); fromMeta {
		t.Error("When claimed a sidecar source with no sidecar")
	}
}

func TestMissingDirectoryIsNotAnError(t *testing.T) {
	repo := fakeRepo(t)
	got, err := List(repo, stagingCfg("staging"), "never-backed-up")
	if err != nil {
		t.Fatalf("missing backup dir returned an error: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("got %d archives from a nonexistent directory", len(got))
	}
}
