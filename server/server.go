// Package server exposes the catalog over HTTP. It is transport only: all
// logic lives in core.
package server

import (
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/solo12345689/cinemacore/core/catalog"
)

// Server is the HTTP surface for the catalog.
type Server struct {
	cat      *catalog.Catalog
	version  string
	specPath string
	log      *slog.Logger
}

// Options configures a Server.
type Options struct {
	Catalog  *catalog.Catalog
	Version  string
	SpecPath string
	Logger   *slog.Logger
}

// New builds a Server.
func New(o Options) *Server {
	if o.Logger == nil {
		o.Logger = slog.New(slog.NewTextHandler(os.Stderr, nil))
	}
	return &Server{cat: o.Catalog, version: o.Version, specPath: o.SpecPath, log: o.Logger}
}

// Handler returns the routed HTTP handler.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", s.health)
	mux.HandleFunc("GET /version", s.versionHandler)
	mux.HandleFunc("GET /openapi.json", s.openapi)
	mux.HandleFunc("GET /v1/home", s.home)
	mux.HandleFunc("GET /v1/search", s.search)
	mux.HandleFunc("GET /v1/search/suggestions", s.suggestions)
	mux.HandleFunc("GET /v1/detail/{id}", s.detail)
	mux.HandleFunc("GET /v1/detail/{id}/seasons", s.seasons)
	mux.HandleFunc("GET /v1/play", s.play)
	return mux
}

func (s *Server) health(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) versionHandler(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"version": s.version})
}

func (s *Server) openapi(w http.ResponseWriter, _ *http.Request) {
	b, err := os.ReadFile(s.specPath)
	if err != nil {
		writeErr(w, http.StatusNotFound, "spec_unavailable", err.Error())
		return
	}
	w.Header().Set("Content-Type", "application/yaml")
	w.Header().Set("X-API-Version", "1")
	w.Write(b)
}

func (s *Server) home(w http.ResponseWriter, r *http.Request) {
	page, err := s.cat.Home(r.Context())
	if err != nil {
		s.fail(w, "home", err)
		return
	}
	writeJSON(w, http.StatusOK, page)
}

func (s *Server) search(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query().Get("q")
	if q == "" {
		writeErr(w, http.StatusBadRequest, "missing_query", "query parameter q is required")
		return
	}
	items, err := s.cat.Search(r.Context(), q)
	if err != nil {
		s.fail(w, "search", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

func (s *Server) detail(w http.ResponseWriter, r *http.Request) {
	sub, err := s.cat.Detail(r.Context(), r.PathValue("id"))
	if err != nil {
		s.fail(w, "detail", err)
		return
	}
	writeJSON(w, http.StatusOK, sub)
}

func (s *Server) seasons(w http.ResponseWriter, r *http.Request) {
	seasons, err := s.cat.Seasons(r.Context(), r.PathValue("id"))
	if err != nil {
		s.fail(w, "seasons", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"seasons": seasons})
}

func (s *Server) play(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	id := q.Get("subjectId")
	if id == "" {
		writeErr(w, http.StatusBadRequest, "missing_subject", "query parameter subjectId is required")
		return
	}
	season, err := intParam(q.Get("season"))
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid_season", err.Error())
		return
	}
	episode, err := intParam(q.Get("episode"))
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid_episode", err.Error())
		return
	}
	info, err := s.cat.Play(r.Context(), id, season, episode)
	if err != nil {
		s.fail(w, "play", err)
		return
	}
	writeJSON(w, http.StatusOK, info)
}

func (s *Server) suggestions(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query().Get("q")
	if q == "" {
		writeErr(w, http.StatusBadRequest, "missing_query", "query parameter q is required")
		return
	}
	items, err := s.cat.Suggestions(r.Context(), q)
	if err != nil {
		s.fail(w, "suggestions", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

// intParam parses an optional non-negative integer query value; an absent or
// empty value is zero (movie semantics).
func intParam(raw string) (int, error) {
	if raw == "" {
		return 0, nil
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n < 0 {
		return 0, fmt.Errorf("expected a non-negative integer, got %q", raw)
	}
	return n, nil
}

func (s *Server) fail(w http.ResponseWriter, op string, err error) {
	s.log.Error("request failed", "op", op, "err", err)
	writeErr(w, http.StatusBadGateway, "upstream_error", err.Error())
}

// ListenAndServe runs the server with graceful shutdown handled by the caller.
func (s *Server) ListenAndServe(addr string) error {
	srv := &http.Server{
		Addr:              addr,
		Handler:           s.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
	}
	s.log.Info("listening", "addr", addr)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("X-API-Version", "1")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, status int, code, msg string) {
	writeJSON(w, status, map[string]string{"code": code, "message": msg})
}
