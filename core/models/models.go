// Package models holds the transport-agnostic domain types shared by every
// surface. Field names are stable and versioned by the OpenAPI contract.
package models

// Subject is a movie, series, or other catalog entry.
type Subject struct {
	ID                string             `json:"id"`
	Title             string             `json:"title"`
	Poster            string             `json:"poster,omitempty"`
	Year              int                `json:"year,omitempty"`
	Rating            float64            `json:"rating,omitempty"`
	Kind              string             `json:"kind,omitempty"`
	Synopsis          string             `json:"synopsis,omitempty"`
	Genres            []string           `json:"genres,omitempty"`
	Dubs              []string           `json:"dubs,omitempty"`
	DubOptions        []Dub              `json:"dubOptions,omitempty"`
	DurationMinutes   int                `json:"durationMinutes,omitempty"`
	SeasonCount       int                `json:"seasonCount,omitempty"`
	Cast              []CastMember       `json:"cast,omitempty"`
	ResourceDetectors []ResourceDetector `json:"resourceDetectors,omitempty"`
}

// CastMember is one credited person.
type CastMember struct {
	Name   string `json:"name"`
	Role   string `json:"role,omitempty"`
	Avatar string `json:"avatar,omitempty"`
}

// Dub is one selectable language version. The provider models it as a separate
// subject, so SubjectID is what playback must re-resolve.
type Dub struct {
	SubjectID    string `json:"subjectId"`
	LanguageName string `json:"languageName"`
	LanguageCode string `json:"languageCode,omitempty"`
	Original     bool   `json:"isOriginal,omitempty"`
}

// ResourceDetector is one provider playable mirror/upload resource.
type ResourceDetector struct {
	ResourceID string `json:"resourceId"`
	Name       string `json:"name"`
}

// Episode identifies one season/episode of a series subject.
type Episode struct {
	SubjectID string `json:"subjectId"`
	Season    int    `json:"season"`
	Number    int    `json:"number"`
	Title     string `json:"title,omitempty"`
	// DurationSeconds is the upstream per-episode length. It is absent on the
	// season-info payload and only present on the resource listing, so it is
	// zero for titles whose resources we could not read.
	DurationSeconds int `json:"durationSeconds,omitempty"`
}

// Season groups a series' episodes.
type Season struct {
	Number   int       `json:"number"`
	Episodes []Episode `json:"episodes"`
}

// Stream is a resolved playback source.
type Stream struct {
	URL       string            `json:"url"`
	Qualities []Quality         `json:"qualities,omitempty"`
	Headers   map[string]string `json:"headers,omitempty"`
	// Kind marks how the URL plays. Empty (the default) is direct media: an
	// HLS manifest or a progressive file a video player can open. "web" is a
	// browser-rendered embed page — the URL must be opened in a web view, never
	// handed to a native player or downloader.
	Kind string `json:"kind,omitempty"`
}

// KindWeb marks a stream whose URL is an embedded web player page.
const KindWeb = "web"

// Quality is one selectable stream rendition. Size and Cookie are per-rendition
// (upstream emits one stream entry, and one cookie, per resolution); Cookie is
// the media request's only credential and must reach the wire.
type Quality struct {
	Label  string `json:"label"`
	URL    string `json:"url"`
	Size   string `json:"size,omitempty"`
	Cookie string `json:"cookie,omitempty"`
	// Kind carries the Stream's marker per rendition: empty = media, KindWeb =
	// an embed page. Kept on the rendition too so a rendition list is
	// self-describing without its parent Stream.
	Kind string `json:"kind,omitempty"`
}

// Subtitle is one caption track.
type Subtitle struct {
	Lang   string `json:"lang"`
	URL    string `json:"url"`
	Format string `json:"format,omitempty"`
}

// StreamRendition is one selectable playback rendition.
type StreamRendition struct {
	Quality string `json:"quality"`
	URL     string `json:"url"`
	Size    string `json:"size,omitempty"`
	Cookie  string `json:"cookie,omitempty"`
	Kind    string `json:"kind,omitempty"`
}

// SubtitleTrack is one caption track in a PlayInfo payload.
type SubtitleTrack struct {
	Language string `json:"language"`
	URL      string `json:"url"`
	Format   string `json:"format,omitempty"`
}

// PlayInfo is the resolved playback payload for one episode or movie.
type PlayInfo struct {
	Streams   []StreamRendition `json:"streams"`
	Subtitles []SubtitleTrack   `json:"subtitles"`
}

// Section is a titled row of subjects (home rails, category rows).
type Section struct {
	Title string    `json:"title"`
	Items []Subject `json:"items"`
}

// Page is a collection of sections.
type Page struct {
	Sections []Section `json:"sections"`
}
