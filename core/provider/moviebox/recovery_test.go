package moviebox

import (
	"context"
	"encoding/base64"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/solo12345689/cinemacore/core/provider"
	"github.com/solo12345689/cinemacore/core/session"
)

func fixture(t *testing.T, name string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatalf("read fixture %s: %v", name, err)
	}
	return string(b)
}

// fixtureProvider serves each fixture body for the first route whose suffix
// matches the request path; anything else is 404, which is how a recovery rung
// is observed to have been skipped.
func fixtureProvider(t *testing.T, routes map[string]string) (*Provider, func()) {
	t.Helper()
	bodies := make(map[string]string, len(routes))
	for suffix, name := range routes {
		bodies[suffix] = fixture(t, name)
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		for suffix, body := range bodies {
			if strings.HasSuffix(r.URL.Path, suffix) {
				w.Header().Set("Content-Type", "application/json")
				_, _ = w.Write([]byte(body))
				return
			}
		}
		http.NotFound(w, r)
	}))
	return New(session.New(session.Config{Hosts: []string{srv.URL}})), srv.Close
}

// TestStream_RejectsRecordedDecoy pins the headline bug: a recorded upstream
// play-info whose only source is the anti-piracy placeholder must never be
// returned as a rendition.
func TestStream_RejectsRecordedDecoy(t *testing.T) {
	p, done := fixtureProvider(t, map[string]string{
		"/play-info": "play-info-decoy.json",
		"/resource":  "resource-movie.json", // its resourceLink is the same decoy
	})
	defer done()

	s, err := p.Stream(context.Background(), "9048868765454191080", 1, 1)
	if err == nil {
		t.Fatalf("Stream returned no error for a decoy-only response: %+v", s)
	}
	if !provider.IsUnavailable(err) {
		t.Fatalf("err = %v (%T), want a typed UnavailableError", err, err)
	}
	if s.URL != "" || len(s.Qualities) != 0 {
		t.Fatalf("decoy leaked into a stream: %+v", s)
	}
	const decoy = "80da52722ee7de7a4303290af6783424"
	for _, q := range s.Qualities {
		if strings.Contains(q.URL, decoy) || strings.Contains(q.URL, "macdn.aoneroom.com/other/") {
			t.Fatalf("decoy rendition returned: %+v", q)
		}
	}
}

func TestStream_RecoversDASHFromSignCookie(t *testing.T) {
	p, done := fixtureProvider(t, map[string]string{"/play-info": "play-info-signed-cookie.json"})
	defer done()

	s, err := p.Stream(context.Background(), "1", 0, 0)
	if err != nil {
		t.Fatalf("Stream: %v", err)
	}
	const want = "https://sbcdn3.hakunaymatata.com/dash/3264772588333157424_0_0_1080_h265_560/index.mpd"
	if s.URL != want {
		t.Fatalf("url = %q, want %q", s.URL, want)
	}
	if len(s.Qualities) != 3 || s.Qualities[0].Label != "1080" || s.Qualities[2].Label != "480" {
		t.Fatalf("qualities = %+v", s.Qualities)
	}
	for _, q := range s.Qualities {
		if q.URL != want {
			t.Fatalf("rendition %q url = %q", q.Label, q.URL)
		}
		if q.Cookie == "" || !strings.Contains(q.Cookie, "urlprefix=") {
			t.Fatalf("rendition %q lost its signCookie: %+v", q.Label, q)
		}
		if q.Size != "1682353414" {
			t.Fatalf("rendition %q size = %q", q.Label, q.Size)
		}
	}
}

func TestStream_RecoversHLSFromSignCookie(t *testing.T) {
	p, done := fixtureProvider(t, map[string]string{"/play-info": "play-info-hls-cookie.json"})
	defer done()

	s, err := p.Stream(context.Background(), "1", 0, 0)
	if err != nil {
		t.Fatalf("Stream: %v", err)
	}
	const want = "https://sbcdn3.hakunaymatata.com/hls/5283420379380335576-1-1-720-946/index.m3u8"
	if s.URL != want {
		t.Fatalf("url = %q, want %q", s.URL, want)
	}
}

func TestStream_UGCDownloadBypass(t *testing.T) {
	p, done := fixtureProvider(t, map[string]string{
		"/play-info":        "play-info-decoy.json",
		"/first-by-subject": "ugc-first-movie.json",
		"/video/download":   "ugc-download-movie.json",
	})
	defer done()

	s, err := p.Stream(context.Background(), "9048868765454191080", 0, 0)
	if err != nil {
		t.Fatalf("Stream: %v", err)
	}
	if !strings.HasPrefix(s.URL, "https://bcdn.hakunaymatata.com/") {
		t.Fatalf("url = %q, want a recovered UGC resource", s.URL)
	}
	if len(s.Qualities) != 4 {
		t.Fatalf("qualities = %+v, want one per UGC resolution", s.Qualities)
	}
	// The collection lists ascending; the adapter sorts high resolution first.
	if s.Qualities[0].Label != "1080" || s.Qualities[3].Label != "360" {
		t.Fatalf("quality order = %+v", s.Qualities)
	}
	if s.Qualities[0].Size == "" {
		t.Fatalf("per-rendition size dropped: %+v", s.Qualities[0])
	}
}

func TestStream_UGCCollectionMatchesEpisode(t *testing.T) {
	p, done := fixtureProvider(t, map[string]string{
		"/play-info":                "play-info-decoy.json",
		"/first-by-subject":         "ugc-first-series.json",
		"/collection/download-list": "ugc-collection-series.json",
	})
	defer done()

	s, err := p.Stream(context.Background(), "985706818477379368", 1, 2)
	if err != nil {
		t.Fatalf("Stream: %v", err)
	}
	if !strings.Contains(s.URL, "4e9b1c40a4e3ff79a618e05b1759bd") {
		t.Fatalf("url = %q, want the S1EP2 resource, not episode 1", s.URL)
	}
}

func TestStream_UGCCollectionEpisodeTokenBoundary(t *testing.T) {
	cases := []struct {
		name    string
		fixture string
		season  int
		episode int
		want    string
	}{
		{
			name:    "episode 2 does not match the S1EP10 prefix",
			fixture: "ugc-collection-s1ep10-first.json",
			season:  1,
			episode: 2,
			want:    "ep2-1080",
		},
		{
			name:    "episode 1 does not match the S1EP10 prefix",
			fixture: "ugc-collection-ep1-ep10.json",
			season:  1,
			episode: 1,
			want:    "ep1-1080",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			p, done := fixtureProvider(t, map[string]string{
				"/play-info":                "play-info-decoy.json",
				"/first-by-subject":         "ugc-first-series.json",
				"/collection/download-list": tc.fixture,
			})
			defer done()

			s, err := p.Stream(context.Background(), "985706818477379368", tc.season, tc.episode)
			if err != nil {
				t.Fatalf("Stream: %v", err)
			}
			if !strings.Contains(s.URL, tc.want) {
				t.Fatalf("url = %q, want the %s resource", s.URL, tc.want)
			}
		})
	}
}

func TestStream_UGCCollectionMissingEpisodeIsUnavailable(t *testing.T) {
	p, done := fixtureProvider(t, map[string]string{
		"/play-info":                "play-info-decoy.json",
		"/first-by-subject":         "ugc-first-series.json",
		"/collection/download-list": "ugc-collection-series.json",
		"/video/download":           "ugc-download-series.json",
	})
	defer done()

	s, err := p.Stream(context.Background(), "985706818477379368", 1, 9)
	if err == nil {
		t.Fatalf("Stream returned the wrong episode for a missing E9: %+v", s)
	}
	if !provider.IsUnavailable(err) {
		t.Fatalf("err = %v (%T), want a typed UnavailableError", err, err)
	}
	if s.URL != "" || len(s.Qualities) != 0 {
		t.Fatalf("wrong-episode source leaked into a stream: %+v", s)
	}
}

func TestStream_UGCSingleVideoFallbackOnlyForEpisodeOne(t *testing.T) {
	p, done := fixtureProvider(t, map[string]string{
		"/play-info":        "play-info-decoy.json",
		"/first-by-subject": "ugc-first-movie.json",
		"/video/download":   "ugc-download-movie.json",
	})
	defer done()
	ctx := context.Background()

	s, err := p.Stream(ctx, "9048868765454191080", 1, 2)
	if err == nil {
		t.Fatalf("Stream returned the single video for episode 2: %+v", s)
	}
	if !provider.IsUnavailable(err) {
		t.Fatalf("err = %v (%T), want a typed UnavailableError", err, err)
	}
	if s.URL != "" {
		t.Fatalf("single video leaked into episode 2: %+v", s)
	}

	for _, tc := range []struct {
		name    string
		season  int
		episode int
	}{
		{name: "movie", season: 0, episode: 0},
		{name: "episode 1", season: 1, episode: 1},
	} {
		s, err := p.Stream(ctx, "9048868765454191080", tc.season, tc.episode)
		if err != nil {
			t.Fatalf("%s: Stream: %v", tc.name, err)
		}
		if !strings.HasPrefix(s.URL, "https://bcdn.hakunaymatata.com/") {
			t.Fatalf("%s: url = %q, want the single video resource", tc.name, s.URL)
		}
	}
}

func TestStream_ResourceListingFiltersEpisode(t *testing.T) {
	p, done := fixtureProvider(t, map[string]string{
		"/play-info": "play-info-decoy.json",
		"/resource":  "resource-series-episodes.json",
	})
	defer done()
	ctx := context.Background()

	s, err := p.Stream(ctx, "985706818477379368", 1, 2)
	if err != nil {
		t.Fatalf("Stream: %v", err)
	}
	if len(s.Qualities) != 1 || !strings.Contains(s.Qualities[0].URL, "ep2-720") {
		t.Fatalf("S1E2 stream = %+v, want only the E2 resource", s)
	}

	missing, err := p.Stream(ctx, "985706818477379368", 1, 3)
	if err == nil {
		t.Fatalf("Stream returned a source for missing E3: %+v", missing)
	}
	if !provider.IsUnavailable(err) {
		t.Fatalf("err = %v (%T), want a typed UnavailableError", err, err)
	}

	movie, err := p.Stream(ctx, "9048868765454191080", 0, 0)
	if err != nil {
		t.Fatalf("movie Stream: %v", err)
	}
	if len(movie.Qualities) != 2 {
		t.Fatalf("movie qualities = %+v, want the whole listing", movie.Qualities)
	}
}

func TestStream_PrefersNonDecoyLaterStream(t *testing.T) {
	const body = `{"code":0,"data":{"streams":[
		{"url":"https://macdn.aoneroom.com/other/2026/10/10/80da52722ee7de7a4303290af6783424.mp4","resolutions":"1080","signCookie":""},
		{"url":"https://cdn.example/real.m3u8","resolutions":"720","size":"42","signCookie":"c=2"}
	]}}`
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(body))
	}))
	defer srv.Close()

	s, err := New(session.New(session.Config{Hosts: []string{srv.URL}})).Stream(context.Background(), "1", 0, 0)
	if err != nil {
		t.Fatalf("Stream: %v", err)
	}
	if s.URL != "https://cdn.example/real.m3u8" || len(s.Qualities) != 1 || s.Qualities[0].Cookie != "c=2" {
		t.Fatalf("stream = %+v", s)
	}
}

// TestEpisodes_CarriesResourceDurations covers the only upstream endpoint that
// exposes per-episode duration; titles stay empty because the reference clients
// expose no canonical per-episode title.
func TestEpisodes_CarriesResourceDurations(t *testing.T) {
	p, done := fixtureProvider(t, map[string]string{
		"/season-info": "season-info-series.json",
		"/resource":    "resource-series.json",
	})
	defer done()

	eps, err := p.Episodes(context.Background(), "985706818477379368")
	if err != nil {
		t.Fatalf("Episodes: %v", err)
	}
	want := []int{5751, 5916, 5882}
	if len(eps) != len(want) {
		t.Fatalf("episodes = %+v, want %d", eps, len(want))
	}
	for i, secs := range want {
		if eps[i].DurationSeconds != secs {
			t.Errorf("ep[%d].DurationSeconds = %d, want %d", i, eps[i].DurationSeconds, secs)
		}
		if eps[i].Title != "" {
			t.Errorf("ep[%d].Title = %q, want empty (no canonical upstream title)", i, eps[i].Title)
		}
	}
}

func TestManifestFromSignCookie(t *testing.T) {
	cloudFront := func(resource string) string {
		policy := `{"Statement":[{"Resource":"` + resource + `"}]}`
		b64 := base64.StdEncoding.EncodeToString([]byte(policy))
		return "CloudFront-Policy=" + strings.NewReplacer("+", "-", "/", "~", "=", "_").Replace(b64)
	}
	decoy := "https://macdn.aoneroom.com/other/2026/10/10/80da52722ee7de7a4303290af6783424.mp4"
	cases := []struct {
		name   string
		cookie string
		want   string
		ok     bool
	}{
		{
			name:   "dash urlprefix from the Rust vector",
			cookie: "Edge-Cache-Cookie=urlprefix=aHR0cHM6Ly9zYmNkbjMuaGFrdW5heW1hdGF0YS5jb20vZGFzaC8zMjY0NzcyNTg4MzMzMTU3NDI0XzBfMF8xMDgwX2gyNjVfNTYwLw:sign=f1a522f7bf4c548c981ad6efa88925ad:t=1789908742",
			want:   "https://sbcdn3.hakunaymatata.com/dash/3264772588333157424_0_0_1080_h265_560/index.mpd",
			ok:     true,
		},
		{
			name:   "hls urlprefix",
			cookie: "Edge-Cache-Cookie=urlprefix=aHR0cHM6Ly9zYmNkbjMuaGFrdW5heW1hdGF0YS5jb20vaGxzLzUyODM0MjAzNzkzODAzMzU1NzYtMS0xLTcyMC05NDYv:sign=abc:t=1791308037",
			want:   "https://sbcdn3.hakunaymatata.com/hls/5283420379380335576-1-1-720-946/index.m3u8",
			ok:     true,
		},
		{
			name:   "cloudfront policy resource",
			cookie: cloudFront("https://cdn.example/dash/tree/"),
			want:   "https://cdn.example/dash/tree/index.mpd",
			ok:     true,
		},
		{
			name:   "signed decoy prefix is not a manifest",
			cookie: "urlprefix=" + base64.RawURLEncoding.EncodeToString([]byte(decoy)) + ":sign=x",
		},
		{
			name:   "cloudfront decoy resource is not a manifest",
			cookie: cloudFront(decoy),
		},
		{name: "unrelated cookie", cookie: "SomeOtherCookie=123"},
		{name: "empty", cookie: ""},
		{name: "undecodable", cookie: "Edge-Cache-Cookie=urlprefix=!!!not-base64!!!:sign=x"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := manifestFromSignCookie(tc.cookie)
			if ok != tc.ok || got != tc.want {
				t.Fatalf("manifestFromSignCookie(%q) = (%q, %v), want (%q, %v)", tc.cookie, got, ok, tc.want, tc.ok)
			}
		})
	}
}

func TestDecoyURL(t *testing.T) {
	cases := []struct {
		url  string
		want bool
	}{
		{"https://macdn.aoneroom.com/other/2026/10/10/80da52722ee7de7a4303290af6783424.mp4", true},
		{"https://cdn.example/notice.mp4", true},
		{"https://cdn.example/please_update.mp4", true},
		{"https://macdn.aoneroom.com/media/video/x.mp4", false},
		{"https://bcdn.hakunaymatata.com/resource/x.mp4?sign=1", false},
		{"", false},
	}
	for _, tc := range cases {
		if got := decoyURL(tc.url); got != tc.want {
			t.Errorf("decoyURL(%q) = %v, want %v", tc.url, got, tc.want)
		}
	}
}
