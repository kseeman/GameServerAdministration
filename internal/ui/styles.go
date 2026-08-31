package ui

import (
	"github.com/charmbracelet/lipgloss"

	"github.com/kseeman/GameServerAdministration/internal/inventory"
)

// Colours are picked from the 256-colour cube rather than truecolor so the app
// degrades sanely on a plain SSH terminal.
var (
	colFg       = lipgloss.AdaptiveColor{Light: "236", Dark: "252"}
	colMuted    = lipgloss.AdaptiveColor{Light: "245", Dark: "243"}
	colAccent   = lipgloss.AdaptiveColor{Light: "27", Dark: "39"}
	colGreen    = lipgloss.AdaptiveColor{Light: "28", Dark: "42"}
	colYellow   = lipgloss.AdaptiveColor{Light: "130", Dark: "214"}
	colRed      = lipgloss.AdaptiveColor{Light: "124", Dark: "203"}
	colBorder   = lipgloss.AdaptiveColor{Light: "252", Dark: "238"}
	colProdBg   = lipgloss.AdaptiveColor{Light: "224", Dark: "52"}
	colSelBg    = lipgloss.AdaptiveColor{Light: "254", Dark: "236"}
	colHeaderFg = lipgloss.AdaptiveColor{Light: "241", Dark: "245"}
)

var (
	styTitle = lipgloss.NewStyle().Bold(true).Foreground(colAccent)

	styHeader = lipgloss.NewStyle().
			Foreground(colHeaderFg).
			Bold(true)

	styMuted = lipgloss.NewStyle().Foreground(colMuted)

	stySelected = lipgloss.NewStyle().Background(colSelBg).Foreground(colFg).Bold(true)

	styHelp = lipgloss.NewStyle().Foreground(colMuted)

	styErr = lipgloss.NewStyle().Foreground(colRed).Bold(true)

	styOK = lipgloss.NewStyle().Foreground(colGreen).Bold(true)

	styWarn = lipgloss.NewStyle().Foreground(colYellow)

	styBox = lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(colBorder).
		Padding(0, 1)

	styDanger = lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(colRed).
			Padding(0, 1)

	// Production is visually distinct everywhere it appears; the whole point of
	// a fast UI is that it stays hard to act on prod by accident.
	styProd = lipgloss.NewStyle().Foreground(colRed).Bold(true)

	styProdBadge = lipgloss.NewStyle().Background(colProdBg).Foreground(colFg).Bold(true).Padding(0, 1)

	styStaging = lipgloss.NewStyle().Foreground(colMuted)
)

// statusDot renders the coloured indicator for an instance state.
func statusDot(s inventory.Status) string {
	switch s {
	case inventory.StatusRunning:
		return lipgloss.NewStyle().Foreground(colGreen).Render("●")
	case inventory.StatusStarting:
		return lipgloss.NewStyle().Foreground(colYellow).Render("◐")
	case inventory.StatusUnhealthy:
		return lipgloss.NewStyle().Foreground(colRed).Render("●")
	case inventory.StatusStopped:
		return lipgloss.NewStyle().Foreground(colMuted).Render("○")
	default:
		return lipgloss.NewStyle().Foreground(colMuted).Render("·")
	}
}

func envStyle(env string) lipgloss.Style {
	if env == "production" {
		return styProd
	}
	return styStaging
}

// truncate shortens s to width, marking elision with an ellipsis.
func truncate(s string, width int) string {
	if width <= 0 {
		return ""
	}
	if lipgloss.Width(s) <= width {
		return s
	}
	runes := []rune(s)
	if width == 1 {
		return "…"
	}
	if len(runes) > width-1 {
		runes = runes[:width-1]
	}
	return string(runes) + "…"
}

// pad right-pads s to width, truncating when it does not fit.
func pad(s string, width int) string {
	s = truncate(s, width)
	for lipgloss.Width(s) < width {
		s += " "
	}
	return s
}
