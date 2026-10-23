package catalog

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/solo12345689/cinemacore/core/models"
)

// webStub answers Stream with a web-embed stream: a kind on the Stream itself
// and on each quality (the form the embed resolver actually returns).
type webStub struct{}

func (webStub) Name() string                                             { return "web-stub" }
func (webStub) Home(context.Context) (models.Page, error)                { return models.Page{}, nil }
func (webStub) Search(context.Context, string) ([]models.Subject, error) { return nil, nil }
func (webStub) Detail(context.Context, string) (models.Subject, error) {
	return models.Subject{}, nil
}
func (webStub) Episodes(context.Context, string) ([]models.Episode, error) {
	return nil, nil
}
func (webStub) Stream(context.Context, string, int, int) (models.Stream, error) {
	return models.Stream{
		URL:  "https://embed.test/embed/movie?tmdb=27205",
		Kind: models.KindWeb,
		Qualities: []models.Quality{
			{Label: "StreamHype Web", URL: "https://embed.test/embed/movie?tmdb=27205", Kind: models.KindWeb},
		},
	}, nil
}
func (webStub) Subtitles(context.Context, string, int) ([]models.Subtitle, error) {
	return nil, nil
}
func (webStub) Suggest(context.Context, string) ([]string, error) { return nil, nil }

// bareKindStub answers Stream with a bare URL and only a stream-level kind —
// the fallback path renditions() takes when the qualities list is empty.
type bareKindStub struct{}

func (bareKindStub) Name() string                                             { return "bare-kind-stub" }
func (bareKindStub) Home(context.Context) (models.Page, error)                { return models.Page{}, nil }
func (bareKindStub) Search(context.Context, string) ([]models.Subject, error) { return nil, nil }
func (bareKindStub) Detail(context.Context, string) (models.Subject, error) {
	return models.Subject{}, nil
}
func (bareKindStub) Episodes(context.Context, string) ([]models.Episode, error) {
	return nil, nil
}
func (bareKindStub) Stream(context.Context, string, int, int) (models.Stream, error) {
	return models.Stream{URL: "https://embed.test/embed/movie?tmdb=1399", Kind: models.KindWeb}, nil
}
func (bareKindStub) Subtitles(context.Context, string, int) ([]models.Subtitle, error) {
	return nil, nil
}
func (bareKindStub) Suggest(context.Context, string) ([]string, error) { return nil, nil }

// TestPlay_PropagatesWebKind pins that a web embed survives the stream ->
// PlayInfo flattening. A rendition that loses its kind reads as media and
// would be handed to a native player or queued as a download of an HTML page.
func TestPlay_PropagatesWebKind(t *testing.T) {
	info, err := New(webStub{}).Play(context.Background(), "1", 0, 0)
	if err != nil {
		t.Fatalf("Play: %v", err)
	}
	if len(info.Streams) != 1 || info.Streams[0].Kind != models.KindWeb {
		t.Fatalf("streams = %+v, want one web rendition", info.Streams)
	}
}

// TestPlay_WebKindOnTheWire pins the serialized field the clients switch on:
// a web rendition says "kind":"web", and a media rendition says nothing at
// all — an explicit "" would be noise, and the clients treat absent as media.
func TestPlay_WebKindOnTheWire(t *testing.T) {
	info, err := New(webStub{}).Play(context.Background(), "1", 0, 0)
	if err != nil {
		t.Fatalf("Play: %v", err)
	}
	body, err := json.Marshal(info.Streams[0])
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if !strings.Contains(string(body), `"kind":"web"`) {
		t.Fatalf("web rendition = %s, want kind on the wire", body)
	}

	media, err := json.Marshal(models.StreamRendition{Quality: "Auto", URL: "https://cdn.test/a.m3u8"})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if strings.Contains(string(media), "kind") {
		t.Fatalf("media rendition = %s, want no kind field", media)
	}
}

// TestPlay_WebKindFromBareStream pins the fallback branch: no qualities, one
// URL, and the stream-level kind carried onto the synthetic rendition.
func TestPlay_WebKindFromBareStream(t *testing.T) {
	info, err := New(bareKindStub{}).Play(context.Background(), "1", 0, 0)
	if err != nil {
		t.Fatalf("Play: %v", err)
	}
	if len(info.Streams) != 1 || info.Streams[0].Kind != models.KindWeb {
		t.Fatalf("streams = %+v, want kind carried from the stream", info.Streams)
	}
	if info.Streams[0].Quality != "Auto" {
		t.Fatalf("quality = %q, want the Auto fallback label", info.Streams[0].Quality)
	}
}
