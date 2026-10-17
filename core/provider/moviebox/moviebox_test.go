package moviebox

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/solo12345689/cinemacore/core/session"
)

const subjectJSON = `{
  "subjectId":"42","subjectType":2,"title":"Dune","description":"Spice.","releaseDate":"2021-10-22",
  "durationSeconds":9300,"genre":"Sci-Fi, Adventure","cover":{"url":"https://img.example/p.jpg"},
  "imdbRatingValue":"8.0","seNum":2,
  "staffList":[{"name":"Denis Villeneuve","character":"Director","avatarUrl":"https://img.example/a.jpg"}],
  "dubs":[{"lanName":"English"}],
  "resourceDetectors":[{"resourceId":"r1","source":"example.cdn"}]
}`

// stubGateway serves the canned gateway envelopes for every provider path.
func stubGateway() *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case strings.HasSuffix(r.URL.Path, "/daily-movie-rec"):
			_, _ = w.Write([]byte(`{"code":0,"data":{"items":[` + subjectJSON + `]}}`))
		case strings.HasSuffix(r.URL.Path, "/search"):
			_, _ = w.Write([]byte(`{"code":0,"data":{"items":[` + subjectJSON + `]}}`))
		case strings.HasSuffix(r.URL.Path, "/get"):
			_, _ = w.Write([]byte(`{"code":0,"data":` + subjectJSON + `}`))
		case strings.HasSuffix(r.URL.Path, "/season-info"):
			_, _ = w.Write([]byte(`{"code":0,"data":{"seasons":[{"se":1,"maxEp":3},{"se":2,"maxEp":3,"allEp":"1,3"}]}}`))
		case strings.HasSuffix(r.URL.Path, "/play-info"):
			_, _ = w.Write([]byte(`{"code":0,"data":{"streams":[{"url":"https://cdn.example/x.m3u8","resolutions":"1080,720","signCookie":"c=1"}]}}`))
		case strings.HasSuffix(r.URL.Path, "/get-ext-captions"):
			_, _ = w.Write([]byte(`{"code":0,"data":{"extCaptions":[{"lan":"en","lanName":"English","url":"https://cdn.example/en.srt"}]}}`))
		case strings.HasSuffix(r.URL.Path, "/search-suggest"):
			_, _ = w.Write([]byte(`{"code":0,"data":{"items":[{"word":"Dune"},{"word":"Dune: Part Two"}]}}`))
		default:
			http.NotFound(w, r)
		}
	}))
}

func newProvider(t *testing.T, srv *httptest.Server) *Provider {
	t.Helper()
	return New(session.New(session.Config{Hosts: []string{srv.URL}}))
}

func TestHomeMapsItems(t *testing.T) {
	srv := stubGateway()
	defer srv.Close()

	page, err := newProvider(t, srv).Home(context.Background())
	if err != nil {
		t.Fatalf("Home: %v", err)
	}
	if len(page.Sections) != 1 || page.Sections[0].Title != "Top Picks" {
		t.Fatalf("sections = %+v", page.Sections)
	}
	s := page.Sections[0].Items[0]
	if s.ID != "42" || s.Title != "Dune" || s.Poster != "https://img.example/p.jpg" {
		t.Fatalf("subject = %+v", s)
	}
	if s.Year != 2021 || s.Rating != 8.0 || s.Kind != "series" || s.DurationMinutes != 155 || s.SeasonCount != 2 {
		t.Fatalf("scalars = %+v", s)
	}
	if len(s.Genres) != 2 || s.Genres[0] != "Sci-Fi" || s.Genres[1] != "Adventure" {
		t.Fatalf("genres = %v", s.Genres)
	}
	if len(s.Cast) != 1 || s.Cast[0].Name != "Denis Villeneuve" || s.Cast[0].Role != "Director" {
		t.Fatalf("cast = %+v", s.Cast)
	}
	if len(s.Dubs) != 1 || s.Dubs[0] != "English" {
		t.Fatalf("dubs = %v", s.Dubs)
	}
	if len(s.ResourceDetectors) != 1 || s.ResourceDetectors[0].ResourceID != "r1" {
		t.Fatalf("detectors = %+v", s.ResourceDetectors)
	}
}

func TestEpisodesExpandsAllEpAndMaxEp(t *testing.T) {
	srv := stubGateway()
	defer srv.Close()

	eps, err := newProvider(t, srv).Episodes(context.Background(), "42")
	if err != nil {
		t.Fatalf("Episodes: %v", err)
	}
	// Season 1 -> 1,2,3 ; Season 2 -> allEp "1,3".
	want := []struct {
		season, number int
	}{{1, 1}, {1, 2}, {1, 3}, {2, 1}, {2, 3}}
	if len(eps) != len(want) {
		t.Fatalf("episodes = %+v, want %d", eps, len(want))
	}
	for i, w := range want {
		if eps[i].Season != w.season || eps[i].Number != w.number || eps[i].SubjectID != "42" {
			t.Errorf("ep[%d] = %+v, want s%d e%d", i, eps[i], w.season, w.number)
		}
	}
}

func TestStreamMapsRenditions(t *testing.T) {
	srv := stubGateway()
	defer srv.Close()

	s, err := newProvider(t, srv).Stream(context.Background(), "42", 1, 1)
	if err != nil {
		t.Fatalf("Stream: %v", err)
	}
	if s.URL != "https://cdn.example/x.m3u8" {
		t.Fatalf("url = %q", s.URL)
	}
	if len(s.Qualities) != 2 || s.Qualities[0].Label != "1080" || s.Qualities[1].Label != "720" {
		t.Fatalf("qualities = %+v", s.Qualities)
	}
	if s.Headers["Cookie"] != "c=1" {
		t.Fatalf("headers = %+v", s.Headers)
	}
}

func TestSubtitlesFromExtCaptions(t *testing.T) {
	srv := stubGateway()
	defer srv.Close()

	subs, err := newProvider(t, srv).Subtitles(context.Background(), "42", 1)
	if err != nil {
		t.Fatalf("Subtitles: %v", err)
	}
	if len(subs) != 1 || subs[0].Lang != "English" || subs[0].Format != "srt" {
		t.Fatalf("subtitles = %+v", subs)
	}
}

func TestSuggestReturnsWords(t *testing.T) {
	srv := stubGateway()
	defer srv.Close()

	terms, err := newProvider(t, srv).Suggest(context.Background(), "dune")
	if err != nil {
		t.Fatalf("Suggest: %v", err)
	}
	if len(terms) != 2 || terms[0] != "Dune" || terms[1] != "Dune: Part Two" {
		t.Fatalf("terms = %v", terms)
	}
}

func TestDurationMinutesFallsBackToHuman(t *testing.T) {
	if got := durationMinutes(0, "1h 33m"); got != 93 {
		t.Errorf("durationMinutes(1h 33m) = %d, want 93", got)
	}
	if got := durationMinutes(0, "45m"); got != 45 {
		t.Errorf("durationMinutes(45m) = %d, want 45", got)
	}
}
