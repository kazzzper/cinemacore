// Package streamhype adapts the StreamHype ecosystem to the provider contract.
//
// The source splits in two, and the adapter keeps the split explicit:
//
//   - Catalog: TMDB (api.themoviedb.org) — a clean REST API. Every StreamHype
//     surface is a thin wrapper over TMDB queries, so the catalog needs no
//     scraping at all (docs/streamhype-network-map.md §2).
//   - Playback: embedded third-party players behind single-use tokens, WASM
//     response crypto and per-request host rotation (NET_MAP §3-§5). Replaying
//     that chain natively decays whenever the backend rotates; the durable
//     path is the embed page itself, opened in the app's web player.
//
// Stream() therefore answers with KindWeb — an embed URL, not media — and
// leaves native protocol replay to a later provider variant once the wire path
// is proven stable in production.
//
// Subject ids are namespaced "tmdb-movie-<id>" / "tmdb-tv-<id>" so Detail,
// Episodes and Stream can recover the TMDB media type from the id alone, and
// so ids can never collide with another provider's subjects in merged search.
package streamhype

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/solo12345689/cinemacore/core/models"
	"github.com/solo12345689/cinemacore/core/provider"
)

const (
	// APIBase is TMDB's REST root.
	APIBase = "https://api.themoviedb.org/3"
	// ImageBase is TMDB's asset root; poster paths are relative to it.
	ImageBase = "https://image.tmdb.org/t/p"

	// EmbedBase is the vidsrc-family façade StreamHype's own Play button
	// opens first (NET_MAP §2: screenfetch4.cyou, fallback vidsrc.me —
	// both front-ends of the same backend). Kept as a constant so the
	// failover front-end list can grow without touching callers.
	EmbedBase = "https://screenfetch4.cyou/"
	// embedReferrerAttribution mirrors StreamHype's own `?o=` embed
	// parameter: provider attribution, not a credential.
	embedReferrerAttribution = "streamhype.net"

	// idPrefix is the subject-id namespace prefix.
	idPrefix = "tmdb"
)

// mediaType is TMDB's movie/tv discriminator.
type mediaType string

const (
	mediaMovie mediaType = "movie"
	mediaTV    mediaType = "tv"
)

// Provider serves the catalog from TMDB and playback as web embeds.
type Provider struct {
	// apiKey is the TMDB v3 key. Registered per deployment, never scraped.
	apiKey  string
	client  *http.Client
	apiBase string
	// embedBase is overridable for tests and for swapping the façade host.
	embedBase string
}

// New builds a provider over the given TMDB API key.
func New(apiKey string) *Provider {
	return &Provider{
		apiKey:    apiKey,
		client:    &http.Client{Timeout: 30 * time.Second},
		apiBase:   APIBase,
		embedBase: EmbedBase,
	}
}

// Name identifies this provider.
func (p *Provider) Name() string { return "streamhype" }

// Home returns the landing rails: trending, popular movies, popular TV and
// top-rated, mirroring the rails StreamHype's own explorer exposes.
func (p *Provider) Home(ctx context.Context) (models.Page, error) {
	type rail struct {
		title string
		path  string
		// media is the rail's own type: list endpoints do not set media_type
		// (only multi-search does), so the rail supplies its own.
		media mediaType
	}
	rails := []rail{
		{"Trending Now", "/trending/movie/week", mediaMovie},
		{"Popular Movies", "/movie/popular", mediaMovie},
		{"Popular TV", "/tv/popular", mediaTV},
		{"Top Rated", "/movie/top_rated", mediaMovie},
	}
	var sections []models.Section
	for _, r := range rails {
		items, err := p.results(ctx, r.path, r.media, nil)
		if err != nil {
			// One dead rail must not kill the page; fail loud only when
			// every rail is dead (below).
			continue
		}
		if len(items) > 0 {
			sections = append(sections, models.Section{Title: r.title, Items: items})
		}
	}
	if len(sections) == 0 {
		return models.Page{}, fmt.Errorf("streamhype: all home rails failed")
	}
	return models.Page{Sections: sections}, nil
}

// Search returns movie/TV subjects matching query.
func (p *Provider) Search(ctx context.Context, query string) ([]models.Subject, error) {
	return p.results(ctx, "/search/multi", "", map[string]string{"query": query})
}

// Suggest returns type-ahead candidates from the same multi-search.
func (p *Provider) Suggest(ctx context.Context, query string) ([]string, error) {
	items, err := p.results(ctx, "/search/multi", "", map[string]string{"query": query})
	if err != nil {
		return nil, err
	}
	terms := make([]string, 0, len(items))
	for _, it := range items {
		if it.Title != "" {
			terms = append(terms, it.Title)
		}
	}
	return terms, nil
}

// Detail returns one subject. The id namespace decides the TMDB endpoint:
// "tmdb-movie-<id>" reads /movie/{id}, "tmdb-tv-<id>" reads /tv/{id}.
func (p *Provider) Detail(ctx context.Context, id string) (models.Subject, error) {
	ref, err := parseID(id)
	if err != nil {
		return models.Subject{}, err
	}
	var raw struct {
		ID          int     `json:"id"`
		Title       string  `json:"title"`
		Name        string  `json:"name"`
		Overview    string  `json:"overview"`
		Poster      string  `json:"poster_path"`
		VoteAverage float64 `json:"vote_average"`
		Runtime     int     `json:"runtime"`
		ReleaseDate string  `json:"release_date"`
		FirstAir    string  `json:"first_air_date"`
		Genres      []struct {
			Name string `json:"name"`
		} `json:"genres"`
		Seasons []tmdbSeason `json:"seasons"`
	}
	if _, err := p.get(ctx, "/"+string(ref.kind)+"/"+strconv.Itoa(ref.tmdb), nil, &raw); err != nil {
		return models.Subject{}, err
	}
	s := models.Subject{
		ID:              idOf(ref.tmdb, ref.kind),
		Title:           titleOf(ref.kind, raw.Title, raw.Name),
		Poster:          imageURL(raw.Poster),
		Year:            year(firstNonEmpty(raw.ReleaseDate, raw.FirstAir)),
		Rating:          raw.VoteAverage,
		Kind:            kindLabel(ref.kind),
		Synopsis:        raw.Overview,
		DurationMinutes: raw.Runtime,
	}
	for _, g := range raw.Genres {
		if g.Name != "" {
			s.Genres = append(s.Genres, g.Name)
		}
	}
	s.SeasonCount = tvSeasonCount(ref.kind, raw.Seasons)
	return s, nil
}

// Episodes returns the full episode tree of a series, one call per TMDB
// season so titles and runtimes come straight from the source data.
func (p *Provider) Episodes(ctx context.Context, id string) ([]models.Episode, error) {
	ref, err := parseID(id)
	if err != nil {
		return nil, err
	}
	if ref.kind != mediaTV {
		// A movie is a one-entry tree only when asked as one; the contract
		// expects Episodes to be a series operation.
		return nil, &provider.UnavailableError{
			Provider: p.Name(),
			Reason:   "movies have no episode tree",
		}
	}
	seasons, err := p.tvSeasons(ctx, ref.tmdb)
	if err != nil {
		return nil, err
	}
	var out []models.Episode
	for _, season := range seasons {
		if !season.Enabled {
			continue
		}
		var raw struct {
			Episodes []struct {
				EpisodeNumber int    `json:"episode_number"`
				Name          string `json:"name"`
				Runtime       int    `json:"runtime"`
			} `json:"episodes"`
		}
		path := "/tv/" + strconv.Itoa(ref.tmdb) + "/season/" + strconv.Itoa(season.Num)
		if _, err := p.get(ctx, path, nil, &raw); err != nil {
			continue
		}
		for _, ep := range raw.Episodes {
			if ep.EpisodeNumber <= 0 {
				continue
			}
			out = append(out, models.Episode{
				SubjectID:       id,
				Season:          season.Num,
				Number:          ep.EpisodeNumber,
				Title:           ep.Name,
				DurationSeconds: ep.Runtime * 60,
			})
		}
	}
	return out, nil
}

// Stream resolves one playback source. The answer is a web embed: the
// vidsrc-family player page StreamHype's own Play button opens, keyed by the
// TMDB id the source catalog itself uses — no token minting, no WASM decrypt.
func (p *Provider) Stream(ctx context.Context, id string, season, episode int) (models.Stream, error) {
	ref, err := parseID(id)
	if err != nil {
		return models.Stream{}, err
	}
	embed := p.embedURL(ref, season, episode)
	return models.Stream{
		URL:  embed,
		Kind: models.KindWeb,
		Qualities: []models.Quality{{
			Label: "StreamHype Web",
			URL:   embed,
			Kind:  models.KindWeb,
		}},
	}, nil
}

// Subtitles: every StreamHype player chain carries its own caption list, and
// the web player shows them itself. Exposing TMDB-less empty tracks here is
// honest (the contract treats captions as best-effort) and keeps PlayInfo
// from advertising tracks that point nowhere.
func (p *Provider) Subtitles(ctx context.Context, id string, episode int) ([]models.Subtitle, error) {
	return nil, nil
}

// tvSeasons lists a series' seasons from the TV detail payload.
func (p *Provider) tvSeasons(ctx context.Context, tmdb int) ([]tvSeasonRef, error) {
	var raw struct {
		Seasons []tmdbSeason `json:"seasons"`
	}
	if _, err := p.get(ctx, "/tv/"+strconv.Itoa(tmdb), nil, &raw); err != nil {
		return nil, err
	}
	return seasonsFrom(raw.Seasons), nil
}

// tmdbSeason is the season entry TMDB lists on the TV detail payload.
type tmdbSeason struct {
	SeasonNumber int    `json:"season_number"`
	EpisodeCount int    `json:"episode_count"`
	Name         string `json:"name"`
}

// tvSeasonRef is one playable season: number plus an upstream flag for the
// special entries TMDB lists but players do not resolve (Specials = season 0).
type tvSeasonRef struct {
	Num     int
	Enabled bool
}

// seasonsFrom keeps numbered, non-special seasons in ascending order.
func seasonsFrom(in []tmdbSeason) []tvSeasonRef {
	out := make([]tvSeasonRef, 0, len(in))
	for _, s := range in {
		if s.SeasonNumber > 0 {
			out = append(out, tvSeasonRef{Num: s.SeasonNumber, Enabled: s.EpisodeCount > 0})
		}
	}
	return out
}

// --- id namespace ---

// idRef is the parsed subject id: TMDB id plus media type.
type idRef struct {
	tmdb int
	kind mediaType
}

// parseID reads "<prefix>-<kind>-<tmdb>" back into its parts.
func parseID(id string) (idRef, error) {
	parts := strings.Split(id, "-")
	if len(parts) != 3 || parts[0] != idPrefix {
		return idRef{}, &provider.UnavailableError{
			Provider: "streamhype",
			Reason:   "id is not a TMDB subject: " + id,
		}
	}
	kind := mediaType(parts[1])
	if kind != mediaMovie && kind != mediaTV {
		return idRef{}, &provider.UnavailableError{
			Provider: "streamhype",
			Reason:   "unknown TMDB media type: " + parts[1],
		}
	}
	tmdb, err := strconv.Atoi(parts[2])
	if err != nil || tmdb <= 0 {
		return idRef{}, &provider.UnavailableError{
			Provider: "streamhype",
			Reason:   "bad TMDB id: " + parts[2],
		}
	}
	return idRef{tmdb: tmdb, kind: kind}, nil
}

// idOf namespaces a TMDB id into a provider subject id.
func idOf(tmdb int, kind mediaType) string {
	return idPrefix + "-" + string(kind) + "-" + strconv.Itoa(tmdb)
}

// embedURL builds the player page for one movie or episode.
func (p *Provider) embedURL(ref idRef, season, episode int) string {
	v := url.Values{}
	v.Set("tmdb", strconv.Itoa(ref.tmdb))
	v.Set("o", embedReferrerAttribution)
	if ref.kind == mediaTV {
		v.Set("season", strconv.Itoa(max(season, 1)))
		v.Set("episode", strconv.Itoa(max(episode, 1)))
	}
	return p.embedBase + "embed/" + string(ref.kind) + "?" + v.Encode()
}

// kindLabel maps the id's media type to the contract's kind vocabulary
// ("movie"/"series"). TMDB carries series under the "tv" endpoint.
func kindLabel(kind mediaType) string {
	if kind == mediaTV {
		return "series"
	}
	return "movie"
}

// tvSeasonCount keeps the special (season 0) TMDB entry out of the count.
func tvSeasonCount(kind mediaType, seasons []tmdbSeason) int {
	if kind != mediaTV {
		return 1
	}
	n := 0
	for _, s := range seasons {
		if s.SeasonNumber > 0 {
			n++
		}
	}
	return n
}

// --- TMDB access ---

// get performs one TMDB GET and decodes the payload into out.
func (p *Provider) get(ctx context.Context, path string, extra map[string]string, out any) (int, error) {
	v := url.Values{}
	v.Set("api_key", p.apiKey)
	for k, val := range extra {
		v.Set(k, val)
	}
	full := p.apiBase + path + "?" + v.Encode()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, full, nil)
	if err != nil {
		return 0, fmt.Errorf("streamhype: request %s: %w", path, err)
	}
	req.Header.Set("Accept", "application/json")
	resp, err := p.client.Do(req)
	if err != nil {
		return 0, fmt.Errorf("streamhype: %s: %w", path, err)
	}
	defer func() {
		_ = resp.Body.Close()
	}()
	if resp.StatusCode == http.StatusNotFound {
		return resp.StatusCode, &provider.UnavailableError{
			Provider: "streamhype",
			Reason:   path + " not found",
		}
	}
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return resp.StatusCode, fmt.Errorf("streamhype: %s: TMDB status %d: %s", path, resp.StatusCode, strings.TrimSpace(string(body)))
	}
	if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
		return resp.StatusCode, fmt.Errorf("streamhype: decode %s: %w", path, err)
	}
	return resp.StatusCode, nil
}

// results handles the "results" arrays TMDB puts on every list endpoint,
// mapped to Subjects. `fallback` names the media type for endpoints whose
// entries carry no media_type (any fixed list); multi-search leaves it empty
// because its entries are typed individually.
func (p *Provider) results(ctx context.Context, path string, fallback mediaType, extra map[string]string) ([]models.Subject, error) {
	var raw struct {
		Results []struct {
			ID          int     `json:"id"`
			MediaType   string  `json:"media_type"`
			Title       string  `json:"title"`
			Name        string  `json:"name"`
			Overview    string  `json:"overview"`
			Poster      string  `json:"poster_path"`
			VoteAverage float64 `json:"vote_average"`
			Release     string  `json:"release_date"`
			FirstAir    string  `json:"first_air_date"`
			Runtime     int     `json:"runtime"`
		} `json:"results"`
	}
	if _, err := p.get(ctx, path, extra, &raw); err != nil {
		return nil, err
	}
	out := make([]models.Subject, 0, len(raw.Results))
	for _, item := range raw.Results {
		kind, ok := mediaTypeOf(item.MediaType, fallback)
		if !ok {
			// multi-search carries "person" entries used to skip cast cards.
			continue
		}
		// Kind is the contract's vocabulary ("movie"/"series"), not TMDB's
		// endpoint name ("tv"), so a list entry reads exactly like Detail.
		out = append(out, models.Subject{
			ID:       idOf(item.ID, kind),
			Title:    titleOf(kind, item.Title, item.Name),
			Poster:   imageURL(item.Poster),
			Year:     year(firstNonEmpty(item.Release, item.FirstAir)),
			Rating:   item.VoteAverage,
			Kind:     kindLabel(kind),
			Synopsis: item.Overview,
		})
	}
	return out, nil
}

// mediaTypeOf resolves one entry's media type: the entry's own media_type
// when present, otherwise the endpoint's fallback kind. Unresolvable entries
// (person results in multi-search) are dropped.
func mediaTypeOf(media string, fallback mediaType) (mediaType, bool) {
	switch media {
	case "movie":
		return mediaMovie, true
	case "tv":
		return mediaTV, true
	default:
		if fallback != "" {
			return fallback, true
		}
		return "", false
	}
}

// titleOf prefers the field the media type actually carries: movies use
// title, TV uses name. The other field is never populated on a typed TMDB
// payload — but fixture drift or payload drift must not put a wrong name on
// the card.
func titleOf(kind mediaType, title, name string) string {
	if kind == mediaTV {
		return firstNonEmpty(name, title)
	}
	return firstNonEmpty(title, name)
}

// imageURL expands TMDB's relative poster path.
func imageURL(rawPath string) string {
	if rawPath == "" {
		return ""
	}
	return ImageBase + "/w780" + rawPath
}

// year reads a TMDB date's leading year.
func year(date string) int {
	if len(date) < 4 {
		return 0
	}
	n, err := strconv.Atoi(date[:4])
	if err != nil {
		return 0
	}
	return n
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}
