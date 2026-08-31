package ui

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/kseeman/GameServerAdministration/internal/backups"
	"github.com/kseeman/GameServerAdministration/internal/config"
	"github.com/kseeman/GameServerAdministration/internal/inventory"
)

func (m Model) updateDetail(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "esc", "q", "left", "h":
		m.mode = modeDashboard
		return m, nil
	case "a":
		return m.openActions()
	case "u":
		// Volume size is opt-in: it starts a throwaway container per volume,
		// which is far too slow to run for the whole fleet on a refresh tick.
		if inst, ok := m.current(); ok {
			return m, m.fetchVolumeSize(inst.Volume)
		}
	case "up", "k":
		if m.cursor > 0 {
			m.cursor--
		}
	case "down", "j":
		if m.cursor < len(m.rows)-1 {
			m.cursor++
		}
	}
	return m, nil
}

func (m Model) fetchVolumeSize(volume string) tea.Cmd {
	return func() tea.Msg {
		size, err := m.docker.VolumeSize(volume)
		return volSizeMsg{volume: volume, size: size, err: err}
	}
}

func (m Model) viewDetail() string {
	inst, ok := m.current()
	if !ok {
		return m.statusLine() + "\n\nnothing selected"
	}

	var b strings.Builder
	b.WriteString(m.statusLine() + "\n\n")

	title := fmt.Sprintf("%s / %s", inst.Game, inst.Name)
	b.WriteString(styTitle.Render(title) + "  " + envStyle(inst.Env).Render(inst.Env) + "\n")
	if inst.Info.Description != "" {
		b.WriteString(styMuted.Render(inst.Info.Description) + "\n")
	}
	b.WriteString("\n")

	rows := [][2]string{
		{"Status", statusDot(inst.Status()) + " " + inst.Status().String()},
		{"Container", inst.Container()},
		{"Volume", m.volumeLine(inst)},
	}

	if inst.Running() {
		rows = append(rows, [2]string{"Uptime", inst.Docker.Uptime()})
		if h := inst.Docker.Health(); h != "" {
			rows = append(rows, [2]string{"Docker health", h})
		}
	}
	if inst.Info.Map != "" {
		rows = append(rows, [2]string{"Map", inst.Info.Map})
	}

	rows = append(rows,
		[2]string{"Active preset", m.presetLine(inst)},
		[2]string{"Default preset", inst.Default},
		[2]string{"Ports", m.portsLine(inst)},
		[2]string{"Max players", fmt.Sprintf("%d", inst.Info.MaxPlayers)},
	)

	if inst.Cfg != nil {
		d := inst.Cfg.DockerConfig
		rows = append(rows,
			[2]string{"Limits", fmt.Sprintf("mem %s · cpu %s · restart %s", d.MemoryLimit, d.CPULimit, d.RestartPolicy)},
			[2]string{"Backup schedule", scheduleLine(inst.Cfg.BackupConfig)},
		)
		if inst.Cfg.ClusterConfig != nil && inst.Cfg.ClusterConfig.ClusterID != "" {
			rows = append(rows, [2]string{"Cluster", inst.Cfg.ClusterConfig.ClusterID})
		}
	}

	rows = append(rows,
		[2]string{"Last backup", m.lastBackupLine(inst)},
		[2]string{"Health check", config.HealthCheckDescription(inst.Game, healthType(inst))},
		[2]string{"Config swap", swapLine(inst.Game)},
		[2]string{"Restart", restartLine(inst.Game)},
	)

	labelWidth := 0
	for _, r := range rows {
		if len(r[0]) > labelWidth {
			labelWidth = len(r[0])
		}
	}
	for _, r := range rows {
		b.WriteString(styMuted.Render(pad(r[0], labelWidth)) + "  " + r[1] + "\n")
	}

	if lines := m.cronFor(inst); len(lines) > 0 {
		b.WriteString("\n" + styHeader.Render("Scheduled jobs") + "\n")
		b.WriteString(styMuted.Render("cron runs these independently of gsa; a job can start "+
			"while you are looking at this screen.") + "\n")
		for _, l := range lines {
			b.WriteString("  " + truncate(l, m.width-4) + "\n")
		}
	}

	b.WriteString("\n" + styHelp.Render("a actions · u measure volume · ↑/↓ another instance · esc back"))
	return b.String()
}

func (m Model) volumeLine(inst inventory.Instance) string {
	line := inst.Volume
	if size, ok := m.volSize[inst.Volume]; ok {
		line += "  " + styMuted.Render("("+size+")")
	} else {
		line += "  " + styMuted.Render("(press u to measure)")
	}
	return line
}

func (m Model) presetLine(inst inventory.Instance) string {
	if inst.Preset == "" {
		return styMuted.Render("unknown — no start or config-swap has recorded one")
	}
	line := inst.Preset
	if chain := m.repo.PresetLineage(inst.Game, inst.Preset); len(chain) > 1 {
		line += "  " + styMuted.Render("inherits "+strings.Join(chain[1:], " → "))
	}
	return line
}

func (m Model) portsLine(inst inventory.Instance) string {
	// Only ports with a non-zero base are real. ARK configures no REST API port,
	// and smalland and windrose configure nothing but a game port; showing
	// base+offset for those would invent plausible numbers.
	p := inst.Ports
	parts := []string{fmt.Sprintf("game %d", p.Game)}
	if p.HasQuery() {
		parts = append(parts, fmt.Sprintf("query %d", p.Query))
	}
	if p.HasRCON() {
		parts = append(parts, fmt.Sprintf("rcon %d", p.RCON))
	}
	if p.HasRESTAPI() {
		parts = append(parts, fmt.Sprintf("rest %d", p.RESTAPI))
	}
	return strings.Join(parts, " · ")
}

func (m Model) lastBackupLine(inst inventory.Instance) string {
	if inst.Cfg == nil {
		return styMuted.Render("unknown")
	}
	b := backups.Latest(m.repo, inst.Cfg, inst.Game, inst.Name)
	if b == nil {
		return styMuted.Render("none")
	}
	when, fromMeta := b.When()
	label := when.Local().Format("2006-01-02 15:04")
	if !fromMeta {
		label += styMuted.Render(" (file mtime)")
	}
	return fmt.Sprintf("%s · %s · %s", label, b.DisplayPreset(), b.HumanSize())
}

func healthType(inst inventory.Instance) string {
	if inst.Cfg == nil {
		return ""
	}
	return inst.Cfg.Game.HealthCheck.Type
}

func scheduleLine(bc config.BackupConfig) string {
	if bc.Schedule == "" {
		return "—"
	}
	return fmt.Sprintf("%s · keep %d", bc.Schedule, bc.Retention)
}

func swapLine(game string) string {
	if config.SupportsHotConfigSwap(game) {
		return "tries hot swap, falls back to a restart"
	}
	return "always cold — the server restarts"
}

func restartLine(game string) string {
	if config.HasNativeRestart(game) {
		return "native"
	}
	return styMuted.Render("stop + start (no native restart for this game)")
}

// cronFor returns crontab lines that look relevant to an instance.
func (m Model) cronFor(inst inventory.Instance) []string {
	var out []string
	for _, l := range m.cronLines {
		lower := strings.ToLower(l)
		if !strings.Contains(lower, "scheduled-backup") && !strings.Contains(lower, "scheduled-config-swap") {
			continue
		}
		// Entries scoped to a different environment are not relevant.
		if strings.Contains(lower, "--env ") && !strings.Contains(lower, "--env "+inst.Env) {
			continue
		}
		// --game all covers everything; a named game must match.
		if strings.Contains(lower, "--game ") &&
			!strings.Contains(lower, "--game all") &&
			!strings.Contains(lower, "--game "+inst.Game) {
			continue
		}
		out = append(out, strings.TrimSpace(l))
	}
	return out
}
