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
	Stream(ctx context.Context, id string) (models.Stream, error)
	Subtitles(ctx context.Context, id string) ([]models.Subtitle, error)
}
