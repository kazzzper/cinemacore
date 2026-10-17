// Package provider defines the source contract every content backend
// implements. Adapters (moviebox, bdix, addons, tv) live in subpackages.
package provider

import (
	"context"
	"errors"

	"github.com/solo12345689/cinemacore/core/models"
)

// UnavailableError reports a source that answered the request but has nothing
// playable to offer — as opposed to a transport or decode failure. It exists so
// a surface can answer honestly when the upstream serves an anti-piracy decoy
// instead of content, rather than passing the decoy off as a stream.
type UnavailableError struct {
	Provider string
	Reason   string
}

func (e *UnavailableError) Error() string {
	if e.Provider == "" {
		return "no playable source: " + e.Reason
	}
	return e.Provider + ": no playable source: " + e.Reason
}

// IsUnavailable reports whether err is or wraps an UnavailableError.
func IsUnavailable(err error) bool {
	var target *UnavailableError
	return errors.As(err, &target)
}

// Provider is one content source.
type Provider interface {
	Name() string
	Home(ctx context.Context) (models.Page, error)
	Search(ctx context.Context, query string) ([]models.Subject, error)
	Detail(ctx context.Context, id string) (models.Subject, error)
	Episodes(ctx context.Context, id string) ([]models.Episode, error)
	// Stream resolves one playback source. A movie passes season and episode as
	// zero; a series passes both, and the provider answers with that episode.
	Stream(ctx context.Context, id string, season, episode int) (models.Stream, error)
	// Subtitles returns caption tracks for one episode (0 = the movie track).
	Subtitles(ctx context.Context, id string, episode int) ([]models.Subtitle, error)
	// Suggest returns type-ahead terms for a query.
	Suggest(ctx context.Context, query string) ([]string, error)
}
