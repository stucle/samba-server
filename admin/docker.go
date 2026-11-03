package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"time"
)

// The target container is a compile-time constant, never a request parameter:
// that is the whole security boundary of this service. docker.sock is equivalent to root on the host,
// so only these two endpoints are ever called — /containers/create, /stop, /kill, /restart and DELETE /containers are not reachable through any code path here.
const (
	targetContainer = "smb-pod"
	apiVersion      = "v1.43"
	dockerHost      = "http://docker" // ignored: the transport always dials the unix socket
)

type dockerClient struct {
	http *http.Client
}

func newDockerClient(socket string) *dockerClient {
	return &dockerClient{http: &http.Client{
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				var d net.Dialer
				return d.DialContext(ctx, "unix", socket)
			},
		},
		Timeout: 30 * time.Second,
	}}
}

func (c *dockerClient) do(ctx context.Context, method, path string, body any) (*http.Response, error) {
	var payload io.Reader
	if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		payload = bytes.NewReader(encoded)
	}
	req, err := http.NewRequestWithContext(ctx, method, dockerHost+"/"+apiVersion+path, payload)
	if err != nil {
		return nil, err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode >= 400 {
		defer resp.Body.Close()
		detail, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return nil, fmt.Errorf("docker %s %s: %s: %s", method, path, resp.Status, sanitize(string(detail)))
	}
	return resp, nil
}

func (c *dockerClient) doJSON(ctx context.Context, method, path string, body, out any) error {
	resp, err := c.do(ctx, method, path, body)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if out == nil {
		return nil
	}
	return json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(out)
}

func (c *dockerClient) ping(ctx context.Context) error {
	resp, err := c.do(ctx, http.MethodGet, "/_ping", nil)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	return nil
}

type execResult struct {
	ExitCode int
	Stdout   string
	Stderr   string
}

// exec runs cmd inside the target container. cmd is an argv array built from
// already-validated input — no shell is involved anywhere, so there is nothing
// for a quote or a semicolon to escape into.
func (c *dockerClient) exec(ctx context.Context, cmd []string) (execResult, error) {
	var created struct {
		ID string `json:"Id"`
	}
	err := c.doJSON(ctx, http.MethodPost, "/containers/"+targetContainer+"/exec", map[string]any{
		"AttachStdout": true,
		"AttachStderr": true,
		"Tty":          false,
		"Cmd":          cmd,
	}, &created)
	if err != nil {
		return execResult{}, err
	}
	if created.ID == "" {
		return execResult{}, fmt.Errorf("docker returned no exec id")
	}

	resp, err := c.do(ctx, http.MethodPost, "/exec/"+created.ID+"/start", map[string]any{
		"Detach": false,
		"Tty":    false,
	})
	if err != nil {
		return execResult{}, err
	}
	defer resp.Body.Close()

	stdout, stderr, err := demultiplex(resp.Body)
	if err != nil {
		return execResult{}, fmt.Errorf("reading exec output: %w", err)
	}

	var inspected struct {
		ExitCode int  `json:"ExitCode"`
		Running  bool `json:"Running"`
	}
	if err := c.doJSON(ctx, http.MethodGet, "/exec/"+created.ID+"/json", nil, &inspected); err != nil {
		return execResult{}, fmt.Errorf("inspecting exec: %w", err)
	}
	if inspected.Running {
		return execResult{}, fmt.Errorf("exec still running after its output stream closed")
	}
	return execResult{ExitCode: inspected.ExitCode, Stdout: stdout, Stderr: stderr}, nil
}

// demultiplex decodes Docker's stream format (Tty=false): 8-byte header per
// frame, byte 0 is the stream id (1 = stdout, 2 = stderr), bytes 4..8 the
// big-endian payload length.
func demultiplex(r io.Reader) (string, string, error) {
	var stdout, stderr bytes.Buffer
	header := make([]byte, 8)
	const maxTotal = 1 << 20

	for stdout.Len()+stderr.Len() < maxTotal {
		if _, err := io.ReadFull(r, header); err != nil {
			if err == io.EOF || err == io.ErrUnexpectedEOF {
				break
			}
			return "", "", err
		}
		size := int64(binary.BigEndian.Uint32(header[4:8]))
		target := &stdout
		if header[0] == 2 {
			target = &stderr
		}
		if _, err := io.CopyN(target, r, size); err != nil {
			if err == io.EOF {
				break
			}
			return "", "", err
		}
	}
	return stdout.String(), stderr.String(), nil
}
