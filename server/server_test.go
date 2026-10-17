package server

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/solo12345689/cinemacore/core/catalog"
	"github.com/solo12345689/cinemacore/core/models"
)

type stubProvider struct{}

func (stubProvider) Name() string { return "stub" }
func (stubProvider) Home(context.Context) (models.Page, error) {
	return models.Page{Sections: []models.Section{{Title: "Trending", Items: []models.Subject{{ID: "1", Title: "Dune"}}}}}, nil
}
func (stubProvider) Search(_ context.Context, q string) ([]models.Subject, error) {
	return []models.Subject{{ID: q, Title: q}}, nil
}
func (stubProvider) Detail(_ context.Context, id string) (models.Subject, error) {
	return models.Subject{ID: id, Title: "Detail " + id}, nil
}
func (stubProvider) Episodes(context.Context, string) ([]models.Episode, error) {
	return []models.Episode{
		{SubjectID: "1", Season: 2, Number: 1, Title: "S2E1"},
		{SubjectID: "1", Season: 1, Number: 2, Title: "S1E2"},
		{SubjectID: "1", Season: 1, Number: 1, Title: "S1E1"},
	}, nil
}
func (stubProvider) Stream(context.Context, string, int, int) (models.Stream, error) {
	return models.Stream{
		URL:       "https://cdn.example/master.m3u8",
		Qualities: []models.Quality{{Label: "Auto", URL: "https://cdn.example/auto.m3u8"}},
	}, nil
}
func (stubProvider) Subtitles(context.Context, string, int) ([]models.Subtitle, error) {
	return []models.Subtitle{
		{Lang: "English", URL: "https://cdn.example/en.vtt", Format: "vtt"},
	}, nil
}
func (stubProvider) Suggest(_ context.Context, q string) ([]string, error) {
	return []string{q}, nil
}

func newTestServer() http.Handler {
	return New(Options{
		Catalog:  catalog.New(stubProvider{}),
		Version:  "test",
		SpecPath: "../contracts/openapi.yaml",
	}).Handler()
}

func TestHealth(t *testing.T) {
	rec := httptest.NewRecorder()
	newTestServer().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/health", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
}

func TestHome(t *testing.T) {
	rec := httptest.NewRecorder()
	newTestServer().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/v1/home", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	var page models.Page
	if err := json.Unmarshal(rec.Body.Bytes(), &page); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(page.Sections) != 1 || page.Sections[0].Items[0].Title != "Dune" {
		t.Fatalf("unexpected page: %+v", page)
	}
}

func TestSearchRequiresQuery(t *testing.T) {
	rec := httptest.NewRecorder()
	newTestServer().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/v1/search", nil))
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", rec.Code)
	}
}

// TestContractRoutes_EveryPathServed is the conformance gate: every path in
// contracts/openapi.yaml must be routed and answer 200 with the version header.
func TestContractRoutes_EveryPathServed(t *testing.T) {
	targets := []struct {
		name   string
		target string
	}{
		{"health", "/health"},
		{"version", "/version"},
		{"openapi", "/openapi.json"},
		{"home", "/v1/home"},
		{"search", "/v1/search?q=dune"},
		{"search_suggestions", "/v1/search/suggestions?q=dune"},
		{"detail", "/v1/detail/1"},
		{"detail_seasons", "/v1/detail/1/seasons"},
		{"play", "/v1/play?subjectId=1&season=1&episode=2"},
	}
	for _, tc := range targets {
		t.Run(tc.name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			newTestServer().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, tc.target, nil))
			if rec.Code != http.StatusOK {
				t.Fatalf("%s: status = %d, want 200 (body %s)", tc.target, rec.Code, rec.Body.String())
			}
			if got := rec.Header().Get("X-API-Version"); got != "1" {
				t.Errorf("%s: X-API-Version = %q, want 1", tc.target, got)
			}
		})
	}
}

func TestSeasons_GroupsBySeasonAscending(t *testing.T) {
	rec := httptest.NewRecorder()
	newTestServer().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/v1/detail/1/seasons", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	var out struct {
		Seasons []models.Season `json:"seasons"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(out.Seasons) != 2 {
		t.Fatalf("seasons = %d, want 2 (%s)", len(out.Seasons), rec.Body.String())
	}
	if out.Seasons[0].Number != 1 || out.Seasons[1].Number != 2 {
		t.Fatalf("season order = [%d %d], want [1 2]", out.Seasons[0].Number, out.Seasons[1].Number)
	}
	if got := out.Seasons[0].Episodes; len(got) != 2 || got[0].Number != 1 || got[1].Number != 2 {
		t.Fatalf("season 1 episodes not ascending: %+v", got)
	}
}

func TestPlay_MapsStreamsAndSubtitles(t *testing.T) {
	rec := httptest.NewRecorder()
	newTestServer().ServeHTTP(
		rec, httptest.NewRequest(http.MethodGet, "/v1/play?subjectId=1&season=1&episode=2", nil),
	)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (%s)", rec.Code, rec.Body.String())
	}
	var info models.PlayInfo
	if err := json.Unmarshal(rec.Body.Bytes(), &info); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(info.Streams) != 1 || info.Streams[0].Quality != "Auto" {
		t.Fatalf("streams = %+v, want one Auto rendition", info.Streams)
	}
	if len(info.Subtitles) != 1 || info.Subtitles[0].Language != "English" {
		t.Fatalf("subtitles = %+v, want one English track", info.Subtitles)
	}
	if ctype := rec.Header().Get("Content-Type"); ctype != "application/json; charset=utf-8" {
		t.Errorf("Content-Type = %q", ctype)
	}
}

func TestPlay_RequiresSubject(t *testing.T) {
	rec := httptest.NewRecorder()
	newTestServer().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/v1/play", nil))
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", rec.Code)
	}
}

func TestPlay_RejectsInvalidSeason(t *testing.T) {
	rec := httptest.NewRecorder()
	newTestServer().ServeHTTP(
		rec, httptest.NewRequest(http.MethodGet, "/v1/play?subjectId=1&season=abc", nil),
	)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", rec.Code)
	}
}

func TestSuggestions_RequiresQuery(t *testing.T) {
	rec := httptest.NewRecorder()
	newTestServer().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/v1/search/suggestions", nil))
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", rec.Code)
	}
}

func TestSuggestions_FromProvider(t *testing.T) {
	rec := httptest.NewRecorder()
	newTestServer().ServeHTTP(
		rec, httptest.NewRequest(http.MethodGet, "/v1/search/suggestions?q=dune", nil),
	)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	var out struct {
		Items []string `json:"items"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(out.Items) != 1 || out.Items[0] != "dune" {
		t.Fatalf("items = %v, want [dune]", out.Items)
	}
}
