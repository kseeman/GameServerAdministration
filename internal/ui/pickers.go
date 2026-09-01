package ui

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/kseeman/GameServerAdministration/internal/backups"
	"github.com/kseeman/GameServerAdministration/internal/config"
	"github.com/kseeman/GameServerAdministration/internal/runner"
)

// openActions builds the action menu for the selected instance.
//
// Illegal actions stay visible but disabled with the reason attached, rather
// than disappearing — knowing why you cannot restore right now is more useful
// than the option silently not being there.
func (m Model) openActions() (tea.Model, tea.Cmd) {
	inst, ok := m.current()
	if !ok {
		return m, nil
	}
	running := inst.Running()

	type action struct {
		op       runner.Op
		title    string
		desc     string
		disabled bool
		reason   string
	}

	actions := []action{
		{op: runner.OpStart, title: "start", desc: "bring the server up",
			disabled: running, reason: "already running"},
		{op: runner.OpStop, title: "stop", desc: "bring the server down",
			disabled: !running, reason: "not running"},
		{op: runner.OpRestart, title: "restart", desc: restartLine(inst.Game),
			disabled: !running, reason: "not running"},
		{op: runner.OpConfigSwap, title: "config-swap", desc: swapLine(inst.Game)},
		{op: runner.OpBackup, title: "backup", desc: "capture save data"},
		{op: runner.OpRestore, title: "restore", desc: "replace world data from an archive",
			disabled: running, reason: "stop the server first"},
		{op: runner.OpHealth, title: "health", desc: config.HealthCheckDescription(inst.Game, healthType(inst))},
		{op: runner.OpStatus, title: "status", desc: "full status from server-manager.sh"},
		{op: runner.OpListBackups, title: "list-backups", desc: "as the CLI prints them"},
		{op: runner.OpValidate, title: "validate", desc: "check the game plugin"},
	}

	items := make([]pickerItem, 0, len(actions))
	for _, a := range actions {
		items = append(items, pickerItem{
			Title: a.title, Desc: a.desc,
			Disabled: a.disabled, Reason: a.reason,
			Value: a.op,
		})
	}

	m.pick = newPicker(
		fmt.Sprintf("Actions — %s / %s @ %s", inst.Game, inst.Name, inst.Env),
		items, m.height-4)
	m.pick.width = m.width
	m.prev = m.mode
	m.mode = modeActions
	return m, nil
}

// openPresets lists the game's presets, for either a config-swap or a start.
// op selects which: OpConfigSwap disables the already-active preset, OpStart
// prepends an "instance default" entry that sends no --preset at all.
func (m Model) openPresets(op runner.Op) (tea.Model, tea.Cmd) {
	inst, ok := m.current()
	if !ok {
		return m, nil
	}
	presets, err := m.repo.Presets(inst.Game)
	if err != nil {
		m.err = err
		return m, nil
	}

	items := make([]pickerItem, 0, len(presets)+1)

	if op == runner.OpStart {
		// An empty preset means server-manager.sh resolves the instance's
		// default_preset itself, which is the behaviour anyone who just hits
		// start expects. Listed first so it stays the zero-thought choice.
		def := inst.Info.DefaultPreset
		if def == "" {
			def = "default"
		}
		items = append(items, pickerItem{
			Title: "instance default",
			Desc:  styMuted.Render("start with " + def + ", as configured for this instance"),
			Value: "",
		})
	}

	for _, p := range presets {
		desc := p.Metadata.Description
		if parent := p.InheritsPreset(); parent != "" {
			desc += styMuted.Render(" · inherits " + parent)
		}
		item := pickerItem{Title: p.Name, Desc: desc, Value: p.Name}
		// Swapping to the preset already active is a no-op worth flagging.
		// On start there is nothing running, so nothing to exclude.
		if op == runner.OpConfigSwap && p.Name == inst.Preset {
			item.Disabled = true
			item.Reason = "already active"
		}
		items = append(items, item)
	}

	title := fmt.Sprintf("Config-swap — %s / %s @ %s (currently %s)",
		inst.Game, inst.Name, inst.Env, inst.DisplayPreset())
	if op == runner.OpStart {
		title = fmt.Sprintf("Start — %s / %s @ %s (preset)",
			inst.Game, inst.Name, inst.Env)
	}

	m.pick = newPicker(title, items, m.height-4)
	m.pick.width = m.width
	m.presetOp = op
	m.prev = m.mode
	m.mode = modePresets
	return m, nil
}

// openBackups lists archives that are safe to restore onto this instance.
//
// Filtering is on the sidecar's game field, never the filename: several games
// share backups/<env>/<instance>/ and restoring the wrong game's archive is a
// data-loss event.
func (m Model) openBackups() (tea.Model, tea.Cmd) {
	inst, ok := m.current()
	if !ok || inst.Cfg == nil {
		return m, nil
	}

	mine, err := backups.ListFor(m.repo, inst.Cfg, inst.Game, inst.Name)
	if err != nil {
		m.err = err
		return m, nil
	}
	all, _ := backups.List(m.repo, inst.Cfg, inst.Name)

	items := make([]pickerItem, 0, len(all))
	for _, b := range mine {
		when, fromMeta := b.When()
		stamp := when.Local().Format("2006-01-02 15:04")
		if !fromMeta {
			stamp += " (mtime)"
		}
		desc := fmt.Sprintf("%s · %s · %s", stamp, b.DisplayPreset(), b.HumanSize())
		if b.Meta.WorldID != "" {
			desc += " · world " + truncate(b.Meta.WorldID, 8)
		}
		items = append(items, pickerItem{Title: b.File, Desc: desc, Value: b.File})
	}

	// Show the archives we refused, so the omission is visible rather than
	// looking like the backups are missing.
	var foreign int
	for _, b := range all {
		if b.BelongsTo(inst.Game, inst.Name) && !b.IsCluster() {
			continue
		}
		foreign++
		reason := "no metadata — cannot confirm which game wrote it"
		if b.Attributed() {
			switch {
			case b.IsCluster():
				reason = "cluster archive — restore via ark-cluster-restore.sh"
			case b.Meta.Game != inst.Game:
				reason = "belongs to " + b.Meta.Game
			default:
				reason = "belongs to instance " + b.Meta.Instance
			}
		}
		items = append(items, pickerItem{
			Title: b.File, Disabled: true, Reason: reason,
		})
	}

	title := fmt.Sprintf("Restore — %s / %s @ %s", inst.Game, inst.Name, inst.Env)
	if foreign > 0 {
		title += fmt.Sprintf("  (%d archive(s) in this directory belong elsewhere)", foreign)
	}

	m.pick = newPicker(title, items, m.height-4)
	m.pick.width = m.width
	m.prev = m.mode
	m.mode = modeBackups
	return m, nil
}

func (m Model) updatePicker(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	selected, cancelled := m.pick.update(msg)
	if cancelled {
		m.mode = modeDashboard
		return m, nil
	}
	if selected == nil {
		return m, nil
	}

	inst, ok := m.current()
	if !ok {
		m.mode = modeDashboard
		return m, nil
	}

	switch m.mode {
	case modeActions:
		op := selected.Value.(runner.Op)
		switch op {
		case runner.OpConfigSwap:
			return m.openPresets(runner.OpConfigSwap)
		case runner.OpStart:
			return m.openPresets(runner.OpStart)
		case runner.OpRestore:
			return m.openBackups()
		default:
			m.mode = modeDashboard
			return m.begin(op)
		}

	case modePresets:
		op := m.presetOp
		if op == "" {
			op = runner.OpConfigSwap
		}
		req := runner.Request{
			Op:       op,
			Game:     inst.Game,
			Instance: inst.Name,
			Env:      inst.Env,
			Preset:   selected.Value.(string),
		}
		m.pending = req
		m.confirm = newConfirm(m.repo, req, inst)
		m.prev = modeDashboard
		m.mode = modeConfirm
		return m, nil

	case modeBackups:
		req := runner.Request{
			Op:       runner.OpRestore,
			Game:     inst.Game,
			Instance: inst.Name,
			Env:      inst.Env,
			Backup:   selected.Value.(string),
		}
		m.pending = req
		m.confirm = newConfirm(m.repo, req, inst)
		m.prev = modeDashboard
		m.mode = modeConfirm
		return m, nil
	}

	return m, nil
}

func (m Model) viewPicker() string {
	var b strings.Builder
	b.WriteString(m.statusLine() + "\n\n")
	b.WriteString(m.pick.view())
	return b.String()
}
