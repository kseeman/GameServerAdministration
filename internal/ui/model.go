// Package ui implements the gsa terminal interface.
package ui

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/textinput"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"

	"github.com/kseeman/GameServerAdministration/internal/backups"
	"github.com/kseeman/GameServerAdministration/internal/config"
	"github.com/kseeman/GameServerAdministration/internal/dockerx"
	"github.com/kseeman/GameServerAdministration/internal/inventory"
	"github.com/kseeman/GameServerAdministration/internal/runner"
)

// mode is which screen is in front.
type mode int

const (
	modeDashboard mode = iota
	modeDetail
	modeActions
	modePresets
	modeBackups
	modeConfirm
	modeOutput
	modeFilter
)

// refreshInterval is how often the dashboard re-reads Docker. Slow enough not
// to hammer the daemon over SSH, fast enough that a start feels acknowledged.
const refreshInterval = 5 * time.Second

// Model is the root Bubble Tea model.
type Model struct {
	repo   *config.Repo
	docker *dockerx.Client
	runner *runner.Runner

	mode mode
	prev mode // where esc returns to

	width, height int
	ready         bool

	// Fleet state.
	snap   *inventory.Snapshot
	rows   []inventory.Instance // filtered view of snap.Instances
	cursor int
	err    error

	// Filters.
	filter    string
	filterIn  textinput.Model
	envFilter string // "", "staging" or "production"

	// Sub-screens.
	pick    picker
	confirm confirmModel

	// A pending request waiting on confirmation.
	pending runner.Request

	// Running operation.
	out       viewport.Model
	outLines  []string
	running   bool
	runReq    runner.Request
	runCancel context.CancelFunc
	runResult *runner.Result
	lineCh    chan string
	doneCh    <-chan runner.Result

	// Cached extras for the detail pane.
	volSize   map[string]string
	lastBkp   map[string]*backups.Backup
	cronLines []string

	dryRun bool
}

// New builds the root model.
func New(repo *config.Repo, docker *dockerx.Client, envFilter string) Model {
	ti := textinput.New()
	ti.Prompt = "/"
	ti.Placeholder = "filter by game, instance or preset"

	return Model{
		repo:      repo,
		docker:    docker,
		runner:    runner.New(repo),
		filterIn:  ti,
		envFilter: envFilter,
		volSize:   map[string]string{},
		lastBkp:   map[string]*backups.Backup{},
	}
}

// --- messages ---------------------------------------------------------------

type snapshotMsg struct {
	snap *inventory.Snapshot
	err  error
}
type tickMsg time.Time
type outLineMsg string
type runDoneMsg runner.Result
type volSizeMsg struct {
	volume string
	size   string
	err    error
}
type cronMsg []string

func (m Model) Init() tea.Cmd {
	return tea.Batch(m.loadSnapshot(), m.loadCron(), tick())
}

func tick() tea.Cmd {
	return tea.Tick(refreshInterval, func(t time.Time) tea.Msg { return tickMsg(t) })
}

func (m Model) loadSnapshot() tea.Cmd {
	return func() tea.Msg {
		snap, err := inventory.Load(m.repo, m.docker)
		return snapshotMsg{snap: snap, err: err}
	}
}

func (m Model) loadCron() tea.Cmd {
	return func() tea.Msg { return cronMsg(readCron()) }
}

// waitLine and waitDone bridge the runner's channels into the Bubble Tea loop.
func waitLine(ch chan string) tea.Cmd {
	return func() tea.Msg {
		line, ok := <-ch
		if !ok {
			return nil
		}
		return outLineMsg(line)
	}
}

func waitDone(ch <-chan runner.Result) tea.Cmd {
	return func() tea.Msg { return runDoneMsg(<-ch) }
}

// --- update -----------------------------------------------------------------

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {

	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		m.ready = true
		m.out.Width = msg.Width - 4
		m.out.Height = msg.Height - 8
		if m.out.Height < 3 {
			m.out.Height = 3
		}
		m.filterIn.Width = msg.Width - 6
		return m, nil

	case snapshotMsg:
		if msg.err != nil {
			m.err = msg.err
		} else {
			m.err = nil
			m.snap = msg.snap
			m.applyFilter()
		}
		return m, nil

	case cronMsg:
		m.cronLines = msg
		return m, nil

	case tickMsg:
		// Refreshing mid-operation would fight the output pane for attention;
		// the post-run refresh covers it.
		if m.running {
			return m, tick()
		}
		return m, tea.Batch(m.loadSnapshot(), tick())

	case volSizeMsg:
		if msg.err == nil {
			m.volSize[msg.volume] = msg.size
		} else {
			m.volSize[msg.volume] = "unknown"
		}
		return m, nil

	case outLineMsg:
		m.outLines = append(m.outLines, string(msg))
		m.out.SetContent(strings.Join(m.outLines, "\n"))
		m.out.GotoBottom()
		return m, waitLine(m.lineCh)

	case runDoneMsg:
		res := runner.Result(msg)
		m.running = false
		m.runResult = &res
		m.runCancel = nil
		// Re-read the fleet so the dashboard reflects whatever just happened.
		return m, m.loadSnapshot()

	case tea.KeyMsg:
		return m.handleKey(msg)
	}

	// Let the output viewport handle scroll messages it understands.
	if m.mode == modeOutput {
		var cmd tea.Cmd
		m.out, cmd = m.out.Update(msg)
		return m, cmd
	}
	return m, nil
}

func (m Model) handleKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	// Ctrl+C always quits, except that it first cancels a running operation so
	// a half-finished start does not get orphaned.
	if msg.Type == tea.KeyCtrlC {
		if m.running && m.runCancel != nil {
			m.runCancel()
			return m, nil
		}
		return m, tea.Quit
	}

	switch m.mode {
	case modeFilter:
		return m.updateFilter(msg)
	case modeConfirm:
		return m.updateConfirm(msg)
	case modeOutput:
		return m.updateOutput(msg)
	case modeActions, modePresets, modeBackups:
		return m.updatePicker(msg)
	case modeDetail:
		return m.updateDetail(msg)
	default:
		return m.updateDashboard(msg)
	}
}

// --- helpers ----------------------------------------------------------------

func (m *Model) applyFilter() {
	m.rows = nil
	if m.snap == nil {
		return
	}
	needle := strings.ToLower(strings.TrimSpace(m.filter))
	for _, inst := range m.snap.Instances {
		if m.envFilter != "" && inst.Env != m.envFilter {
			continue
		}
		if needle != "" {
			hay := strings.ToLower(strings.Join([]string{
				inst.Game, inst.Name, inst.Env, inst.DisplayPreset(), inst.Info.Description, inst.Info.Map,
			}, " "))
			if !strings.Contains(hay, needle) {
				continue
			}
		}
		m.rows = append(m.rows, inst)
	}
	if m.cursor >= len(m.rows) {
		m.cursor = len(m.rows) - 1
	}
	if m.cursor < 0 {
		m.cursor = 0
	}
}

// current returns the selected instance, if any.
func (m Model) current() (inventory.Instance, bool) {
	if m.cursor < 0 || m.cursor >= len(m.rows) {
		return inventory.Instance{}, false
	}
	return m.rows[m.cursor], true
}

// launch begins an operation, moving to the output pane.
func (m *Model) launch(req runner.Request) tea.Cmd {
	req.DryRun = m.dryRun

	m.outLines = []string{
		styMuted.Render("$ " + req.Describe("scripts/core/server-manager.sh")),
		"",
	}
	m.out.SetContent(strings.Join(m.outLines, "\n"))
	m.runResult = nil
	m.runReq = req
	m.mode = modeOutput

	ctx, cancel := context.WithCancel(context.Background())
	m.lineCh = make(chan string, 512)

	done, err := m.runner.Start(ctx, req, m.lineCh)
	if err != nil {
		cancel()
		m.running = false
		failed := runner.Result{ExitCode: -1, Err: err}
		m.runResult = &failed
		m.outLines = append(m.outLines, styErr.Render("could not start: "+err.Error()))
		m.out.SetContent(strings.Join(m.outLines, "\n"))
		return nil
	}

	m.running = true
	m.runCancel = cancel
	m.doneCh = done
	return tea.Batch(waitLine(m.lineCh), waitDone(done))
}

// statusLine is the one-line summary at the top of every screen.
func (m Model) statusLine() string {
	var parts []string
	parts = append(parts, styTitle.Render("gsa"))

	if m.snap != nil {
		running, stopped, absent, total := m.snap.Counts()
		summary := fmt.Sprintf("%d running · %d stopped", running, stopped)
		if absent > 0 {
			summary += fmt.Sprintf(" · %d never built", absent)
		}
		summary += fmt.Sprintf(" · %d configured", total)
		parts = append(parts, summary)
	}

	switch m.envFilter {
	case "":
		parts = append(parts, styMuted.Render("all envs"))
	case "production":
		parts = append(parts, styProdBadge.Render("PRODUCTION"))
	default:
		parts = append(parts, styMuted.Render(m.envFilter))
	}

	if m.dryRun {
		parts = append(parts, styWarn.Render("DRY-RUN"))
	}
	if m.snap != nil && !m.snap.DockerOK {
		parts = append(parts, styErr.Render("docker unavailable"))
	}
	if m.filter != "" {
		parts = append(parts, styMuted.Render("/"+m.filter))
	}
	return strings.Join(parts, "  ")
}
