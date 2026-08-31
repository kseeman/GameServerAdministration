package ui

import (
	"fmt"
	"os/exec"
	"regexp"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
)

func (m Model) updateOutput(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "esc", "q":
		if m.running {
			// Leaving mid-run would hide the operation with no way back to it.
			return m, nil
		}
		m.mode = modeDashboard
		return m, m.loadSnapshot()

	case "ctrl+x":
		if m.running && m.runCancel != nil {
			m.outLines = append(m.outLines, styWarn.Render("— cancelling —"))
			m.out.SetContent(strings.Join(m.outLines, "\n"))
			m.runCancel()
		}
		return m, nil
	}

	var cmd tea.Cmd
	m.out, cmd = m.out.Update(msg)
	return m, cmd
}

func (m Model) viewOutput() string {
	var b strings.Builder
	b.WriteString(m.statusLine() + "\n\n")

	head := fmt.Sprintf("%s — %s / %s @ %s",
		m.runReq.Op, m.runReq.Game, m.runReq.Instance, m.runReq.Env)
	b.WriteString(styTitle.Render(head) + "\n")

	b.WriteString(m.out.View() + "\n\n")

	switch {
	case m.running:
		b.WriteString(styWarn.Render("running…") + "  " +
			styHelp.Render("↑/↓ scroll · ctrl+x cancel"))

	case m.runResult == nil:
		b.WriteString(styHelp.Render("esc back"))

	case m.runResult.OK():
		b.WriteString(styOK.Render("✓ completed (exit 0)") + "  " + styHelp.Render("esc back"))

	default:
		// Report the script's own verdict rather than inferring one. A non-zero
		// exit is a failure even when the log printed [SUCCESS] lines earlier,
		// which happens when a later step refuses.
		msg := fmt.Sprintf("✗ failed (exit %d)", m.runResult.ExitCode)
		if m.runResult.Err != nil {
			msg = "✗ failed: " + m.runResult.Err.Error()
		}
		b.WriteString(styErr.Render(msg) + "  " + styHelp.Render("esc back"))
	}

	return b.String()
}

// --- filter -----------------------------------------------------------------

func (m Model) updateFilter(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.Type {
	case tea.KeyEnter:
		m.filter = m.filterIn.Value()
		m.filterIn.Blur()
		m.mode = modeDashboard
		m.applyFilter()
		return m, nil
	case tea.KeyEsc:
		m.filterIn.Blur()
		m.mode = modeDashboard
		return m, nil
	}
	var cmd tea.Cmd
	m.filterIn, cmd = m.filterIn.Update(msg)
	// Filter live so the result is visible while typing.
	m.filter = m.filterIn.Value()
	m.applyFilter()
	return m, cmd
}

func (m Model) viewFilter() string {
	var b strings.Builder
	b.WriteString(m.viewDashboard())
	b.WriteString("\n\n" + m.filterIn.View() + "\n")
	b.WriteString(styHelp.Render("enter apply · esc cancel"))
	return b.String()
}

// --- root view --------------------------------------------------------------

func (m Model) View() string {
	if !m.ready {
		return "loading…"
	}
	switch m.mode {
	case modeDetail:
		return m.viewDetail()
	case modeActions, modePresets, modeBackups:
		return m.viewPicker()
	case modeConfirm:
		return m.viewConfirm()
	case modeOutput:
		return m.viewOutput()
	case modeFilter:
		return m.viewFilter()
	default:
		return m.viewDashboard()
	}
}

// --- misc -------------------------------------------------------------------

var ansiRe = regexp.MustCompile("\x1b\\[[0-9;]*[a-zA-Z]")

// stripAnsi removes escape sequences so a string can be measured and padded.
func stripAnsi(s string) string { return ansiRe.ReplaceAllString(s, "") }

// padStyled pads a string that may already carry ANSI styling, measuring only
// its visible width.
func padStyled(s string, width int) string {
	visible := len([]rune(stripAnsi(s)))
	if visible >= width {
		return s
	}
	return s + strings.Repeat(" ", width-visible)
}

// readCron returns the user's crontab lines, or nil when there is no crontab.
//
// cron drives scheduled-backup.sh and scheduled-config-swap.sh against the same
// instances gsa manages, and gsa's lock cannot stop it — so the least it can do
// is show you what is scheduled.
func readCron() []string {
	out, err := exec.Command("crontab", "-l").Output()
	if err != nil {
		return nil
	}
	var lines []string
	for _, l := range strings.Split(string(out), "\n") {
		trimmed := strings.TrimSpace(l)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		lines = append(lines, trimmed)
	}
	return lines
}
