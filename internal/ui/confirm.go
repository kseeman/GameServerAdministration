package ui

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"

	"github.com/kseeman/GameServerAdministration/internal/backups"
	"github.com/kseeman/GameServerAdministration/internal/config"
	"github.com/kseeman/GameServerAdministration/internal/inventory"
	"github.com/kseeman/GameServerAdministration/internal/runner"
)

// confirmModel gates a mutating operation.
//
// The TUI passes --force to server-manager.sh, which skips the script's own
// safety_confirmation() prompt. This modal is what replaces it, so it has to be
// at least as hard to get through: the bash prompt requires typing
// "<game>-<instance>", and so does this one for anything destructive.
type confirmModel struct {
	req   runner.Request
	inst  inventory.Instance
	lines []string

	// typed is set when the operation demands the instance name be typed out.
	typed  bool
	phrase string
	input  textinput.Model

	// A production mutation that is not destructive still needs a deliberate
	// second keypress rather than a bare y.
	strictKey bool

	warnings []string
}

func newConfirm(repo *config.Repo, req runner.Request, inst inventory.Instance) confirmModel {
	c := confirmModel{req: req, inst: inst}
	c.phrase = fmt.Sprintf("%s-%s", req.Game, req.Instance)

	prod := req.Env == config.EnvProduction
	c.typed = req.Op.Destructive()
	c.strictKey = prod

	if c.typed {
		ti := textinput.New()
		ti.Prompt = "> "
		ti.Placeholder = c.phrase
		ti.Focus()
		c.input = ti
	}

	c.lines = describeOperation(repo, req, inst)
	c.warnings = collectWarnings(repo, req, inst)
	return c
}

// describeOperation states plainly what is about to happen.
func describeOperation(repo *config.Repo, req runner.Request, inst inventory.Instance) []string {
	target := fmt.Sprintf("%s / %s @ %s", req.Game, req.Instance, req.Env)
	lines := []string{target}

	switch req.Op {
	case runner.OpStart:
		if req.Preset != "" {
			lines = append(lines, "start with preset "+req.Preset)
		} else {
			// No --preset is sent, so server-manager.sh resolves the instance's
			// default_preset. Name it, rather than leaving the operator to guess
			// which settings the server is about to come up on.
			def := inst.Info.DefaultPreset
			if def == "" {
				def = "default"
			}
			lines = append(lines, "start with preset "+def+" (this instance's default)")
		}

	case runner.OpStop:
		lines = append(lines, "stop the container")

	case runner.OpRestart:
		if config.HasNativeRestart(req.Game) {
			lines = append(lines, "restart the container")
		} else {
			lines = append(lines, "restart — this game has no native restart, so it stops, waits 5s, then starts")
		}

	case runner.OpBackup:
		lines = append(lines, "back up save data")

	case runner.OpConfigSwap:
		from := inst.DisplayPreset()
		lines = append(lines, fmt.Sprintf("config-swap %s → %s", from, req.Preset))
		if config.SupportsHotConfigSwap(req.Game) {
			lines = append(lines,
				"ARK tries a hot swap first. If any changed setting is outside its",
				"hot-swappable allowlist it falls back to a cold swap, which restarts",
				"the server and takes a pre-swap backup.")
		} else {
			lines = append(lines, "this is a cold swap: the server stops and restarts")
		}

	case runner.OpRestore:
		lines = append(lines, "restore from "+req.Backup)
		if b := findBackup(repo, inst, req.Backup); b != nil {
			when, _ := b.When()
			lines = append(lines,
				fmt.Sprintf("archive: %s / %s, preset %s, %s",
					b.Meta.Game, b.Meta.Instance, b.DisplayPreset(), when.Local().Format("2006-01-02 15:04")))
			if b.Meta.WorldID != "" {
				lines = append(lines, "world ID: "+b.Meta.WorldID)
			}
			if b.Meta.Map != "" {
				lines = append(lines, "map: "+b.Meta.Map)
			}
		}
	}
	return lines
}

func findBackup(repo *config.Repo, inst inventory.Instance, file string) *backups.Backup {
	if inst.Cfg == nil {
		return nil
	}
	list, err := backups.ListFor(repo, inst.Cfg, inst.Game, inst.Name)
	if err != nil {
		return nil
	}
	for i := range list {
		if list[i].File == file {
			return &list[i]
		}
	}
	return nil
}

// collectWarnings surfaces things worth knowing before committing.
func collectWarnings(repo *config.Repo, req runner.Request, inst inventory.Instance) []string {
	var w []string

	if req.Op.Destructive() {
		w = append(w, "This replaces the world data wholesale. SaveGames/ and Config/ are "+
			"deleted before the archive is unpacked; anything since that backup is gone.")
		if inst.Running() {
			w = append(w, "The container is running. Restore requires it stopped and will fail otherwise.")
		}
	}

	if req.Env == config.EnvProduction {
		w = append(w, "This is production.")
	}

	if req.Op == runner.OpConfigSwap && inst.Preset == "" {
		w = append(w, "No active preset is recorded, so the swap cannot be diffed and "+
			"will take the cold path.")
	}

	if req.Op == runner.OpStart && inst.Running() {
		w = append(w, "The container is already running; the safety checklist will refuse this.")
	}

	if req.Op == runner.OpStop && !inst.Running() {
		w = append(w, "The container is not running; this will be a no-op.")
	}

	// Cron can act on the same instance at any moment and gsa cannot stop it.
	for _, l := range readCron() {
		if strings.Contains(l, "scheduled-config-swap") && strings.Contains(l, "--env "+req.Env) {
			w = append(w, "A scheduled config-swap is installed in cron for this environment.")
			break
		}
	}

	return w
}

func (m Model) updateConfirm(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	c := &m.confirm

	switch msg.String() {
	case "esc", "ctrl+c":
		m.mode = m.prev
		return m, nil
	}

	if c.typed {
		switch msg.Type {
		case tea.KeyEnter:
			if strings.TrimSpace(c.input.Value()) == c.phrase {
				cmd := (&m).launch(m.pending)
				return m, cmd
			}
			// Wrong phrase: clear it rather than letting a near-miss sit there
			// looking like it might be accepted.
			c.input.SetValue("")
			return m, nil
		default:
			var cmd tea.Cmd
			c.input, cmd = c.input.Update(msg)
			return m, cmd
		}
	}

	// Production requires an unambiguous capital Y; staging accepts y.
	want := "y"
	if c.strictKey {
		want = "Y"
	}
	if msg.String() == want {
		cmd := (&m).launch(m.pending)
		return m, cmd
	}
	if msg.String() == "n" || msg.String() == "q" {
		m.mode = m.prev
	}
	return m, nil
}

func (m Model) viewConfirm() string {
	c := m.confirm

	var b strings.Builder
	b.WriteString(m.statusLine() + "\n\n")

	style := styBox
	title := "Confirm"
	if c.req.Op.Destructive() || c.req.Env == config.EnvProduction {
		style = styDanger
		title = "Confirm — " + strings.ToUpper(c.req.Env)
	}

	var inner strings.Builder
	inner.WriteString(styTitle.Render(title) + "\n\n")
	for i, l := range c.lines {
		if i == 0 {
			inner.WriteString(envStyle(c.req.Env).Render(l) + "\n")
			continue
		}
		inner.WriteString(l + "\n")
	}

	if m.dryRun {
		inner.WriteString("\n" + styWarn.Render("DRY-RUN: --dry-run is passed; nothing will actually change.") + "\n")
	}

	if len(c.warnings) > 0 {
		inner.WriteString("\n")
		for _, w := range c.warnings {
			inner.WriteString(styWarn.Render("! ") + w + "\n")
		}
	}

	inner.WriteString("\n" + styMuted.Render("$ "+c.req.Describe("scripts/core/server-manager.sh")) + "\n")

	inner.WriteString("\n")
	switch {
	case c.typed:
		inner.WriteString(fmt.Sprintf("Type %s to confirm:\n", styErr.Render(c.phrase)))
		inner.WriteString(c.input.View() + "\n\n")
		inner.WriteString(styHelp.Render("enter confirm · esc cancel"))
	case c.strictKey:
		inner.WriteString(styHelp.Render("press " + styErr.Render("Y") + " (capital) to confirm · n or esc to cancel"))
	default:
		inner.WriteString(styHelp.Render("y confirm · n or esc cancel"))
	}

	b.WriteString(style.Width(minInt(m.width-2, 96)).Render(inner.String()))
	return b.String()
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}
