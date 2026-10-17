// Package models holds the transport-agnostic domain types shared by every
// surface. Field names are stable and versioned by the OpenAPI contract.
package models

// Subject is a movie, series, or other catalog entry.
type Subject struct {
	ID       string   `json:"id"`
	Title    string   `json:"title"`
	Poster   string   `json:"poster,omitempty"`
	Year     int      `json:"year,omitempty"`
	Rating   float64  `json:"rating,omitempty"`
	Kind     string   `json:"kind,omitempty"`
	Synopsis string   `json:"synopsis,omitempty"`
	Genres   []string `json:"genres,omitempty"`
	Dubs     []string `json:"dubs,omitempty"`
}

// Episode identifies one season/episode of a series subject.
type Episode struct {
	SubjectID string `json:"subjectId"`
	Season    int    `json:"season"`
	Number    int    `json:"number"`
	Title     string `json:"title,omitempty"`
}

// Quality is one selectable stream rendition.
type Quality struct {
	Label string `json:"label"`
	URL   string `json:"url"`
}

// Stream is a resolved playback source.
type Stream struct {
	URL       string            `json:"url"`
	Qualities []Quality         `json:"qualities,omitempty"`
	Headers   map[string]string `json:"headers,omitempty"`
}

// Subtitle is one caption track.
type Subtitle struct {
	Lang   string `json:"lang"`
	URL    string `json:"url"`
	Format string `json:"format,omitempty"`
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
