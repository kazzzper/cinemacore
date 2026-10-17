// Package session is the signed HTTP client for the MovieBox gateway: it owns
// host failover, request signing, the guest token, and response caching. Every
// provider talks to the network through this package.
package session

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/solo12345689/cinemacore/core/sign"
	"github.com/solo12345689/cinemacore/core/store/cache"
)

// ErrNoHosts is returned when no gateway host is configured.
var ErrNoHosts = errors.New("session: no hosts configured")

// MaxResponseBytes caps a single response body read (8 MiB).
const MaxResponseBytes = 8 << 20

// Config configures a Client.
type Config struct {
	Hosts      []string
	UserAgent  string
	ClientInfo string
	Timeout    time.Duration
	CacheTTL   time.Duration
	Now        func() time.Time
}

// Client is a signed, failover-aware gateway client. Safe for concurrent use.
type Client struct {
	cfg   Config
	hc    *http.Client
	cache *cache.Cache[string, []byte]

	mu    sync.Mutex
	host  int
	token string
}

// New builds a Client, applying defaults for zero fields.
func New(cfg Config) *Client {
	if cfg.Timeout == 0 {
		cfg.Timeout = 20 * time.Second
	}
	if cfg.CacheTTL == 0 {
		cfg.CacheTTL = 5 * time.Minute
	}
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	if cfg.UserAgent == "" {
		cfg.UserAgent = "okhttp/4.11.0"
	}
	return &Client{
		cfg:   cfg,
		hc:    &http.Client{Timeout: cfg.Timeout},
		cache: cache.New[string, []byte](256, cfg.CacheTTL),
	}
}

// Hosts returns the configured host pool.
func (c *Client) Hosts() []string { return c.cfg.Hosts }

// Do signs and sends one request, failing over across hosts on
// 403/429/5xx. GET responses are cached for the configured TTL.
func (c *Client) Do(ctx context.Context, method, path, body string) ([]byte, error) {
	cacheKey := method + " " + path
	if method == http.MethodGet {
		if b, ok := c.cache.Get(cacheKey); ok {
			return b, nil
		}
	}
	if len(c.cfg.Hosts) == 0 {
		return nil, ErrNoHosts
	}

	var lastErr error
	for attempt := 0; attempt < len(c.cfg.Hosts); attempt++ {
		rawURL := c.currentBase() + path
		ts := c.cfg.Now().UnixMilli()
		h := sign.Headers(method, rawURL, body, ts)

		var rdr io.Reader
		if body != "" {
			rdr = strings.NewReader(body)
		}
		req, err := http.NewRequestWithContext(ctx, method, rawURL, rdr)
		if err != nil {
			return nil, fmt.Errorf("session: build request: %w", err)
		}
		req.Header.Set("User-Agent", c.cfg.UserAgent)
		req.Header.Set("Accept", h.Accept)
		req.Header.Set("Content-Type", h.ContentType)
		req.Header.Set("X-Client-Token", h.ClientToken)
		req.Header.Set("x-tr-signature", h.TRSignature)
		if c.cfg.ClientInfo != "" {
			req.Header.Set("X-Client-Info", c.cfg.ClientInfo)
		}
		req.Header.Set("X-Client-Status", "0")
		if tok := c.Token(); tok != "" {
			req.Header.Set("Authorization", "Bearer "+tok)
		}

		resp, err := c.hc.Do(req)
		if err != nil {
			lastErr = fmt.Errorf("session: %s %s: %w", method, path, err)
			c.rotate()
			continue
		}
		data, readErr := io.ReadAll(io.LimitReader(resp.Body, MaxResponseBytes))
		resp.Body.Close()
		if readErr != nil {
			lastErr = fmt.Errorf("session: read %s: %w", path, readErr)
			c.rotate()
			continue
		}
		if resp.StatusCode >= 200 && resp.StatusCode < 300 {
			if method == http.MethodGet {
				c.cache.Put(cacheKey, data)
			}
			return data, nil
		}
		lastErr = fmt.Errorf("session: %s %s -> %d", method, path, resp.StatusCode)
		if retryable(resp.StatusCode) {
			c.rotate()
			continue
		}
		return nil, lastErr
	}
	return nil, lastErr
}

// Guest acquires an anonymous token (visitor-login). Idempotent.
func (c *Client) Guest(ctx context.Context) error {
	if c.Token() != "" {
		return nil
	}
	data, err := c.Do(ctx, http.MethodPost, "/wefeed-mobile-bff/user-api/visitor-login", "{}")
	if err != nil {
		return fmt.Errorf("session: guest login: %w", err)
	}
	var env struct {
		Data struct {
			Token string `json:"token"`
		} `json:"data"`
	}
	if err := json.Unmarshal(data, &env); err != nil {
		return fmt.Errorf("session: decode guest login: %w", err)
	}
	c.SetToken(env.Data.Token)
	return nil
}

// Token returns the current bearer token, if any.
func (c *Client) Token() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.token
}

// SetToken sets the bearer token.
func (c *Client) SetToken(t string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.token = t
}

func (c *Client) currentBase() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	h := c.cfg.Hosts[c.host]
	if strings.Contains(h, "://") {
		return h
	}
	return "https://" + h
}

func (c *Client) rotate() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.cfg.Hosts) > 0 {
		c.host = (c.host + 1) % len(c.cfg.Hosts)
	}
}

func retryable(code int) bool {
	return code == http.StatusForbidden || code == http.StatusTooManyRequests || code >= 500
}
