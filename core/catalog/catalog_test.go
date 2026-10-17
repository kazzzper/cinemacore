package catalog

import (
	"context"
	"testing"

	"github.com/solo12345689/cinemacore/core/models"
)

// streamStub answers only Stream, with per-rendition size and cookie.
type streamStub struct{}

func (streamStub) Name() string                                             { return "stub" }
func (streamStub) Home(context.Context) (models.Page, error)                { return models.Page{}, nil }
func (streamStub) Search(context.Context, string) ([]models.Subject, error) { return nil, nil }
func (streamStub) Detail(context.Context, string) (models.Subject, error) {
	return models.Subject{}, nil
}
func (streamStub) Episodes(context.Context, string) ([]models.Episode, error) {
	return nil, nil
}
func (streamStub) Stream(context.Context, string, int, int) (models.Stream, error) {
	return models.Stream{Qualities: []models.Quality{
		{Label: "1080", URL: "https://cdn.example/1080.m3u8", Size: "10", Cookie: "signed=1080"},
		{Label: "720", URL: "https://cdn.example/720.m3u8", Size: "5", Cookie: "signed=720"},
	}}, nil
}
func (streamStub) Subtitles(context.Context, string, int) ([]models.Subtitle, error) {
	return nil, nil
}
func (streamStub) Suggest(context.Context, string) ([]string, error) { return nil, nil }

// TestPlay_PropagatesRenditionCosts pins that the media cookie and size survive
// the stream -> PlayInfo flattening; the cookie is the CDN's only credential.
func TestPlay_PropagatesRenditionCosts(t *testing.T) {
	info, err := New(streamStub{}).Play(context.Background(), "1", 0, 0)
	if err != nil {
		t.Fatalf("Play: %v", err)
	}
	if len(info.Streams) != 2 {
		t.Fatalf("streams = %+v", info.Streams)
	}
	if info.Streams[0].Cookie != "signed=1080" || info.Streams[0].Size != "10" {
		t.Fatalf("rendition 0 = %+v, want cookie+size preserved", info.Streams[0])
	}
	if info.Streams[1].Cookie != "signed=720" || info.Streams[1].Size != "5" {
		t.Fatalf("rendition 1 = %+v, want cookie+size preserved", info.Streams[1])
	}
}
