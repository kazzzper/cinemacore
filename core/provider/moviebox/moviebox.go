// Package moviebox adapts the MovieBox gateway to the provider contract.
package moviebox

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"strconv"

	"github.com/solo12345689/cinemacore/core/models"
	"github.com/solo12345689/cinemacore/core/session"
)

// Provider talks to the MovieBox BFF through a signed session.
type Provider struct{ s *session.Client }

// New returns a MovieBox provider over the given session client.
func New(s *session.Client) *Provider { return &Provider{s: s} }

// Name identifies this provider.
func (p *Provider) Name() string { return "moviebox" }

// Home returns the landing sections.
func (p *Provider) Home(ctx context.Context) (models.Page, error) {
	var out models.Page
	err := p.data(ctx, "/wefeed-mobile-bff/subject-api/index?"+query("page", "1", "tabId", "0"), &out)
	return out, err
}

// Search returns subjects matching query.
func (p *Provider) Search(ctx context.Context, q string) ([]models.Subject, error) {
	var out []models.Subject
	err := p.data(ctx, "/wefeed-mobile-bff/subject-api/search?"+query("keyword", q, "page", "1"), &out)
	return out, err
}

// Detail returns one subject.
func (p *Provider) Detail(ctx context.Context, id string) (models.Subject, error) {
	var out models.Subject
	err := p.data(ctx, "/wefeed-mobile-bff/subject-api/detail?"+query("subjectId", id), &out)
	return out, err
}

// Episodes returns the season/episode list for a series.
func (p *Provider) Episodes(ctx context.Context, id string) ([]models.Episode, error) {
	var out []models.Episode
	err := p.data(ctx, "/wefeed-mobile-bff/subject-api/season-info?"+query("subjectId", id), &out)
	return out, err
}

// Stream resolves a playback source.
func (p *Provider) Stream(ctx context.Context, id string, season, episode int) (models.Stream, error) {
	params := []string{"subjectId", id}
	if season > 0 {
		params = append(params, "season", strconv.Itoa(season))
	}
	if episode > 0 {
		params = append(params, "episode", strconv.Itoa(episode))
	}
	var out models.Stream
	err := p.data(ctx, "/wefeed-mobile-bff/subject-api/play-info?"+query(params...), &out)
	return out, err
}

// Subtitles returns caption tracks for a subject.
func (p *Provider) Subtitles(ctx context.Context, id string) ([]models.Subtitle, error) {
	var out []models.Subtitle
	err := p.data(ctx, "/wefeed-mobile-bff/subject-api/subtitle?"+query("subjectId", id), &out)
	return out, err
}

// data calls the gateway, unwraps the {code,message,data} envelope, and decodes
// data into out. The envelope shape matches the reference API.
func (p *Provider) data(ctx context.Context, path string, out any) error {
	raw, err := p.s.Do(ctx, "GET", path, "")
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
	if len(env.Data) == 0 {
		return fmt.Errorf("moviebox: empty data (%s)", env.Message)
	}
	if err := json.Unmarshal(env.Data, out); err != nil {
		return fmt.Errorf("moviebox: decode data: %w", err)
	}
	return nil
}

func query(kv ...string) string {
	v := url.Values{}
	for i := 0; i+1 < len(kv); i += 2 {
		v.Set(kv[i], kv[i+1])
	}
	return v.Encode()
}
