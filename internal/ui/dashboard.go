package ui

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/kseeman/GameServerAdministration/internal/config"
	"github.com/kseeman/GameServerAdministration/internal/inventory"
	"github.com/kseeman/GameServerAdministration/internal/runner"
)

func (m Model) updateDashboard(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "q":
		return m, tea.Quit

	case "up", "k":
		if m.cursor > 0 {
			m.cursor--
		}
	case "down", "j":
		if m.cursor < len(m.rows)-1 {
			m.cursor++
		}
	case "home", "g":
		m.cursor = 0
	case "end", "G":
		m.cursor = len(m.rows) - 1
	case "pgup":
		m.cursor -= 10
		if m.cursor < 0 {
			m.cursor = 0
		}
	case "pgdown":
		m.cursor += 10
		if m.cursor > len(m.rows)-1 {
			m.cursor = len(m.rows) - 1
		}

	case "r":
		return m, m.loadSnapshot()

	case "/":
		m.prev = modeDashboard
		m.mode = modeFilter
		m.filterIn.SetValue(m.filter)
		m.filterIn.Focus()
		m.filterIn.CursorEnd()
		return m, nil

	case "e":
		// Cycle all -> staging -> production.
		switch m.envFilter {
		case "":
			m.envFilter = config.EnvStaging
		case config.EnvStaging:
			m.envFilter = config.EnvProduction
		default:
			m.envFilter = ""
		}
		m.applyFilter()

	case "d":
		m.dryRun = !m.dryRun

	case "enter", "l", "right":
		if _, ok := m.current(); ok {
			m.mode = modeDetail
		}

	case "a":
		if _, ok := m.current(); ok {
			return m.openActions()
		}

	// Direct-action shortcuts. Each still routes through the confirm modal.
	// "s" stays the fast path: start on the instance's configured
	// default_preset, no picker. Choosing a specific preset is done from the
	// actions menu (enter), which routes start through openPresets.
	case "s":
		return m.begin(runner.OpStart)
	case "x":
		return m.begin(runner.OpStop)
	case "R":
		return m.begin(runner.OpRestart)
	case "c":
		return m.openPresets(runner.OpConfigSwap)
	case "b":
		return m.begin(runner.OpBackup)
	case "S":
		return m.begin(runner.OpRestore)
	case "h":
		return m.begin(runner.OpHealth)
	case "v":
		return m.begin(runner.OpValidate)

	case "?":
		m.prev = m.mode
		m.mode = modeDetail
	}
	return m, nil
}

// begin routes an operation towards either a confirm modal (mutations) or
// straight to execution (reads).
func (m Model) begin(op runner.Op) (tea.Model, tea.Cmd) {
	inst, ok := m.current()
	if !ok {
		return m, nil
	}

	req := runner.Request{
		Op:       op,
		Game:     inst.Game,
		Instance: inst.Name,
		Env:      inst.Env,
	}

	// Restore needs a backup chosen first.
	if op == runner.OpRestore {
		return m.openBackups()
	}
	// Start uses the recorded preset if there is one; otherwise the instance
	// default. Passing neither would let the plugin pick, but being explicit
	// makes the confirmation honest about what will run.
	if op == runner.OpStart {
		req.Preset = inst.Preset
		if req.Preset == "" {
			req.Preset = inst.Default
		}
	}

	if err := req.Validate(); err != nil {
		m.err = err
		return m, nil
	}

	if !op.Mutating() {
		cmd := (&m).launch(req)
		return m, cmd
	}

	m.pending = req
	m.confirm = newConfirm(m.repo, req, inst)
	m.prev = m.mode
	m.mode = modeConfirm
	return m, nil
}

// --- rendering --------------------------------------------------------------

type column struct {
	title string
	width int
}

func (m Model) dashboardColumns() []column {
	// Widths are tuned for an 80-column terminal and grow the instance column
	// when there is room.
	cols := []column{
		{"", 1},          // status dot
		{"GAME", 10},     //
		{"INSTANCE", 16}, //
		{"ENV", 10},      //
		{"PRESET", 14},   //
		{"PORTS", 13},    //
		{"UPTIME", 14},   //
	}
	used := 0
	for _, c := range cols {
		used += c.width + 1
	}
	if extra := m.width - used - 2; extra > 0 {
		grow := extra
		if grow > 20 {
			grow = 20
		}
		cols[2].width += grow
	}
	return cols
}

func (m Model) viewDashboard() string {
	var b strings.Builder
	b.WriteString(m.statusLine() + "\n\n")

	if m.err != nil {
		b.WriteString(styErr.Render("error: "+m.err.Error()) + "\n\n")
	}
	if m.snap != nil && !m.snap.DockerOK {
		b.WriteString(styWarn.Render("Docker is not reachable — every instance below reads as absent, "+
			"which means unknown, not stopped.") + "\n\n")
	}

	cols := m.dashboardColumns()

	var head strings.Builder
	for _, c := range cols {
		head.WriteString(pad(c.title, c.width) + " ")
	}
	b.WriteString(styHeader.Render(head.String()) + "\n")

	if len(m.rows) == 0 {
		b.WriteString(styMuted.Render("  no instances match") + "\n")
	}

	// Keep the selection visible in a viewport-sized window.
	visible := m.height - 8
	if visible < 3 {
		visible = 3
	}
	start := 0
	if m.cursor >= visible {
		start = m.cursor - visible + 1
	}
	end := start + visible
	if end > len(m.rows) {
		end = len(m.rows)
	}

	for i := start; i < end; i++ {
		b.WriteString(m.renderRow(m.rows[i], i == m.cursor, cols) + "\n")
	}

	if len(m.rows) > visible {
		b.WriteString(styMuted.Render(fmt.Sprintf("  %d/%d", m.cursor+1, len(m.rows))) + "\n")
	}

	b.WriteString("\n" + m.dashboardHelp())
	return b.String()
}

func (m Model) renderRow(inst inventory.Instance, selected bool, cols []column) string {
	// smalland and windrose configure no RCON port at all, so base+offset there
	// would render a number that does not exist.
	ports := fmt.Sprintf("%d", inst.Ports.Game)
	if inst.Ports.HasRCON() {
		ports += fmt.Sprintf("/%d", inst.Ports.RCON)
	}

	uptime := ""
	switch inst.Status() {
	case inventory.StatusRunning, inventory.StatusStarting, inventory.StatusUnhealthy:
		uptime = inst.Docker.Uptime()
		if h := inst.Docker.Health(); h != "" && h != "healthy" {
			uptime += " (" + h + ")"
		}
	case inventory.StatusStopped:
		uptime = styMuted.Render("stopped")
	default:
		uptime = styMuted.Render("—")
	}

	preset := inst.DisplayPreset()
	if inst.Preset == "" {
		preset = styMuted.Render(preset)
	}

	env := inst.Env
	if selected {
		// Selection styling would fight per-cell colour, so render plain.
		cells := []string{
			" ",
			pad(inst.Game, cols[1].width),
			pad(inst.Name, cols[2].width),
			pad(env, cols[3].width),
			pad(inst.DisplayPreset(), cols[4].width),
			pad(ports, cols[5].width),
			pad(stripAnsi(uptime), cols[6].width),
		}
		line := statusDot(inst.Status()) + " " + stySelected.Render(strings.Join(cells[1:], " "))
		return line
	}

	var b strings.Builder
	b.WriteString(statusDot(inst.Status()) + " ")
	b.WriteString(pad(inst.Game, cols[1].width) + " ")
	b.WriteString(pad(inst.Name, cols[2].width) + " ")
	b.WriteString(envStyle(env).Render(pad(env, cols[3].width)) + " ")
	b.WriteString(padStyled(preset, cols[4].width) + " ")
	b.WriteString(pad(ports, cols[5].width) + " ")
	b.WriteString(padStyled(uptime, cols[6].width))
	return b.String()
}

func (m Model) dashboardHelp() string {
	lines := []string{
		"↑/↓ move · enter detail · a actions · / filter · e env · r refresh · q quit",
		"s start · x stop · R restart · c config-swap · b backup · S restore · h health · d dry-run",
	}
	return styHelp.Render(strings.Join(lines, "\n"))
}
