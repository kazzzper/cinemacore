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

// getListBody mirrors the reference GetListRequest for the main home tab
// (categoryId 1, page 1, page size 24).
const getListBody = `{"categoryId":1,"page":1,"pageSize":24}`

// homeTabID is the "Main Home / Feed" tab id (OFFICIAL_API_DOCUMENTATION.md §8).
const homeTabID = "1"

// Provider talks to the MovieBox BFF through a signed session.
type Provider struct{ s *session.Client }

// New returns a MovieBox provider over the given session client.
func New(s *session.Client) *Provider { return &Provider{s: s} }

// Name identifies this provider.
func (p *Provider) Name() string { return "moviebox" }

// Home returns the landing rails, one Section per upstream rail.
//
// The Kotlin reference app posts home/v2/get-list, but that route answers 404 on
// every live gateway host (api6/api5/api/api.inmoviebox.com, checked 2026-10-17,
// no body); the reference's own proxy resolves it to
// tab-operating?tabId=<categoryId> (LocalMovieBoxServer.kt:1067-1120), which is
// the live multi-rail layout. We try the documented route first in case a
// cluster serves it, then its resolution, then the single ranked daily feed as a
// last resort.
func (p *Provider) Home(ctx context.Context) (models.Page, error) {
	var list homeRails
	if err := p.call(ctx, http.MethodPost, "/home/v2/get-list", getListBody, &list); err == nil {
		if sections := list.sections(); len(sections) > 0 {
			return models.Page{Sections: sections}, nil
		}
	}
	var tabs homeRails
	if err := p.call(ctx, http.MethodGet, "/wefeed-mobile-bff/tab-operating?"+query("page", "1", "tabId", homeTabID, "version", ""), "", &tabs); err == nil {
		if sections := tabs.sections(); len(sections) > 0 {
			return models.Page{Sections: sections}, nil
		}
	}
	// daily-movie-rec is one ranked feed, not labelled rows, so it can only ever
	// be a single rail; it keeps /v1/home answering when the layout is down.
	var daily itemsPage
	if err := p.call(ctx, http.MethodPost, "/wefeed-mobile-bff/subject-api/daily-movie-rec", `{"page":1,"pageSize":20}`, &daily); err != nil {
		return models.Page{}, err
	}
	return models.Page{Sections: []models.Section{{Title: "Top Picks", Items: mapSubjects(daily.Items)}}}, nil
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

// Episodes expands the season/episode tree for a series, enriched with the
// per-episode durations that only the resource listing carries.
func (p *Provider) Episodes(ctx context.Context, id string) ([]models.Episode, error) {
	return p.episodesWithDurations(ctx, id)
}

// Stream resolves a playback source, recovering the real manifest from the
// gateway's anti-piracy decoy where the references do.
func (p *Provider) Stream(ctx context.Context, id string, season, episode int) (models.Stream, error) {
	return p.resolveStream(ctx, id, season, episode)
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

// homeRails is the layout envelope the home routes return: titled rows whose
// subjects sit in one of several containers. tab-operating labels the rows
// "items", the reference proxy's reshaped get-list labels them "list".
type homeRails struct {
	Items []json.RawMessage `json:"items"`
	List  []json.RawMessage `json:"list"`
}

// sections maps every row that resolves to at least one subject into a titled
// Section, preserving upstream order and dropping rows with no subject.
func (h homeRails) sections() []models.Section {
	var out []models.Section
	for _, rows := range [][]json.RawMessage{h.Items, h.List} {
		for _, raw := range rows {
			var r homeRow
			if json.Unmarshal(raw, &r) != nil {
				continue
			}
			if items := r.subjects(); len(items) > 0 {
				out = append(out, models.Section{Title: r.title(), Items: items})
			}
		}
	}
	return out
}

type homeRow struct {
	Title           string            `json:"title"`
	Name            string            `json:"name"`
	CustomData      *homeContainer    `json:"customData"`
	Banner          *homeContainer    `json:"banner"`
	RankingListData *homeContainer    `json:"rankingListData"`
	List            []json.RawMessage `json:"list"`
	Items           []json.RawMessage `json:"items"`
	Subjects        []json.RawMessage `json:"subjects"`
	MovieList       []json.RawMessage `json:"movieList"`
}

// homeContainer is a named sub-list: customData and rankingListData use
// "items", banner uses "banners".
type homeContainer struct {
	Items   []json.RawMessage `json:"items"`
	Banners []json.RawMessage `json:"banners"`
}

// subjects collects a row's subjects from every container the gateway uses.
// postData/playListData/liveList are deliberately ignored: they carry UGC posts
// and live-room entries keyed by their own id, not catalog subjects.
func (r homeRow) subjects() []models.Subject {
	var out []models.Subject
	appendRaw := func(raws []json.RawMessage, cards bool) {
		for _, raw := range raws {
			if s, ok := tabSubject(raw, cards); ok {
				out = append(out, s.toSubject())
			}
		}
	}
	if r.CustomData != nil {
		appendRaw(r.CustomData.Items, true)
	}
	if r.Banner != nil {
		appendRaw(r.Banner.Banners, true)
	}
	if r.RankingListData != nil {
		for _, raw := range r.RankingListData.Items {
			appendRaw(rankSubjects(raw), false)
		}
	}
	appendRaw(r.List, false)
	appendRaw(r.Items, false)
	appendRaw(r.Subjects, false)
	appendRaw(r.MovieList, false)
	return out
}

func (r homeRow) title() string {
	if t := firstNonEmpty(r.Title, r.Name); t != "" {
		return t
	}
	return "Section"
}

// rankSubjects unwraps a rankingListData entry, which nests its subjects under
// "subjects" instead of being one itself.
func rankSubjects(raw json.RawMessage) []json.RawMessage {
	var rank struct {
		Subjects []json.RawMessage `json:"subjects"`
	}
	if json.Unmarshal(raw, &rank) == nil && len(rank.Subjects) > 0 {
		return rank.Subjects
	}
	return []json.RawMessage{raw}
}

// tabSubject resolves one layout entry to a subject: either a wrapper
// ({"subject":{…}}) or the entry itself.
//
// cards marks the mixed containers (customData, banner), where the gateway
// reuses the card shape for things that are not catalog subjects. Every such
// card lacks a subjectType and carries a navigation id in subjectId instead:
// category teasers (/home/category), cast tiles (/movie/staff), UGC posts
// (/post/detailVideo), web promos. Resolving them would hand clients ids that
// Detail cannot answer.
func tabSubject(raw json.RawMessage, cards bool) (wireSubject, bool) {
	var wrap struct {
		Subject *wireSubject `json:"subject"`
	}
	s := wireSubject{}
	switch {
	case json.Unmarshal(raw, &wrap) == nil && wrap.Subject != nil:
		s = *wrap.Subject
	case json.Unmarshal(raw, &s) != nil:
		return wireSubject{}, false
	}
	if s.SubjectID == "" || (cards && s.SubjectType == 0) {
		return wireSubject{}, false
	}
	return s, true
}

type wireSubject struct {
	SubjectID         string         `json:"subjectId"`
	SubjectType       int            `json:"subjectType"`
	Kind              string         `json:"kind"`
	Title             string         `json:"title"`
	Name              string         `json:"name"`
	Description       string         `json:"description"`
	ReleaseDate       string         `json:"releaseDate"`
	Duration          string         `json:"duration"`
	DurationSeconds   int            `json:"durationSeconds"`
	Seconds           int            `json:"seconds"`
	Genre             string         `json:"genre"`
	Cover             wireImage      `json:"cover"`
	IMDBRating        string         `json:"imdbRatingValue"`
	SENum             int            `json:"seNum"`
	SeasonCount       int            `json:"seasonCount"`
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
	LanCode   string `json:"lanCode"`
	LanName   string `json:"lanName"`
	Original  bool   `json:"original"`
	SubjectID string `json:"subjectId"`
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
	Size        string `json:"size"`
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
		Title:           firstNonEmpty(w.Title, w.Name),
		Poster:          httpsURL(w.Cover.URL),
		Year:            year(w.ReleaseDate),
		Rating:          parseFloat(w.IMDBRating),
		Kind:            firstNonEmpty(w.Kind, kindOf(w.SubjectType)),
		Synopsis:        w.Description,
		Genres:          splitList(w.Genre),
		DurationMinutes: durationMinutes(w.totalSeconds(), w.Duration),
		SeasonCount:     w.seasonTotal(),
	}
	for _, d := range w.Dubs {
		if d.LanName == "" {
			continue
		}
		s.Dubs = append(s.Dubs, d.LanName)
		if d.SubjectID != "" {
			s.DubOptions = append(s.DubOptions, models.Dub{
				SubjectID:    d.SubjectID,
				LanguageName: d.LanName,
				LanguageCode: d.LanCode,
				Original:     d.Original,
			})
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

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}

// httpsURL promotes the protocol-relative asset URLs some endpoints return
// ("//pbcdn…") so clients do not resolve them against their own origin.
func httpsURL(u string) string {
	if strings.HasPrefix(u, "//") {
		return "https:" + u
	}
	return u
}

// totalSeconds prefers the feed's exact durationSeconds and falls back to the
// layout rows' "seconds".
func (w wireSubject) totalSeconds() int {
	if w.DurationSeconds > 0 {
		return w.DurationSeconds
	}
	return w.Seconds
}

// seasonTotal prefers the layout's seasonCount and falls back to the feed's seNum.
func (w wireSubject) seasonTotal() int {
	if w.SeasonCount > 0 {
		return w.SeasonCount
	}
	return w.SENum
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
