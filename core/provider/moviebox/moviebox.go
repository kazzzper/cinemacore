// Package moviebox adapts the MovieBox gateway to the provider contract.
//
// The gateway wire shapes (documented independently in
// moviebox-internal-api/OFFICIAL_API_DOCUMENTATION.md and verified against the
// live cluster) differ from the contract DTOs, so this adapter owns the mapping
// and core/models stays gateway-free.
package moviebox

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"github.com/solo12345689/cinemacore/core/models"
	"github.com/solo12345689/cinemacore/core/session"
)

// errNoData marks an envelope whose data payload is empty/absent.
var errNoData = errors.New("moviebox: empty data")

// Provider talks to the MovieBox BFF through a signed session.
type Provider struct{ s *session.Client }

// New returns a MovieBox provider over the given session client.
func New(s *session.Client) *Provider { return &Provider{s: s} }

// Name identifies this provider.
func (p *Provider) Name() string { return "moviebox" }

// Home returns the landing sections from the daily recommendation feed.
func (p *Provider) Home(ctx context.Context) (models.Page, error) {
	var out itemsPage
	if err := p.call(ctx, http.MethodPost, "/wefeed-mobile-bff/subject-api/daily-movie-rec",
		`{"page":1,"pageSize":20}`, &out); err != nil {
		return models.Page{}, err
	}
	// daily-movie-rec is a single ranked feed, not labelled rows, so it maps to
	// one section rather than the multi-row layout tab-operating would give.
	return models.Page{Sections: []models.Section{{
		Title: "Top Picks",
		Items: mapSubjects(out.Items),
	}}}, nil
}

// Search returns subjects matching query.
func (p *Provider) Search(ctx context.Context, q string) ([]models.Subject, error) {
	body, _ := json.Marshal(map[string]any{"keyword": q, "q": q, "type": 0, "page": 1, "pageSize": 20})
	var out itemsPage
	if err := p.call(ctx, http.MethodPost, "/wefeed-mobile-bff/subject-api/search", string(body), &out); err != nil {
		return nil, err
	}
	return mapSubjects(out.Items), nil
}

// Detail returns one subject.
func (p *Provider) Detail(ctx context.Context, id string) (models.Subject, error) {
	var out wireSubject
	path := "/wefeed-mobile-bff/subject-api/get?" + query("subjectId", id)
	if err := p.call(ctx, http.MethodGet, path, "", &out); err != nil {
		return models.Subject{}, err
	}
	return out.toSubject(), nil
}

// Episodes expands the season/episode tree for a series.
func (p *Provider) Episodes(ctx context.Context, id string) ([]models.Episode, error) {
	var out wireSeasonInfo
	path := "/wefeed-mobile-bff/subject-api/season-info?" + query("subjectId", id)
	if err := p.call(ctx, http.MethodGet, path, "", &out); err != nil {
		return nil, err
	}
	return out.episodes(id), nil
}

// Stream resolves a playback source.
func (p *Provider) Stream(ctx context.Context, id string, season, episode int) (models.Stream, error) {
	params := []string{"subjectId", id}
	if season > 0 {
		params = append(params, "se", strconv.Itoa(season))
	}
	if episode > 0 {
		params = append(params, "ep", strconv.Itoa(episode))
	}
	var out wirePlayInfo
	path := "/wefeed-mobile-bff/subject-api/play-info?" + query(params...)
	if err := p.call(ctx, http.MethodGet, path, "", &out); err != nil {
		return models.Stream{}, err
	}
	return out.stream(), nil
}

// Subtitles returns external caption tracks for one episode. The gateway keys
// captions by the title's first playable resourceId, resolved via Detail.
func (p *Provider) Subtitles(ctx context.Context, id string, episode int) ([]models.Subtitle, error) {
	detail, err := p.Detail(ctx, id)
	if err != nil {
		return nil, err
	}
	rid := firstResourceID(detail.ResourceDetectors)
	if rid == "" {
		return nil, nil
	}
	params := []string{"subjectId", id, "resourceId", rid}
	if episode > 0 {
		params = append(params, "episode", strconv.Itoa(episode))
	}
	var out wireCaptions
	path := "/wefeed-mobile-bff/subject-api/get-ext-captions?" + query(params...)
	if err := p.call(ctx, http.MethodGet, path, "", &out); err != nil {
		return nil, err
	}
	subs := make([]models.Subtitle, 0, len(out.ExtCaptions))
	for _, c := range out.ExtCaptions {
		subs = append(subs, models.Subtitle{Lang: c.lang(), URL: c.URL, Format: captionFormat(c.URL)})
	}
	return subs, nil
}

// Suggest returns type-ahead terms for a query from the gateway's suggester.
func (p *Provider) Suggest(ctx context.Context, q string) ([]string, error) {
	var out wireSuggest
	path := "/wefeed-mobile-bff/subject-api/search-suggest?" + query("keyword", q)
	if err := p.call(ctx, http.MethodGet, path, "", &out); err != nil {
		return nil, err
	}
	terms := make([]string, 0, len(out.Items))
	for _, it := range out.Items {
		if it.Word != "" {
			terms = append(terms, it.Word)
		}
	}
	return terms, nil
}

// call performs one signed gateway request and unwraps the {code,message,data}
// envelope into out.
func (p *Provider) call(ctx context.Context, method, path, body string, out any) error {
	raw, err := p.s.Do(ctx, method, path, body)
	if err != nil {
		return err
	}
	var env struct {
		Code    int             `json:"code"`
		Message string          `json:"message"`
		Data    json.RawMessage `json:"data"`
	}
	if err := json.Unmarshal(raw, &env); err != nil {
		return fmt.Errorf("moviebox: decode envelope: %w", err)
	}
	if env.Code != 0 {
		return fmt.Errorf("moviebox: upstream code %d: %s", env.Code, env.Message)
	}
	if len(env.Data) == 0 || string(env.Data) == "null" {
		return errNoData
	}
	if err := json.Unmarshal(env.Data, out); err != nil {
		return fmt.Errorf("moviebox: decode data: %w", err)
	}
	return nil
}

// --- gateway wire types ---

type itemsPage struct {
	Items []wireSubject `json:"items"`
}

type wireSubject struct {
	SubjectID         string         `json:"subjectId"`
	SubjectType       int            `json:"subjectType"`
	Title             string         `json:"title"`
	Description       string         `json:"description"`
	ReleaseDate       string         `json:"releaseDate"`
	Duration          string         `json:"duration"`
	DurationSeconds   int            `json:"durationSeconds"`
	Genre             string         `json:"genre"`
	Cover             wireImage      `json:"cover"`
	IMDBRating        string         `json:"imdbRatingValue"`
	SENum             int            `json:"seNum"`
	StaffList         []wireStaff    `json:"staffList"`
	Dubs              []wireDub      `json:"dubs"`
	ResourceDetectors []wireDetector `json:"resourceDetectors"`
}

type wireImage struct {
	URL string `json:"url"`
}

type wireStaff struct {
	Name      string `json:"name"`
	Character string `json:"character"`
	AvatarURL string `json:"avatarUrl"`
}

type wireDub struct {
	LanName string `json:"lanName"`
}

type wireDetector struct {
	Type       int    `json:"type"`
	ResourceID string `json:"resourceId"`
	Source     string `json:"source"`
}

type wireSeasonInfo struct {
	Seasons []wireSeason `json:"seasons"`
}

type wireSeason struct {
	Se    int    `json:"se"`
	MaxEp int    `json:"maxEp"`
	AllEp string `json:"allEp"`
}

type wirePlayInfo struct {
	Streams []wireStream `json:"streams"`
}

type wireStream struct {
	URL         string `json:"url"`
	Resolutions string `json:"resolutions"`
	SignCookie  string `json:"signCookie"`
}

type wireCaptions struct {
	ExtCaptions []wireCaption `json:"extCaptions"`
}

type wireCaption struct {
	Lan     string `json:"lan"`
	LanName string `json:"lanName"`
	URL     string `json:"url"`
}

type wireSuggest struct {
	Items []struct {
		Word string `json:"word"`
	} `json:"items"`
}

// --- mapping ---

func mapSubjects(in []wireSubject) []models.Subject {
	out := make([]models.Subject, 0, len(in))
	for _, w := range in {
		out = append(out, w.toSubject())
	}
	return out
}

func (w wireSubject) toSubject() models.Subject {
	s := models.Subject{
		ID:              w.SubjectID,
		Title:           w.Title,
		Poster:          w.Cover.URL,
		Year:            year(w.ReleaseDate),
		Rating:          parseFloat(w.IMDBRating),
		Kind:            kindOf(w.SubjectType),
		Synopsis:        w.Description,
		Genres:          splitList(w.Genre),
		DurationMinutes: durationMinutes(w.DurationSeconds, w.Duration),
		SeasonCount:     w.SENum,
	}
	for _, d := range w.Dubs {
		if d.LanName != "" {
			s.Dubs = append(s.Dubs, d.LanName)
		}
	}
	for _, st := range w.StaffList {
		s.Cast = append(s.Cast, models.CastMember{Name: st.Name, Role: st.Character, Avatar: st.AvatarURL})
	}
	for _, d := range w.ResourceDetectors {
		if d.ResourceID == "" {
			continue
		}
		name := d.Source
		if name == "" {
			name = "Resource"
		}
		s.ResourceDetectors = append(s.ResourceDetectors, models.ResourceDetector{ResourceID: d.ResourceID, Name: name})
	}
	return s
}

// episodes flattens season-info into one Episode per available episode number.
// allEp is the authoritative list when present (it can have gaps); otherwise
// every number up to maxEp is present.
func (w wireSeasonInfo) episodes(subjectID string) []models.Episode {
	var out []models.Episode
	for _, s := range w.Seasons {
		numbers := episodeNumbers(s.AllEp, s.MaxEp)
		for _, n := range numbers {
			out = append(out, models.Episode{SubjectID: subjectID, Season: s.Se, Number: n})
		}
	}
	return out
}

func (w wirePlayInfo) stream() models.Stream {
	out := models.Stream{}
	for _, s := range w.Streams {
		if s.URL == "" {
			continue
		}
		out.URL = s.URL
		if s.SignCookie != "" {
			out.Headers = map[string]string{"Cookie": s.SignCookie, "User-Agent": "ExoPlayerLib/2.19.1"}
		}
		// A single muxed URL serves every advertised resolution.
		for _, r := range splitList(s.Resolutions) {
			out.Qualities = append(out.Qualities, models.Quality{Label: r, URL: s.URL})
		}
		break
	}
	return out
}

func (c wireCaption) lang() string {
	if c.LanName != "" {
		return c.LanName
	}
	return c.Lan
}

func firstResourceID(ds []models.ResourceDetector) string {
	for _, d := range ds {
		if d.ResourceID != "" {
			return d.ResourceID
		}
	}
	return ""
}

func kindOf(subjectType int) string {
	switch subjectType {
	case 1:
		return "movie"
	case 2:
		return "series"
	case 10:
		return "game"
	default:
		return ""
	}
}

func year(releaseDate string) int {
	if len(releaseDate) >= 4 {
		if y, err := strconv.Atoi(releaseDate[:4]); err == nil {
			return y
		}
	}
	return 0
}

func parseFloat(s string) float64 {
	f, _ := strconv.ParseFloat(strings.TrimSpace(s), 64)
	return f
}

func splitList(s string) []string {
	if s == "" {
		return nil
	}
	parts := strings.Split(s, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

// durationMinutes prefers the exact second count and falls back to the human
// "1h 33m" string for payloads that omit it.
func durationMinutes(seconds int, human string) int {
	if seconds > 0 {
		return seconds / 60
	}
	human = strings.TrimSpace(human)
	if human == "" {
		return 0
	}
	total := 0
	num := ""
	for _, r := range human {
		switch {
		case r >= '0' && r <= '9':
			num += string(r)
		case r == 'h' || r == 'H':
			total += atoi(num) * 60
			num = ""
		case r == 'm' || r == 'M':
			total += atoi(num)
			num = ""
		}
	}
	return total
}

func atoi(s string) int {
	n, _ := strconv.Atoi(s)
	return n
}

func episodeNumbers(allEp string, maxEp int) []int {
	if allEp != "" {
		var out []int
		for _, p := range strings.Split(allEp, ",") {
			if n, err := strconv.Atoi(strings.TrimSpace(p)); err == nil && n > 0 {
				out = append(out, n)
			}
		}
		if len(out) > 0 {
			return out
		}
	}
	out := make([]int, 0, maxEp)
	for n := 1; n <= maxEp; n++ {
		out = append(out, n)
	}
	return out
}

func captionFormat(rawURL string) string {
	u, err := url.Parse(rawURL)
	if err != nil {
		return ""
	}
	path := u.Path
	if i := strings.LastIndex(path, "."); i >= 0 {
		return strings.ToLower(path[i+1:])
	}
	return ""
}

func query(kv ...string) string {
	v := url.Values{}
	for i := 0; i+1 < len(kv); i += 2 {
		v.Set(kv[i], kv[i+1])
	}
	return v.Encode()
}
