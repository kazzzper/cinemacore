package server

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/solo12345689/cinemacore/core/catalog"
	"github.com/solo12345689/cinemacore/core/models"
	"github.com/solo12345689/cinemacore/core/provider"
)

// unavailableProvider resolves nothing playable, like the gateway when it only
// serves its anti-piracy decoy.
type unavailableProvider struct{}

func (unavailableProvider) Name() string                                             { return "unavailable" }
func (unavailableProvider) Home(context.Context) (models.Page, error)                { return models.Page{}, nil }
func (unavailableProvider) Search(context.Context, string) ([]models.Subject, error) { return nil, nil }
func (unavailableProvider) Detail(context.Context, string) (models.Subject, error) {
	return models.Subject{}, nil
}
func (unavailableProvider) Episodes(context.Context, string) ([]models.Episode, error) {
	return nil, nil
}
func (unavailableProvider) Stream(context.Context, string, int, int) (models.Stream, error) {
	return models.Stream{}, &provider.UnavailableError{Provider: "unavailable", Reason: "only a decoy was offered"}
}
func (unavailableProvider) Subtitles(context.Context, string, int) ([]models.Subtitle, error) {
	return nil, nil
}
func (unavailableProvider) Suggest(context.Context, string) ([]string, error) { return nil, nil }

// TestPlay_UnavailableIsTyped502 pins that a refused source is an error the
// caller cannot mistake for a stream, not a 200 with an empty/decoy payload.
func TestPlay_UnavailableIsTyped502(t *testing.T) {
	h := New(Options{Catalog: catalog.New(unavailableProvider{}), Version: "test", SpecPath: "../contracts/openapi.yaml"}).Handler()
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/v1/play?subjectId=1", nil))

	if rec.Code != http.StatusBadGateway {
		t.Fatalf("status = %d, want 502 (%s)", rec.Code, rec.Body.String())
	}
	var body struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body.Code != "stream_unavailable" {
		t.Fatalf("code = %q, want stream_unavailable (%s)", body.Code, rec.Body.String())
	}
}
