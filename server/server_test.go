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
func (stubProvider) Episodes(context.Context, string) ([]models.Episode, error) { return nil, nil }
func (stubProvider) Stream(context.Context, string) (models.Stream, error) {
	return models.Stream{}, nil
}
func (stubProvider) Subtitles(context.Context, string) ([]models.Subtitle, error) {
	return nil, nil
}

func newTestServer() http.Handler {
	return New(Options{Catalog: catalog.New(stubProvider{}), Version: "test"}).Handler()
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
