package moviebox

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
	"strconv"
	"strings"

	"github.com/solo12345689/cinemacore/core/models"
	"github.com/solo12345689/cinemacore/core/provider"
)

// streamUserAgent is the only media header besides the rendition cookie
// (player-spec.md §8); it keeps the value the adapter already emitted.
const streamUserAgent = "ExoPlayerLib/2.19.1"

// resourcePageLimit bounds resource pagination so a broken pager cannot loop.
const resourcePageLimit = 20

// resolveStream walks the reference clients' stream-recovery ladder. It exists
// because the gateway deliberately answers unofficial clients with a 23-second
// "please update your app" decoy (OFFICIAL_API_DOCUMENTATION.md §3 Phase 5), and
// the real manifest survives only in response metadata. Rungs run cheapest and
// strongest first: signed-cookie decode, then a non-decoy url, then the UGC
// download bypass, then the resource listing. A source that stays unplayable is
// refused with a typed error rather than returned.
func (p *Provider) resolveStream(ctx context.Context, id string, season, episode int) (models.Stream, error) {
	params := []string{"subjectId", id}
	if season > 0 {
		params = append(params, "se", strconv.Itoa(season))
	}
	if episode > 0 {
		params = append(params, "ep", strconv.Itoa(episode))
	}
	var info wirePlayInfo
	if err := p.call(ctx, http.MethodGet, "/wefeed-mobile-bff/subject-api/play-info?"+query(params...), "", &info); err != nil {
		return models.Stream{}, err
	}
	if out, ok := info.primary(); ok {
		return out, nil
	}
	// Rung 3: play-info held nothing playable, so the reference proxy replaces
	// the stream list wholesale from the UGC download endpoints — the only
	// recovery either client has when signCookie is empty (Genga-World
	// LocalMovieBoxServer.kt:835-940; the TUI has no UGC path).
	if out, ok := p.ugcBypass(ctx, id, season, episode); ok {
		return out, nil
	}
	// Rung 4: the TUI joins play-info with the resource listing as a second
	// mirror source and refuses only when both are empty
	// (moviebox-tui mod.rs:65-120).
	if out, ok := p.resourceStream(ctx, id, season, episode); ok {
		return out, nil
	}
	return models.Stream{}, &provider.UnavailableError{
		Provider: "moviebox",
		Reason:   unplayableReason(info),
	}
}

func unplayableReason(info wirePlayInfo) string {
	if len(info.Streams) == 0 {
		return "play-info returned no streams"
	}
	return "play-info returned only the anti-piracy decoy and no recovery path produced a real source"
}

// primary maps /play-info through rungs 1-2 and reports whether anything is
// playable. It never returns a decoy: a non-empty stream list whose every entry
// is a placeholder yields ok=false.
func (w wirePlayInfo) primary() (models.Stream, bool) {
	var out models.Stream
	seen := map[string]struct{}{}
	for _, s := range w.Streams {
		// Rung 1: the signed cookie carries the real CDN prefix, so it outranks
		// the advertised url (moviebox-tui adapt.rs:595-653, 717-725).
		target, ok := manifestFromSignCookie(s.SignCookie)
		if !ok {
			// Rung 2: an advertised url that is not the decoy is usable as-is
			// (moviebox-tui adapt.rs:717-725).
			if !usableURL(s.URL) {
				continue
			}
			target = s.URL
		}
		if out.URL == "" {
			out.URL = target
			out.Headers = streamHeaders(s.SignCookie)
		}
		for _, q := range renditions(s, target) {
			key := q.Label + "\x00" + q.URL
			if _, dup := seen[key]; dup {
				continue
			}
			seen[key] = struct{}{}
			out.Qualities = append(out.Qualities, q)
		}
	}
	if out.URL == "" {
		return models.Stream{}, false
	}
	return out, true
}

// decoyURL reports whether raw is the anti-piracy placeholder instead of
// content. The known slugs, /notice.mp4 and the macdn.aoneroom.com/other/ shape
// are transcribed from moviebox-tui adapt.rs:564-571
// (is_deprecation_notice_url); the please_update/update_app markers come from
// the Kotlin proxy (LocalMovieBoxServer.kt:835-846).
func decoyURL(raw string) bool {
	lower := strings.ToLower(raw)
	for _, marker := range []string{
		"1c7de0bd3393702d9191801f15f88f8d",
		"9a0461bc39da389663bf3dbb17091d3f",
		"b164fbfb43",
		"/notice.mp4",
		"please_update",
		"update_app",
	} {
		if strings.Contains(lower, marker) {
			return true
		}
	}
	return strings.Contains(lower, "macdn.aoneroom.com") && strings.Contains(lower, "/other/")
}

func usableURL(raw string) bool {
	return raw != "" && strings.HasPrefix(raw, "http") && !decoyURL(raw)
}

// manifestFromSignCookie decodes the CDN's signed cookie into a real manifest.
// The cookie is a ";"-separated list of key=value pairs and the real base path
// is base64url-encoded after "urlprefix=" (OFFICIAL_API_DOCUMENTATION.md §3
// Phase 5; moviebox-tui adapt.rs:595-653; LocalMovieBoxServer.kt:986-1004). The
// TUI builds only DASH and the Kotlin proxy only HLS, so both are accepted: a
// /dash/ tree gets index.mpd and any other http prefix gets index.m3u8.
func manifestFromSignCookie(cookie string) (string, bool) {
	for _, part := range strings.Split(cookie, ";") {
		part = strings.TrimSpace(part)
		if i := strings.Index(part, "urlprefix="); i >= 0 {
			token := part[i+len("urlprefix="):]
			if j := strings.IndexAny(token, ":;"); j >= 0 {
				token = token[:j]
			}
			if decoded, ok := decodeBase64(token); ok {
				if mpd, ok := dashManifest(decoded); ok {
					return mpd, true
				}
				if hls, ok := hlsManifest(decoded); ok {
					return hls, true
				}
			}
		}
		// CloudFront carries the same prefix inside a signed policy
		// (moviebox-tui adapt.rs:622-653).
		if policy, ok := strings.CutPrefix(part, "CloudFront-Policy="); ok {
			if decoded, ok := decodeBase64(cloudFrontAlphabet(policy)); ok {
				if resource := cloudFrontResource(decoded); resource != "" {
					if mpd, ok := dashManifest(resource); ok {
						return mpd, true
					}
				}
			}
		}
	}
	return "", false
}

// decodeBase64 accepts the standard and URL-safe alphabets the references use
// and restores the padding the cookies omit (adapt.rs:585-592).
func decodeBase64(s string) (string, bool) {
	s = strings.TrimSpace(s)
	if s == "" {
		return "", false
	}
	s = strings.NewReplacer("-", "+", "_", "/").Replace(s)
	if pad := (4 - len(s)%4) % 4; pad > 0 {
		s += strings.Repeat("=", pad)
	}
	b, err := base64.StdEncoding.DecodeString(s)
	if err != nil {
		return "", false
	}
	return string(b), true
}

// dashManifest mirrors to_dash_mpd (adapt.rs:573-583): only a /dash/ tree under
// an absolute http(s) prefix resolves.
func dashManifest(raw string) (string, bool) {
	base := strings.TrimRight(strings.TrimRight(strings.TrimSpace(raw), "*"), "/")
	if !strings.HasPrefix(base, "http://") && !strings.HasPrefix(base, "https://") {
		return "", false
	}
	if !strings.Contains(base, "/dash/") {
		return "", false
	}
	return base + "/index.mpd", true
}

// hlsManifest mirrors the Kotlin construction (LocalMovieBoxServer.kt:1000-1004).
func hlsManifest(raw string) (string, bool) {
	raw = strings.TrimSpace(raw)
	if !strings.HasPrefix(raw, "http://") && !strings.HasPrefix(raw, "https://") {
		return "", false
	}
	return strings.TrimRight(raw, "/") + "/index.m3u8", true
}

// cloudFrontAlphabet restores CloudFront's non-standard policy alphabet before
// decoding (adapt.rs:627-635).
func cloudFrontAlphabet(s string) string {
	return strings.NewReplacer("-", "+", "_", "=", "~", "/").Replace(strings.TrimSpace(s))
}

// cloudFrontResource reads Statement[0].Resource out of a decoded policy.
func cloudFrontResource(policy string) string {
	var doc struct {
		Statement []struct {
			Resource string `json:"Resource"`
		} `json:"Statement"`
	}
	if json.Unmarshal([]byte(policy), &doc) != nil || len(doc.Statement) == 0 {
		return ""
	}
	return doc.Statement[0].Resource
}

// renditions expands one stream entry into one Quality per advertised
// resolution, carrying that entry's size and cookie; the reference emits one
// release per resolution with per-resolution size (adapt.rs:751-778).
func renditions(s wireStream, target string) []models.Quality {
	labels := splitList(s.Resolutions)
	out := make([]models.Quality, 0, len(labels))
	for _, label := range labels {
		out = append(out, models.Quality{Label: label, URL: target, Size: s.Size, Cookie: s.SignCookie})
	}
	return out
}

func streamHeaders(cookie string) map[string]string {
	h := map[string]string{"User-Agent": streamUserAgent}
	if cookie != "" {
		h["Cookie"] = cookie
	}
	return h
}

// --- UGC bypass ---

func (p *Provider) ugcBypass(ctx context.Context, id string, season, episode int) (models.Stream, bool) {
	var first wireUGCFirst
	if err := p.call(ctx, http.MethodGet, "/wefeed-mobile-bff/ugc/video/first-by-subject?"+query("subjectId", id), "", &first); err != nil {
		return models.Stream{}, false
	}
	var resources []wireUGCResource
	if first.BelongToCollection != nil && first.BelongToCollection.CollectionID != "" {
		resources = p.ugcCollection(ctx, first.BelongToCollection.CollectionID, season, episode)
	}
	if len(resources) == 0 && first.UGCVideoID != "" {
		var dl wireUGCDownload
		if err := p.call(ctx, http.MethodGet, "/wefeed-mobile-bff/ugc/video/download?"+query("ugcVideoId", first.UGCVideoID), "", &dl); err == nil {
			for _, it := range dl.Items {
				resources = append(resources, it.Resources...)
			}
		}
	}
	return ugcRenditions(resources)
}

// ugcCollection matches the requested episode inside a UGC collection by its
// S{se}EP{ep}/E{ep} marker, falling back to the first item for episode 1, as
// Kotlin does (LocalMovieBoxServer.kt:864-890).
func (p *Provider) ugcCollection(ctx context.Context, collectionID string, season, episode int) []wireUGCResource {
	var dl wireUGCDownload
	path := "/wefeed-mobile-bff/ugc/collection/download-list?" + query("collectionId", collectionID, "page", "1", "perPage", "50")
	if err := p.call(ctx, http.MethodGet, path, "", &dl); err != nil {
		return nil
	}
	se, ep := targetEpisode(season, episode)
	for _, it := range dl.Items {
		hay := strings.ToUpper(it.EpTitle + " " + it.Title)
		if strings.Contains(hay, fmt.Sprintf("S%dEP%d", se, ep)) || strings.Contains(hay, fmt.Sprintf("E%d", ep)) {
			return it.Resources
		}
	}
	if ep == 1 && len(dl.Items) > 0 {
		return dl.Items[0].Resources
	}
	return nil
}

func targetEpisode(season, episode int) (int, int) {
	if season <= 0 {
		season = 1
	}
	if episode <= 0 {
		episode = 1
	}
	return season, episode
}

// ugcRenditions turns recovered UGC resources into renditions, dropping decoys
// and sorting high resolution first (the collection lists them ascending).
func ugcRenditions(resources []wireUGCResource) (models.Stream, bool) {
	var out models.Stream
	seen := map[string]struct{}{}
	for _, r := range resources {
		if !usableURL(r.URL) {
			continue
		}
		if out.URL == "" {
			out.URL = r.URL
			out.Headers = streamHeaders(r.SignCookie)
		}
		for _, label := range splitList(r.Resolutions) {
			key := label + "\x00" + r.URL
			if _, dup := seen[key]; dup {
				continue
			}
			seen[key] = struct{}{}
			out.Qualities = append(out.Qualities, models.Quality{Label: label, URL: r.URL, Size: r.Size, Cookie: r.SignCookie})
		}
	}
	if len(out.Qualities) == 0 {
		return models.Stream{}, false
	}
	sortQualityDesc(out.Qualities)
	return out, true
}

// --- resource re-resolve and episode durations ---

func (p *Provider) resourceStream(ctx context.Context, id string, season, episode int) (models.Stream, bool) {
	items, ok := p.resources(ctx, id, season, episode)
	if !ok {
		return models.Stream{}, false
	}
	var out models.Stream
	seen := map[string]struct{}{}
	for _, it := range items {
		if !usableURL(it.ResourceLink) {
			continue
		}
		if out.URL == "" {
			out.URL = it.ResourceLink
			out.Headers = streamHeaders("")
		}
		label := strconv.Itoa(it.Resolution)
		key := label + "\x00" + it.ResourceLink
		if _, dup := seen[key]; dup {
			continue
		}
		seen[key] = struct{}{}
		out.Qualities = append(out.Qualities, models.Quality{Label: label, URL: it.ResourceLink, Size: it.Size})
	}
	if len(out.Qualities) == 0 {
		return models.Stream{}, false
	}
	sortQualityDesc(out.Qualities)
	return out, true
}

// episodesWithDurations expands season-info and fills each episode's duration
// from the resource listing, the only endpoint that carries it
// (provider-gap-analysis.md §3). Duration is best-effort: a listing failure
// still returns the full tree. Titles are left empty because no canonical
// upstream field exists — Kotlin invents "Episode N", the TUI does not, and the
// iOS client already renders that fallback itself.
func (p *Provider) episodesWithDurations(ctx context.Context, id string) ([]models.Episode, error) {
	var out wireSeasonInfo
	if err := p.call(ctx, http.MethodGet, "/wefeed-mobile-bff/subject-api/season-info?"+query("subjectId", id), "", &out); err != nil {
		return nil, err
	}
	eps := out.episodes(id)
	items, ok := p.resources(ctx, id, 0, 0)
	if !ok {
		return eps, nil
	}
	durations := map[[2]int]int{}
	for _, it := range items {
		key := [2]int{it.Se, it.Ep}
		if _, seen := durations[key]; !seen && it.Duration > 0 {
			durations[key] = it.Duration
		}
	}
	for i := range eps {
		eps[i].DurationSeconds = durations[[2]int{eps[i].Season, eps[i].Number}]
	}
	return eps, nil
}

// resources pages the per-title resource listing. The listing is unfiltered by
// se/ep on the live cluster, so callers may pass zeros for the whole tree.
func (p *Provider) resources(ctx context.Context, id string, season, episode int) ([]wireResourceItem, bool) {
	base := []string{"subjectId", id}
	if season > 0 {
		base = append(base, "se", strconv.Itoa(season))
	}
	if episode > 0 {
		base = append(base, "ep", strconv.Itoa(episode))
	}
	var out []wireResourceItem
	for page := 1; page <= resourcePageLimit; page++ {
		var listing wireResourcePage
		params := append(append([]string{}, base...), "page", strconv.Itoa(page), "perPage", "50")
		if err := p.call(ctx, http.MethodGet, "/wefeed-mobile-bff/subject-api/resource?"+query(params...), "", &listing); err != nil {
			return out, len(out) > 0
		}
		out = append(out, listing.List...)
		if !listing.Pager.HasMore {
			break
		}
	}
	return out, len(out) > 0
}

func sortQualityDesc(qs []models.Quality) {
	sort.SliceStable(qs, func(i, j int) bool { return resolutionRank(qs[i].Label) > resolutionRank(qs[j].Label) })
}

func resolutionRank(label string) int {
	n, _ := strconv.Atoi(strings.TrimRight(strings.ToLower(strings.TrimSpace(label)), "p"))
	return n
}

// --- gateway wire types for the recovery rungs ---

type wireResourcePage struct {
	List  []wireResourceItem `json:"list"`
	Pager struct {
		HasMore bool `json:"hasMore"`
	} `json:"pager"`
}

type wireResourceItem struct {
	Se           int    `json:"se"`
	Ep           int    `json:"ep"`
	Duration     int    `json:"duration"`
	Resolution   int    `json:"resolution"`
	Size         string `json:"size"`
	ResourceLink string `json:"resourceLink"`
	ResourceID   string `json:"resourceId"`
}

type wireUGCFirst struct {
	UGCVideoID         string `json:"ugcVideoId"`
	BelongToCollection *struct {
		CollectionID string `json:"collectionId"`
	} `json:"belongToCollection"`
}

type wireUGCDownload struct {
	Items []wireUGCItem `json:"items"`
}

type wireUGCItem struct {
	EpTitle   string            `json:"epTitle"`
	Title     string            `json:"title"`
	Resources []wireUGCResource `json:"resources"`
}

type wireUGCResource struct {
	URL         string `json:"url"`
	Resolutions string `json:"resolutions"`
	Size        string `json:"size"`
	Duration    int    `json:"duration"`
	SignCookie  string `json:"signCookie"`
}
