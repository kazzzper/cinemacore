// Package catalog aggregates providers into one query surface: it merges
// search results and falls through to the next provider on failure.
package catalog

import (
	"context"
	"sort"

	"github.com/solo12345689/cinemacore/core/models"
	"github.com/solo12345689/cinemacore/core/provider"
)

// Catalog queries a set of providers.
type Catalog struct{ providers []provider.Provider }

// New builds a catalog over the given providers (order = fallback order).
func New(ps ...provider.Provider) *Catalog { return &Catalog{providers: ps} }

// Providers returns the configured providers.
func (c *Catalog) Providers() []provider.Provider { return c.providers }

// Home returns the first provider's homepage.
func (c *Catalog) Home(ctx context.Context) (models.Page, error) {
	return c.first(func(p provider.Provider) (models.Page, error) { return p.Home(ctx) })
}

// Search merges and dedupes results across all providers, sorted by title.
func (c *Catalog) Search(ctx context.Context, q string) ([]models.Subject, error) {
	seen := map[string]struct{}{}
	var out []models.Subject
	var firstErr error
	for _, p := range c.providers {
		items, err := p.Search(ctx, q)
		if err != nil {
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		for _, s := range items {
			if s.ID == "" {
				continue
			}
			if _, dup := seen[s.ID]; dup {
				continue
			}
			seen[s.ID] = struct{}{}
			out = append(out, s)
		}
	}
	if len(out) == 0 && firstErr != nil {
		return nil, firstErr
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Title < out[j].Title })
	return out, nil
}

// Detail returns the first provider that resolves id.
func (c *Catalog) Detail(ctx context.Context, id string) (models.Subject, error) {
	return c.first(func(p provider.Provider) (models.Subject, error) { return p.Detail(ctx, id) })
}

// Episodes returns the first provider that resolves id.
func (c *Catalog) Episodes(ctx context.Context, id string) ([]models.Episode, error) {
	return c.first(func(p provider.Provider) ([]models.Episode, error) { return p.Episodes(ctx, id) })
}

// Stream returns the first provider that resolves id.
func (c *Catalog) Stream(ctx context.Context, id string) (models.Stream, error) {
	return c.first(func(p provider.Provider) (models.Stream, error) { return p.Stream(ctx, id) })
}

// Subtitles returns the first provider that resolves id.
func (c *Catalog) Subtitles(ctx context.Context, id string) ([]models.Subtitle, error) {
	return c.first(func(p provider.Provider) ([]models.Subtitle, error) { return p.Subtitles(ctx, id) })
}

// first tries each provider in order, returning the first success.
func (c *Catalog) first[T any](fn func(provider.Provider) (T, error)) (T, error) {
	var zero T
	var lastErr error
	for _, p := range c.providers {
		v, err := fn(p)
		if err == nil {
			return v, nil
		}
		lastErr = err
	}
	return zero, lastErr
}
