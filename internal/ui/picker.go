package ui

import (
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// pickerItem is one selectable row.
type pickerItem struct {
	Title string
	Desc  string
	// Disabled rows render dimmed and cannot be chosen. Used for actions that
	// are illegal in the current state, so the reason stays visible rather than
	// the option silently vanishing.
	Disabled bool
	Reason   string
	Value    any
}

// picker is a scrolling single-select list used for actions, presets and
// backups.
type picker struct {
	title  string
	items  []pickerItem
	cursor int
	offset int
	height int
	width  int
}

func newPicker(title string, items []pickerItem, height int) picker {
	p := picker{title: title, items: items, height: height}
	p.cursor = p.firstEnabled()
	return p
}

func (p picker) firstEnabled() int {
	for i, it := range p.items {
		if !it.Disabled {
			return i
		}
	}
	return 0
}

func (p *picker) move(delta int) {
	if len(p.items) == 0 {
		return
	}
	i := p.cursor
	for n := 0; n < len(p.items); n++ {
		i += delta
		if i < 0 {
			i = len(p.items) - 1
		}
		if i >= len(p.items) {
			i = 0
		}
		if !p.items[i].Disabled {
			p.cursor = i
			p.scroll()
			return
		}
	}
}

func (p *picker) scroll() {
	visible := p.visibleRows()
	if p.cursor < p.offset {
		p.offset = p.cursor
	}
	if p.cursor >= p.offset+visible {
		p.offset = p.cursor - visible + 1
	}
	if p.offset < 0 {
		p.offset = 0
	}
}

func (p picker) visibleRows() int {
	// Title plus help line consume two rows.
	v := p.height - 2
	if v < 1 {
		return 1
	}
	return v
}

func (p *picker) update(msg tea.KeyMsg) (selected *pickerItem, cancelled bool) {
	switch msg.String() {
	case "up", "k":
		p.move(-1)
	case "down", "j":
		p.move(1)
	case "home", "g":
		p.cursor = p.firstEnabled()
		p.scroll()
	case "end", "G":
		for i := len(p.items) - 1; i >= 0; i-- {
			if !p.items[i].Disabled {
				p.cursor = i
				break
			}
		}
		p.scroll()
	case "enter":
		if p.cursor < len(p.items) && !p.items[p.cursor].Disabled {
			it := p.items[p.cursor]
			return &it, false
		}
	case "esc", "q":
		return nil, true
	}
	return nil, false
}

func (p picker) view() string {
	var b strings.Builder
	b.WriteString(styTitle.Render(p.title) + "\n")

	if len(p.items) == 0 {
		b.WriteString(styMuted.Render("  (nothing to choose)") + "\n")
		b.WriteString(styHelp.Render("esc back"))
		return b.String()
	}

	visible := p.visibleRows()
	end := p.offset + visible
	if end > len(p.items) {
		end = len(p.items)
	}

	for i := p.offset; i < end; i++ {
		it := p.items[i]
		line := "  " + it.Title
		if it.Desc != "" {
			line += "  " + styMuted.Render(it.Desc)
		}
		if it.Disabled && it.Reason != "" {
			line += "  " + styMuted.Render("("+it.Reason+")")
		}

		switch {
		case it.Disabled:
			line = styMuted.Render("  " + truncate(stripStyle(it.Title), p.width-4))
			if it.Reason != "" {
				line += styMuted.Render("  (" + it.Reason + ")")
			}
		case i == p.cursor:
			prefix := stySelected.Render("▸ " + it.Title)
			if it.Desc != "" {
				prefix += "  " + styMuted.Render(it.Desc)
			}
			line = prefix
		}
		b.WriteString(line + "\n")
	}

	if len(p.items) > visible {
		b.WriteString(styMuted.Render(scrollHint(p.cursor+1, len(p.items))) + "\n")
	}
	b.WriteString(styHelp.Render("↑/↓ move · enter select · esc back"))
	return b.String()
}

func scrollHint(pos, total int) string {
	return "  " + itoa(pos) + "/" + itoa(total)
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var digits []byte
	for n > 0 {
		digits = append([]byte{byte('0' + n%10)}, digits...)
		n /= 10
	}
	return string(digits)
}

// stripStyle removes lipgloss formatting so disabled rows render uniformly.
func stripStyle(s string) string { return lipgloss.NewStyle().Render(s) }
