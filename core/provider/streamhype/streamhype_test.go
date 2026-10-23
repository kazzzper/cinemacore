package streamhype

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"github.com/solo12345689/cinemacore/core/models"
	"github.com/solo12345689/cinemacore/core/provider"
)

const movieDetail = `{
  "id": 27205,
  "title": "Inception",
  "name": "WRONG NAME",
  "overview": "A thief who steals corporate secrets.",
  "poster_path": "/9gk7ps.jpg",
  "vote_average": 8.4,
  "runtime": 148,
  "release_date": "2010-07-16",
  "genres": [{"name": "Action"}, {"name": "Sci-Fi"}]
}`

const tvDetail = `{
  "id": 1399,
  "title": "WRONG TITLE",
  "name": "Game of Thrones",
  "overview": "Seven noble families.",
  "poster_path": "/1sp.jpg",
  "vote_average": 8.5,
  "release_date": "",
  "first_air_date": "2011-04-17",
  "genres": [{"name": "Drama"}, {"name": "Fantasy"}],
  "seasons": [
    {"season_number": 0, "episode_count": 0, "name": "Specials"},
    {"season_number": 1, "episode_count": 10, "name": "Season 1"},
    {"season_number": 2, "episode_count": 10, "name": "Season 2"}
  ]
}`

const seasonOne = `{
  "episodes": [
    {"episode_number": 1, "name": "Winter Is Coming", "runtime": 62},
    {"episode_number": 2, "name": "The Kingsroad", "runtime": 56}
  ]
}`

// tmdbStub answers the paths the provider reads. `servers` distinguishes
// multi-search from the fixed list endpoints, which TMDB types differently.
type tmdbStub struct {
	movies   string            // /movie/{id}
	tv       string            // /tv/{id}
	seasons  map[string]string // "/tv/1399/season/<n>"
	search   string            // /search/multi
	lists    map[string]string // fixed list endpoints (home rails)
	requests []string
}

func stubTMDB(stub *tmdbStub) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		stub.requests = append(stub.requests, r.URL.Path)
		if key := r.URL.Query().Get("api_key"); key != "test-key" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		body, ok := "", false
		switch {
		case isDetail(r.URL.Path, "movie"):
			body, ok = stub.movies, stub.movies != ""
		case isDetail(r.URL.Path, "tv"):
			body, ok = stub.tv, stub.tv != ""
		case strings.Contains(r.URL.Path, "/season/"):
			body, ok = stub.seasons[r.URL.Path], stub.seasons != nil
		case r.URL.Path == "/search/multi":
			body, ok = stub.search, stub.search != ""
		default:
			body, ok = stub.lists[r.URL.Path], stub.lists != nil
		}
		if !ok {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(body))
	}))
}

// isDetail matches a detail path — "/movie/27205", "/tv/1399" — by its
// numeric final segment, so list endpoints under the same prefix
// ("/movie/popular"), are not mistaken for the detail payload.
func isDetail(path, kind string) bool {
	prefix := "/" + kind + "/"
	if !strings.HasPrefix(path, prefix) {
		return false
	}
	tail := path[len(prefix):]
	for _, r := range tail {
		if r < '0' || r > '9' {
			return false
		}
	}
	return tail != ""
}

func newProvider(srv *httptest.Server) *Provider {
	return &Provider{
		apiKey:    "test-key",
		client:    srv.Client(),
		apiBase:   srv.URL,
		embedBase: "https://embed.test/",
	}
}

const searchMulti = `{
  "results": [
    {"id": 27205, "media_type": "movie", "title": "Inception", "overview": "Dreams.",
     "poster_path": "/9gk7ps.jpg", "vote_average": 8.4, "release_date": "2010-07-16"},
    {"id": 1234, "media_type": "person", "name": "Christopher Nolan"},
    {"id": 1399, "media_type": "tv", "name": "Game of Thrones", "poster_path": "/1sp.jpg",
     "vote_average": 8.5, "first_air_date": "2011-04-17"}
  ]
}`

// TestSearchMapsTypedEntriesOnly guards multi-search mapping: media_type
// decides the id namespace, person entries are dropped.
func TestSearchMapsTypedEntriesOnly(t *testing.T) {
	srv := stubTMDB(&tmdbStub{search: searchMulti})
	defer srv.Close()

	items, err := newProvider(srv).Search(context.Background(), "inception")
	if err != nil {
		t.Fatalf("Search: %v", err)
	}
	if len(items) != 2 {
		t.Fatalf("items = %+v, want 2", items)
	}
	if items[0].ID != "tmdb-movie-27205" || items[0].Title != "Inception" ||
		items[0].Kind != "movie" || items[0].Year != 2010 || items[0].Rating != 8.4 {
		t.Errorf("items[0] = %+v", items[0])
	}
	if items[0].Poster != ImageBase+"/w780/9gk7ps.jpg" {
		t.Errorf("poster = %q", items[0].Poster)
	}
	if items[1].ID != "tmdb-tv-1399" || items[1].Title != "Game of Thrones" || items[1].Kind != "series" {
		t.Errorf("items[1] = %+v", items[1])
	}
}

func searchMovie(id int) string {
	return fmt.Sprintf(`{"results":[{"id":%d,"media_type":"movie","title":"Movie %d"}]}`, id, id)
}

// TestSearchSkipsUntypedEntriesWithoutFallback guards the untyped branch: with
// no fallback media type, an entry that does not name its own is dropped
// rather than guessed into the movie namespace.
func TestSearchSkipsUntypedEntriesWithoutFallback(t *testing.T) {
	srv := stubTMDB(&tmdbStub{search: `{"results":[{"id":1,"name":"A Person"}]}`})
	defer srv.Close()

	items, err := newProvider(srv).Search(context.Background(), "x")
	if err != nil {
		t.Fatalf("Search: %v", err)
	}
	if len(items) != 0 {
		t.Fatalf("items = %+v, want empty", items)
	}
}

func TestHomeMapsFixedListRails(t *testing.T) {
	stub := &tmdbStub{lists: map[string]string{
		"/trending/movie/week": searchMovie(1),
		"/movie/popular":       searchMovie(2),
		"/tv/popular":          `{"results":[{"id":3,"media_type":"tv","name":"Series"}]}`,
		"/movie/top_rated":     searchMovie(4),
	}}
	srv := stubTMDB(stub)
	defer srv.Close()

	page, err := newProvider(srv).Home(context.Background())
	if err != nil {
		t.Fatalf("Home: %v", err)
	}
	want := []struct{ title, id, kind string }{
		{"Trending Now", "tmdb-movie-1", "movie"},
		{"Popular Movies", "tmdb-movie-2", "movie"},
		{"Popular TV", "tmdb-tv-3", "series"},
		{"Top Rated", "tmdb-movie-4", "movie"},
	}
	if len(page.Sections) != len(want) {
		t.Fatalf("sections = %+v", page.Sections)
	}
	for i, w := range want {
		s := page.Sections[i]
		if s.Title != w.title || len(s.Items) != 1 || s.Items[0].ID != w.id || s.Items[0].Kind != w.kind {
			t.Errorf("section[%d] = %+v, want %q %q %q", i, s, w.title, w.id, w.kind)
		}
	}
}

func TestHomeSurvivesOneDeadRail(t *testing.T) {
	stub := &tmdbStub{lists: map[string]string{
		"/trending/movie/week": searchMovie(1),
		"/movie/popular":       "",
		"/tv/popular":          "",
		"/movie/top_rated":     searchMovie(4),
	}}
	srv := stubTMDB(stub)
	defer srv.Close()

	page, err := newProvider(srv).Home(context.Background())
	if err != nil {
		t.Fatalf("Home: %v", err)
	}
	if len(page.Sections) != 2 {
		t.Fatalf("sections = %+v", page.Sections)
	}
}

func TestHomeFailsLoudWhenAllRailsDead(t *testing.T) {
	srv := stubTMDB(&tmdbStub{})
	defer srv.Close()

	if _, err := newProvider(srv).Home(context.Background()); err == nil {
		t.Fatal("Home succeeded with every rail dead")
	}
}

// TestDetailMovieReadsMoviePayload checks the movie branch: title wins over
// name, runtime the duration, year from release_date.
func TestDetailMovieReadsMoviePayload(t *testing.T) {
	srv := stubTMDB(&tmdbStub{movies: movieDetail})
	defer srv.Close()

	s, err := newProvider(srv).Detail(context.Background(), "tmdb-movie-27205")
	if err != nil {
		t.Fatalf("Detail: %v", err)
	}
	if s.ID != "tmdb-movie-27205" || s.Title != "Inception" || s.Kind != "movie" {
		t.Fatalf("subject = %+v", s)
	}
	if s.Year != 2010 || s.Rating != 8.4 || s.DurationMinutes != 148 ||
		s.Synopsis != "A thief who steals corporate secrets." {
		t.Errorf("scalars = %+v", s)
	}
	if len(s.Genres) != 2 || s.Genres[0] != "Action" {
		t.Errorf("genres = %v", s.Genres)
	}
	if s.Poster != ImageBase+"/w780/9gk7ps.jpg" {
		t.Errorf("poster = %q", s.Poster)
	}
	if s.SeasonCount != 1 {
		t.Errorf("seasonCount = %d, want 1 for a movie", s.SeasonCount)
	}
}

func TestDetailTVReadsTVPayload(t *testing.T) {
	srv := stubTMDB(&tmdbStub{tv: tvDetail})
	defer srv.Close()

	s, err := newProvider(srv).Detail(context.Background(), "tmdb-tv-1399")
	if err != nil {
		t.Fatalf("Detail: %v", err)
	}
	if s.Title != "Game of Thrones" || s.Kind != "series" || s.Year != 2011 ||
		s.DurationMinutes != 0 {
		t.Fatalf("subject = %+v", s)
	}
	if s.SeasonCount != 2 {
		t.Errorf("seasonCount = %d, want 2 (season 0 excluded)", s.SeasonCount)
	}
}

func TestEpisodesExpandSeasonsAndSkipSpecials(t *testing.T) {
	srv := stubTMDB(&tmdbStub{tv: tvDetail, seasons: map[string]string{
		"/tv/1399/season/1": seasonOne,
		"/tv/1399/season/2": seasonOne,
	}})
	defer srv.Close()

	eps, err := newProvider(srv).Episodes(context.Background(), "tmdb-tv-1399")
	if err != nil {
		t.Fatalf("Episodes: %v", err)
	}
	if len(eps) != 4 {
		t.Fatalf("episodes = %+v, want 4", eps)
	}
	for i, w := range []struct{ season, number int }{
		{1, 1}, {1, 2}, {2, 1}, {2, 2},
	} {
		if eps[i].Season != w.season || eps[i].Number != w.number || eps[i].SubjectID != "tmdb-tv-1399" {
			t.Errorf("ep[%d] = %+v, want s%d e%d", i, eps[i], w.season, w.number)
		}
	}
	if eps[0].Title != "Winter Is Coming" || eps[0].DurationSeconds != 62*60 {
		t.Errorf("ep[0] = %+v", eps[0])
	}
}

func TestEpisodesRejectsMovies(t *testing.T) {
	srv := stubTMDB(&tmdbStub{})
	defer srv.Close()

	_, err := newProvider(srv).Episodes(context.Background(), "tmdb-movie-27205")
	if !provider.IsUnavailable(err) {
		t.Fatalf("err = %v, want UnavailableError", err)
	}
}

// TestStreamBuildsEmbedURL checks the playback answer: a KindWeb rendition
// against the vidsrc-family façade, with season/episode only on TV. `o`
// carries the attribution the SPA's own embed URLs carry.
func TestStreamBuildsEmbedURL(t *testing.T) {
	srv := stubTMDB(&tmdbStub{})
	defer srv.Close()
	p := newProvider(srv)

	movieStream, err := p.Stream(context.Background(), "tmdb-movie-27205", 0, 0)
	if err != nil {
		t.Fatalf("movie Stream: %v", err)
	}
	if movieStream.Kind != models.KindWeb {
		t.Fatalf("kind = %q, want %q", movieStream.Kind, models.KindWeb)
	}
	if got, want := movieStream.URL, "https://embed.test/embed/movie?o=streamhype.net&tmdb=27205"; got != want {
		t.Fatalf("movie url = %q, want %q", got, want)
	}
	if len(movieStream.Qualities) != 1 ||
		movieStream.Qualities[0].Kind != models.KindWeb ||
		movieStream.Qualities[0].URL != movieStream.URL {
		t.Fatalf("qualities = %+v", movieStream.Qualities)
	}

	tvStream, err := p.Stream(context.Background(), "tmdb-tv-1399", 1, 2)
	if err != nil {
		t.Fatalf("tv Stream: %v", err)
	}
	if got, want := tvStream.URL, "https://embed.test/embed/tv?episode=2&o=streamhype.net&season=1&tmdb=1399"; got != want {
		t.Fatalf("tv url = %q, want %q", got, want)
	}

	// A series played without episode numbers still points at the first
	// episode rather than an unparameterized embed.
	tvStream0, err := p.Stream(context.Background(), "tmdb-tv-1399", 0, 0)
	if err != nil {
		t.Fatalf("tv Stream: %v", err)
	}
	if q := mustQuery(t, tvStream0.URL); q.Get("season") != "1" || q.Get("episode") != "1" {
		t.Fatalf("degenerate tv url = %q", tvStream0.URL)
	}
}

func TestSubtitlesAreEmptyAndHonest(t *testing.T) {
	srv := stubTMDB(&tmdbStub{})
	defer srv.Close()

	subs, err := newProvider(srv).Subtitles(context.Background(), "tmdb-movie-27205", 0)
	if err != nil {
		t.Fatalf("Subtitles: %v", err)
	}
	if subs != nil {
		t.Fatalf("subtitles = %+v, want none", subs)
	}
}

func TestSuggestReturnsTitles(t *testing.T) {
	srv := stubTMDB(&tmdbStub{search: searchMulti})
	defer srv.Close()

	terms, err := newProvider(srv).Suggest(context.Background(), "inc")
	if err != nil {
		t.Fatalf("Suggest: %v", err)
	}
	if len(terms) != 2 || terms[0] != "Inception" || terms[1] != "Game of Thrones" {
		t.Fatalf("terms = %v", terms)
	}
}

// TestDetailUnknownTenant guards the id namespace: foreign ids (e.g. a
// MovieBox subject id) are unavailable, not a silent wrong-source lookup.
func TestDetailRejectsForeignIDs(t *testing.T) {
	srv := stubTMDB(&tmdbStub{})
	defer srv.Close()

	for _, id := range []string{"42", "tmdb-person-123", "tmdb-movie-zero", "tmdb-movie-"} {
		_, err := newProvider(srv).Detail(context.Background(), id)
		if !provider.IsUnavailable(err) {
			t.Errorf("Detail(%q) err = %v, want UnavailableError", id, err)
		}
	}
}

// TestNotFoundIsUnavailable guards the 404 branch: a TMDB id that answers 404
// is a title the provider cannot serve, not a transport failure.
func TestNotFoundIsUnavailable(t *testing.T) {
	srv := stubTMDB(&tmdbStub{})
	defer srv.Close()

	_, err := newProvider(srv).Detail(context.Background(), "tmdb-movie-99999")
	if !provider.IsUnavailable(err) {
		t.Fatalf("err = %v, want UnavailableError", err)
	}
}

// TestIDsRoundTrip keeps the namespace contract honest: idOf then parseID
// returns the same numbers for both media types.
func TestIDsRoundTrip(t *testing.T) {
	for _, kind := range []mediaType{mediaMovie, mediaTV} {
		ref, err := parseID(idOf(27205, kind))
		if err != nil {
			t.Fatalf("parseID(%q): %v", idOf(27205, kind), err)
		}
		if ref.tmdb != 27205 || ref.kind != kind {
			t.Fatalf("ref = %+v", ref)
		}
	}
}

// TestEmbedURLCarriesSparseQuery checks embedURL's parameter set directly so
// no silent extra/missing parameter can slip past the Stream test above.
func TestEmbedURLCarriesSparseQuery(t *testing.T) {
	p := &Provider{embedBase: "https://embed.test/"}
	movie := p.embedURL(idRef{tmdb: 27205, kind: mediaMovie}, 0, 0)
	u, err := url.Parse(movie)
	if err != nil {
		t.Fatalf("movie embed URL: %v", err)
	}
	q := u.Query()
	if len(q) != 2 || q.Get("tmdb") != "27205" || q.Get("o") != embedReferrerAttribution {
		t.Fatalf("movie query = %v", q)
	}
	tv := p.embedURL(idRef{tmdb: 1399, kind: mediaTV}, 3, 7)
	u, err = url.Parse(tv)
	if err != nil {
		t.Fatalf("tv embed URL: %v", err)
	}
	q = u.Query()
	if len(q) != 4 || q.Get("season") != "3" || q.Get("episode") != "7" || q.Get("tmdb") != "1399" {
		t.Fatalf("tv query = %v", q)
	}
	if !strings.HasPrefix(u.Path, "/embed/tv") {
		t.Fatalf("tv path = %q", u.Path)
	}
}

// TestYearRejectsGarbage guards the date parser: a short or non-leading-number
// date is year 0.
func TestYearRejectsGarbage(t *testing.T) {
	if year("x0") != 0 || year("") != 0 || year("obse") != 0 {
		t.Fatal("year accepted a short or malformed date")
	}
	if year("2010-07-16") != 2010 {
		t.Fatal("year rejected a normal date")
	}
}

// mustQuery parses an embed URL, failing the test on garbage rather than
// silently comparing an unparsable string.
func mustQuery(t *testing.T, raw string) url.Values {
	t.Helper()
	u, err := url.Parse(raw)
	if err != nil {
		t.Fatalf("embed URL: %v", err)
	}
	return u.Query()
}
