// Admin API for the Samba container: five endpoints that onboard/offboard an
// account and create/grant/revoke a sharepoint, each one implemented as a single
// `smbctl` exec inside smb-pod (see docker.go for why that is the whole security
// boundary). Basic auth on every endpoint, one JSON audit line per request.
package main

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

const (
	// The process never binds a privileged port: Docker maps 127.0.0.1:444 on the  host onto this one,
	// which works on any host regardless of net.ipv4.ip_unprivileged_port_start. See execution-plan.md F1.
	listenAddr   = "0.0.0.0:8333"
	dockerSocket = "/var/run/docker.sock"
	maxBodyBytes = 64 << 10
)

type server struct {
	docker   *dockerClient
	user     string
	pass     string
	auditDir string
}

// handler returns the HTTP status, the input to audit (never the password), a human-readable detail line, and an error when the request failed.
type handler func(*http.Request) (int, map[string]any, string, error)

func main() {
	log.SetFlags(0)

	user, pass := os.Getenv("ADMIN_API_USER"), os.Getenv("ADMIN_API_PASSWORD")
	if user == "" || pass == "" {
		log.Fatal("[smb-admin] ADMIN_API_USER and ADMIN_API_PASSWORD must be set (secrets.env)")
	}
	auditDir := os.Getenv("CONTAINER_LOG_DIR")
	if auditDir == "" {
		auditDir = "/var/log/samba"
	}

	s := &server{docker: newDockerClient(dockerSocket), user: user, pass: pass, auditDir: auditDir}

	// Fail loudly at start instead of on the first request: a non-root process cannot open the socket unless compose gives it the socket's group.
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := s.docker.ping(ctx); err != nil {
		log.Fatalf("[smb-admin] cannot reach the Docker API on %s: %v\n"+
			"[smb-admin] on Docker Desktop that socket is root:root mode 0660 and this process runs "+
			"non-root, so compose has to grant it group 0 (group_add: [\"0\"])", dockerSocket, err)
	}
	if err := s.checkAuditDir(); err != nil {
		log.Printf("[smb-admin] WARNING: audit log directory is not writable: %v", err)
	}

	mux := http.NewServeMux()
	// Unauthenticated, so the compose healthcheck can use it. It reports nothing beyond "the process is up".
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, "ok\n")
	})
	mux.HandleFunc("POST /account", s.guard(s.createAccount))
	mux.HandleFunc("DELETE /account/{user}", s.guard(s.deleteAccount))
	mux.HandleFunc("POST /sharepoint", s.guard(s.createSharepoint))
	mux.HandleFunc("POST /sharepoint/{name}/grants", s.guard(s.createGrant))
	mux.HandleFunc("DELETE /sharepoint/{name}/grants/{user}", s.guard(s.deleteGrant))

	srv := &http.Server{
		Addr:              listenAddr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      60 * time.Second,
	}
	log.Printf("[smb-admin] listening on %s, target container %s, audit log in %s",
		listenAddr, targetContainer, auditDir)
	log.Fatal(srv.ListenAndServe())
}

// --- auth, audit, plumbing --------------------------------------------------

func (s *server) guard(h handler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		actor, _, _ := r.BasicAuth()
		if !s.authorized(r) {
			// 401s are audited too (with the attempted actor), but never the password.
			s.audit(actor, r, nil, "error", "unauthorized")
			w.Header().Set("WWW-Authenticate", `Basic realm="smb-admin", charset="UTF-8"`)
			writeJSON(w, http.StatusUnauthorized, map[string]any{"error": "unauthorized"})
			return
		}
		status, input, detail, err := h(r)
		if err != nil {
			s.audit(actor, r, input, "error", err.Error())
			writeJSON(w, status, map[string]any{"error": sanitize(err.Error())})
			return
		}
		s.audit(actor, r, input, "ok", detail)
		writeJSON(w, status, map[string]any{"status": "ok", "detail": detail})
	}
}

func (s *server) authorized(r *http.Request) bool {
	user, pass, ok := r.BasicAuth()
	if !ok {
		return false
	}
	// Both comparisons always run: no early return that would leak which half failed.
	okUser := subtle.ConstantTimeCompare([]byte(user), []byte(s.user)) == 1
	okPass := subtle.ConstantTimeCompare([]byte(pass), []byte(s.pass)) == 1
	return okUser && okPass
}

func (s *server) auditPath(now time.Time) string {
	return filepath.Join(s.auditDir, "audit-"+now.Format("20060102")+".log")
}

func (s *server) checkAuditDir() error {
	probe := filepath.Join(s.auditDir, ".audit-write-probe")
	f, err := os.OpenFile(probe, os.O_CREATE|os.O_WRONLY, 0o640)
	if err != nil {
		return err
	}
	_ = f.Close()
	return os.Remove(probe)
}

// One JSON line per request, appended to audit-YYYYMMDD.log next to smbd's own logs (same mount, no new directory).
// No rotation or retention by design, same as the smbd logs: see analyze-new-requirement.md §5.8.3.
func (s *server) audit(actor string, r *http.Request, input map[string]any, result, detail string) {
	now := time.Now()
	line, err := json.Marshal(map[string]any{
		"ts":     now.Format(time.RFC3339),
		"actor":  actor,
		"method": r.Method,
		"path":   r.URL.Path,
		"input":  input,
		"result": result,
		"detail": sanitize(detail),
	})
	if err != nil {
		log.Printf("[smb-admin] WARNING: cannot encode audit entry: %v", err)
		return
	}
	log.Printf("%s", line) // also visible in `docker logs smb-admin`

	f, err := os.OpenFile(s.auditPath(now), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o640)
	if err != nil {
		log.Printf("[smb-admin] WARNING: cannot write audit log: %v", err)
		return
	}
	defer f.Close()
	if _, err := f.Write(append(line, '\n')); err != nil {
		log.Printf("[smb-admin] WARNING: cannot write audit log: %v", err)
	}
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func decodeBody(r *http.Request, out any) error {
	decoder := json.NewDecoder(io.LimitReader(r.Body, maxBodyBytes))
	if err := decoder.Decode(out); err != nil {
		return fmt.Errorf("invalid JSON body: %w", sanitizeErr(err))
	}
	return nil
}

func sanitizeErr(err error) error { return errors.New(sanitize(err.Error())) }

// run execs smbctl and turns a non-zero exit into an error carrying its output.
func (s *server) run(ctx context.Context, cmd ...string) (string, error) {
	res, err := s.docker.exec(ctx, cmd)
	if err != nil {
		return "", fmt.Errorf("docker exec failed: %w", err)
	}
	output := sanitize(res.Stdout + " " + res.Stderr)
	if res.ExitCode != 0 {
		return "", fmt.Errorf("smbctl %s exited %d: %s", cmd[1], res.ExitCode, output)
	}
	return output, nil
}

// --- handlers ---------------------------------------------------------------

func (s *server) createAccount(r *http.Request) (int, map[string]any, string, error) {
	var body struct {
		User     string `json:"user"`
		Password string `json:"password"`
		Group    string `json:"group"`
	}
	if err := decodeBody(r, &body); err != nil {
		return http.StatusBadRequest, nil, "", err
	}
	// The password is deliberately absent from the audited input.
	input := map[string]any{"user": body.User, "group": body.Group}

	if err := validName(body.User, 32); err != nil {
		return http.StatusBadRequest, input, "", fmt.Errorf("user: %w", err)
	}
	if body.Password == "" {
		return http.StatusBadRequest, input, "", errors.New("password must not be empty")
	}
	if hasControl(body.Password) {
		return http.StatusBadRequest, input, "", errors.New("password must not contain control characters")
	}
	if body.Group != "" {
		if err := validName(body.Group, 32); err != nil {
			return http.StatusBadRequest, input, "", fmt.Errorf("group: %w", err)
		}
	}

	cmd := []string{"smbctl", "onboard", body.User, body.Password}
	if body.Group != "" {
		cmd = append(cmd, body.Group)
	}
	detail, err := s.run(r.Context(), cmd...)
	if err != nil {
		return http.StatusInternalServerError, input, "", err
	}
	return http.StatusCreated, input, detail, nil
}

func (s *server) deleteAccount(r *http.Request) (int, map[string]any, string, error) {
	user := r.PathValue("user")
	input := map[string]any{"user": user}
	if err := validName(user, 32); err != nil {
		return http.StatusBadRequest, input, "", fmt.Errorf("user: %w", err)
	}
	detail, err := s.run(r.Context(), "smbctl", "offboard", user)
	if err != nil {
		return http.StatusInternalServerError, input, "", err
	}
	return http.StatusOK, input, detail, nil
}

func (s *server) createSharepoint(r *http.Request) (int, map[string]any, string, error) {
	var body struct {
		Name string `json:"name"`
	}
	if err := decodeBody(r, &body); err != nil {
		return http.StatusBadRequest, nil, "", err
	}
	input := map[string]any{"name": body.Name}
	if err := validName(body.Name, 26); err != nil {
		return http.StatusBadRequest, input, "", fmt.Errorf("name: %w", err)
	}
	detail, err := s.run(r.Context(), "smbctl", "sharepoint-create", body.Name)
	if err != nil {
		return http.StatusInternalServerError, input, "", err
	}
	return http.StatusCreated, input, detail, nil
}

func (s *server) createGrant(r *http.Request) (int, map[string]any, string, error) {
	share := r.PathValue("name")
	var body struct {
		User string `json:"user"`
		Mode string `json:"mode"`
	}
	if err := decodeBody(r, &body); err != nil {
		return http.StatusBadRequest, map[string]any{"share": share}, "", err
	}
	input := map[string]any{"share": share, "user": body.User, "mode": body.Mode}
	if err := validName(share, 26); err != nil {
		return http.StatusBadRequest, input, "", fmt.Errorf("share: %w", err)
	}
	if err := validName(body.User, 32); err != nil {
		return http.StatusBadRequest, input, "", fmt.Errorf("user: %w", err)
	}
	if body.Mode != "r" && body.Mode != "rw" {
		return http.StatusBadRequest, input, "", errors.New(`mode must be "r" or "rw"`)
	}
	detail, err := s.run(r.Context(), "smbctl", "grant", body.User, share, body.Mode)
	if err != nil {
		return http.StatusInternalServerError, input, "", err
	}
	return http.StatusOK, input, detail, nil
}

// Mode matches `smbctl revoke`: "w" (the default) drops write access and keeps read, "all" drops both. Pass it as ?mode=all.
func (s *server) deleteGrant(r *http.Request) (int, map[string]any, string, error) {
	share, user := r.PathValue("name"), r.PathValue("user")
	mode := r.URL.Query().Get("mode")
	if mode == "" {
		mode = "w"
	}
	input := map[string]any{"share": share, "user": user, "mode": mode}
	if err := validName(share, 26); err != nil {
		return http.StatusBadRequest, input, "", fmt.Errorf("share: %w", err)
	}
	if err := validName(user, 32); err != nil {
		return http.StatusBadRequest, input, "", fmt.Errorf("user: %w", err)
	}
	if mode != "w" && mode != "all" {
		return http.StatusBadRequest, input, "", errors.New(`mode must be "w" or "all"`)
	}
	detail, err := s.run(r.Context(), "smbctl", "revoke", user, share, mode)
	if err != nil {
		return http.StatusInternalServerError, input, "", err
	}
	return http.StatusOK, input, detail, nil
}
