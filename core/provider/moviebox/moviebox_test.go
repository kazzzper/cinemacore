package moviebox

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/solo12345689/cinemacore/core/models"
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

// gatewayStub is the canned gateway the provider is pointed at. An empty home
// payload makes that route answer 404, which is how the fallback chain is
// exercised without a live network.
type gatewayStub struct {
	tab     string
	getList string

	tabCalls     atomic.Int32
	getListCalls atomic.Int32
}

func stubGateway(stub *gatewayStub) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case strings.HasSuffix(r.URL.Path, "/home/v2/get-list"):
			stub.getListCalls.Add(1)
			if stub.getList == "" {
				http.NotFound(w, r)
				return
			}
			_, _ = w.Write([]byte(stub.getList))
		case strings.HasSuffix(r.URL.Path, "/tab-operating"):
			stub.tabCalls.Add(1)
			if stub.tab == "" {
				http.NotFound(w, r)
				return
			}
			_, _ = w.Write([]byte(stub.tab))
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

// homeFixture reads a recorded upstream payload from testdata.
func homeFixture(t *testing.T, name string) string {
	t.Helper()
	b, err := os.ReadFile("testdata/" + name)
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	return string(b)
}

// TestHomeMapsUpstreamRails is the guard for the rail layout: one Section per
// non-empty upstream row, in upstream order, with the upstream titles.
func TestHomeMapsUpstreamRails(t *testing.T) {
	srv := stubGateway(&gatewayStub{tab: homeFixture(t, "tab-operating.json")})
	defer srv.Close()

	page, err := newProvider(t, srv).Home(context.Background())
	if err != nil {
		t.Fatalf("Home: %v", err)
	}
	// "Categories" (FILTER) and "Movies in Minutes" (POST_LIST, UGC posts) carry
	// no subject and must not become blank sections.
	want := []struct {
		title string
		items int
	}{
		{"IN Banner", 1},
		{"Trending Movies", 2},
		{"Gems for you", 3},
		{"🔥Trending Now", 2},
	}
	if len(page.Sections) != len(want) {
		t.Fatalf("sections = %d (%+v), want %d", len(page.Sections), titles(page.Sections), len(want))
	}
	for i, w := range want {
		if page.Sections[i].Title != w.title || len(page.Sections[i].Items) != w.items {
			t.Errorf("section[%d] = %q items=%d, want %q items=%d",
				i, page.Sections[i].Title, len(page.Sections[i].Items), w.title, w.items)
		}
	}

	// The banner card is a wrapper around a real subject; its id must be the
	// subject's, not the teaser's.
	banner := page.Sections[0].Items[0]
	if banner.ID != "3908280950886646112" || banner.Title != "VisionQuest [Hindi]" {
		t.Errorf("banner subject = %+v", banner)
	}
	// rankingListData nests its subjects one level deeper.
	ranked := page.Sections[1].Items[0]
	if ranked.ID != "9107376937579734040" || ranked.Title != "DC [Hindi]" || ranked.Kind != "movie" {
		t.Errorf("ranked subject = %+v", ranked)
	}
	if ranked.DurationMinutes != 150 || ranked.Rating != 8.1 || ranked.Year != 2026 {
		t.Errorf("ranked scalars = %+v", ranked)
	}
	// The layout carries duration in "seconds", and genres as one comma string.
	gems := page.Sections[2].Items[0]
	if gems.Title != "Sleepy Princess in the Demon Castle [English]" || gems.Kind != "series" {
		t.Errorf("gems subject = %+v", gems)
	}
	if len(gems.Genres) != 3 || gems.Genres[0] != "Anime" {
		t.Errorf("gems genres = %v", gems.Genres)
	}
}

// TestHomeFallsBackToDailyRec covers the last-resort feed: when both layout
// routes fail, daily-movie-rec still answers, as the single "Top Picks" rail.
func TestHomeFallsBackToDailyRec(t *testing.T) {
	srv := stubGateway(&gatewayStub{})
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

// TestHomePrefersGetListRails checks the documented route wins when a cluster
// serves it, using the rail shape the reference proxy produces.
func TestHomePrefersGetListRails(t *testing.T) {
	stub := &gatewayStub{
		getList: `{"code":0,"data":{"list":[{"title":"Movies","items":[` + subjectJSON + `]}]}}`,
		tab:     homeFixture(t, "tab-operating.json"),
	}
	srv := stubGateway(stub)
	defer srv.Close()

	page, err := newProvider(t, srv).Home(context.Background())
	if err != nil {
		t.Fatalf("Home: %v", err)
	}
	if len(page.Sections) != 1 || page.Sections[0].Title != "Movies" || page.Sections[0].Items[0].ID != "42" {
		t.Fatalf("sections = %+v", page.Sections)
	}
	if n := stub.tabCalls.Load(); n != 0 {
		t.Errorf("tab-operating called %d times, want 0", n)
	}
	if n := stub.getListCalls.Load(); n != 1 {
		t.Errorf("get-list called %d times, want 1", n)
	}
}

// TestToSubjectReadsLayoutOnlyFields guards the tolerant mapping the layout
// relies on: a string kind, a seasonCount, a "seconds" duration and the
// protocol-relative poster URL some endpoints return.
func TestToSubjectReadsLayoutOnlyFields(t *testing.T) {
	var w wireSubject
	raw := `{"subjectId":"7","kind":"series","seasonCount":3,"name":"Fallback Name",
	         "seconds":1800,"cover":{"url":"//cdn.example/p.jpg"}}`
	if err := json.Unmarshal([]byte(raw), &w); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	s := w.toSubject()
	if s.ID != "7" || s.Title != "Fallback Name" || s.Kind != "series" {
		t.Fatalf("subject = %+v", s)
	}
	if s.Poster != "https://cdn.example/p.jpg" {
		t.Errorf("poster = %q, want https://cdn.example/p.jpg", s.Poster)
	}
	if s.SeasonCount != 3 || s.DurationMinutes != 30 {
		t.Errorf("seasonCount=%d durationMinutes=%d, want 3 and 30", s.SeasonCount, s.DurationMinutes)
	}
}

func TestEpisodesExpandsAllEpAndMaxEp(t *testing.T) {
	srv := stubGateway(&gatewayStub{})
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
	srv := stubGateway(&gatewayStub{})
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
	srv := stubGateway(&gatewayStub{})
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
	srv := stubGateway(&gatewayStub{})
	defer srv.Close()

	terms, err := newProvider(t, srv).Suggest(context.Background(), "dune")
	if err != nil {
		t.Fatalf("Suggest: %v", err)
	}
	if len(terms) != 2 || terms[0] != "Dune" || terms[1] != "Dune: Part Two" {
		t.Fatalf("terms = %v", terms)
	}
}

func TestSearchMapsItems(t *testing.T) {
	srv := stubGateway(&gatewayStub{})
	defer srv.Close()

	items, err := newProvider(t, srv).Search(context.Background(), "dune")
	if err != nil {
		t.Fatalf("Search: %v", err)
	}
	if len(items) != 1 || items[0].ID != "42" || items[0].Kind != "series" {
		t.Fatalf("items = %+v", items)
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

func titles(sections []models.Section) []string {
	out := make([]string, 0, len(sections))
	for _, s := range sections {
		out = append(out, s.Title)
	}
	return out
}
