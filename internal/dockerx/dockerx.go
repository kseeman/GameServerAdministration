// Package dockerx wraps the docker CLI.
//
// It shells out rather than using the Docker SDK, matching how the rest of the
// repo talks to Docker and avoiding an API-version coupling that would have to
// be kept in step with whatever the server runs.
package dockerx

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"os/exec"
	"strings"
	"time"
)

// Container is the subset of `docker ps` output the dashboard needs.
type Container struct {
	Names   string `json:"Names"`
	State   string `json:"State"`
	Status  string `json:"Status"`
	Image   string `json:"Image"`
	Ports   string `json:"Ports"`
	RunFor  string `json:"RunningFor"`
	CreatAt string `json:"CreatedAt"`
}

// Running reports whether the container is in Docker's "running" state.
func (c Container) Running() bool { return c.State == "running" }

// Health extracts the health substring Docker embeds in Status, e.g.
// "Up 2 hours (healthy)" -> "healthy". Returns "" when the image declares no
// healthcheck.
func (c Container) Health() string {
	open := strings.LastIndex(c.Status, "(")
	close := strings.LastIndex(c.Status, ")")
	if open < 0 || close < open {
		return ""
	}
	h := c.Status[open+1 : close]
	// Docker writes "health: starting" in some versions.
	h = strings.TrimPrefix(h, "health: ")
	switch h {
	case "healthy", "unhealthy", "starting":
		return h
	}
	return ""
}

// Uptime is Docker's human-readable RunningFor, e.g. "2 hours ago" -> "2 hours".
func (c Container) Uptime() string {
	return strings.TrimSuffix(c.RunFor, " ago")
}

// Client runs docker commands.
type Client struct {
	// Timeout bounds every call so a wedged daemon cannot freeze the UI.
	Timeout time.Duration
}

func New() *Client { return &Client{Timeout: 10 * time.Second} }

func (c *Client) timeout() time.Duration {
	if c.Timeout <= 0 {
		return 10 * time.Second
	}
	return c.Timeout
}

// Available reports whether the docker CLI exists and its daemon answers.
// The dashboard stays usable when this is false — every instance simply reads
// as stopped, which is the honest answer when we cannot tell.
func (c *Client) Available() bool {
	if _, err := exec.LookPath("docker"); err != nil {
		return false
	}
	ctx, cancel := context.WithTimeout(context.Background(), c.timeout())
	defer cancel()
	return exec.CommandContext(ctx, "docker", "info", "--format", "{{.ServerVersion}}").Run() == nil
}

// PS lists all containers, running or not, keyed by name.
//
// It uses `--format {{json .}}`, which emits one JSON object per line, rather
// than the table format server-manager.sh prints for humans.
func (c *Client) PS() (map[string]Container, error) {
	ctx, cancel := context.WithTimeout(context.Background(), c.timeout())
	defer cancel()

	cmd := exec.CommandContext(ctx, "docker", "ps", "--all", "--no-trunc", "--format", "{{json .}}")
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return nil, &Error{Op: "docker ps", Err: err, Detail: strings.TrimSpace(stderr.String())}
	}

	out := map[string]Container{}
	scanner := bufio.NewScanner(&stdout)
	scanner.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for scanner.Scan() {
		line := bytes.TrimSpace(scanner.Bytes())
		if len(line) == 0 {
			continue
		}
		var ct Container
		if err := json.Unmarshal(line, &ct); err != nil {
			continue // a single unparseable row should not lose the rest
		}
		// A container can report multiple comma-separated names.
		for _, name := range strings.Split(ct.Names, ",") {
			if name = strings.TrimSpace(name); name != "" {
				out[name] = ct
			}
		}
	}
	return out, scanner.Err()
}

// VolumeExists reports whether a named volume is present.
func (c *Client) VolumeExists(name string) bool {
	ctx, cancel := context.WithTimeout(context.Background(), c.timeout())
	defer cancel()
	return exec.CommandContext(ctx, "docker", "volume", "inspect", name).Run() == nil
}

// VolumeSize returns a human-readable size for a volume.
//
// This is deliberately not called for the dashboard: it starts a throwaway
// container per volume (the same trick server-manager.sh uses), which is far too
// slow to run across the whole fleet on a refresh tick. The detail pane calls it
// on request only.
func (c *Client) VolumeSize(name string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	cmd := exec.CommandContext(ctx, "docker", "run", "--rm",
		"-v", name+":/data", "alpine:latest", "du", "-sh", "/data")
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return "", &Error{Op: "docker run du", Err: err, Detail: strings.TrimSpace(stderr.String())}
	}
	fields := strings.Fields(stdout.String())
	if len(fields) == 0 {
		return "", nil
	}
	return fields[0], nil
}

// Error carries the stderr detail a bare exec.ExitError throws away.
type Error struct {
	Op     string
	Err    error
	Detail string
}

func (e *Error) Error() string {
	if e.Detail != "" {
		return e.Op + ": " + e.Detail
	}
	return e.Op + ": " + e.Err.Error()
}

func (e *Error) Unwrap() error { return e.Err }
