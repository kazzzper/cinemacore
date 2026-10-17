// Package provider defines the source contract every content backend
// implements. Adapters (moviebox, bdix, addons, tv) live in subpackages.
package provider

import (
	"context"

	"github.com/solo12345689/cinemacore/core/models"
)

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
