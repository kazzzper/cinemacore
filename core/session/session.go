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
	"net/url"
	"strconv"
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

// statusMissToken/statusUnauthorized are the gateway's missing/expired guest
// token signals; both are answered by re-running the visitor-login bootstrap.
const (
	statusMissToken    = 441
	statusUnauthorized = 401
)

// Config configures a Client.
type Config struct {
	Hosts      []string
	UserAgent  string
	ClientInfo string
	AppID      string
	Region     string
	Lang       string
	OS         string
	AppVersion string
	SignVer    string
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
	// Defaults mirror the official MovieBox/4.0.02 Android identity; the gateway
	// filters on these, so they are not cosmetic.
	if cfg.UserAgent == "" {
		cfg.UserAgent = "MovieBox/4.0.02 (Android 14; Pixel 6)"
	}
	if cfg.AppID == "" {
		cfg.AppID = "4U01pxRu278GqCZKY9"
	}
	if cfg.Region == "" {
		cfg.Region = "IN"
	}
	if cfg.Lang == "" {
		cfg.Lang = "en"
	}
	if cfg.OS == "" {
		cfg.OS = "android"
	}
	if cfg.AppVersion == "" {
		cfg.AppVersion = "4.0.02"
	}
	if cfg.SignVer == "" {
		cfg.SignVer = "2.0"
	}
	return &Client{
		cfg:   cfg,
		hc:    &http.Client{Timeout: cfg.Timeout},
		cache: cache.New[string, []byte](256, cfg.CacheTTL),
	}
}

// Hosts returns the configured host pool.
func (c *Client) Hosts() []string { return c.cfg.Hosts }

// Do signs and sends one request, failing over across hosts on 403/429/5xx and
// re-bootstrapping the guest session on a missing/expired token (441/401).
// GET responses are cached for the configured TTL.
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

	data, status, err := c.attempt(ctx, method, path, body)
	if status == statusMissToken || status == statusUnauthorized {
		// Content endpoints answer 441 until a guest bearer is presented; drop any
		// stale token, mint a fresh one, and replay once.
		c.SetToken("")
		if gerr := c.Guest(ctx); gerr == nil {
			data, status, err = c.attempt(ctx, method, path, body)
		}
	}
	if err != nil {
		return nil, err
	}
	if method == http.MethodGet {
		c.cache.Put(cacheKey, data)
	}
	return data, nil
}

// attempt runs one request across the host pool, returning the last status code.
func (c *Client) attempt(ctx context.Context, method, path, body string) ([]byte, int, error) {
	var lastErr error
	lastStatus := 0
	for i := 0; i < len(c.cfg.Hosts); i++ {
		base := c.currentBase()
		rawURL := base + withHost(path, hostOf(base))
		ts := c.cfg.Now().UnixMilli()
		h := sign.Headers(method, rawURL, body, ts)

		var rdr io.Reader
		if body != "" {
			rdr = strings.NewReader(body)
		}
		req, err := http.NewRequestWithContext(ctx, method, rawURL, rdr)
		if err != nil {
			return nil, 0, fmt.Errorf("session: build request: %w", err)
		}
		c.setHeaders(req, base, ts, h)

		resp, err := c.hc.Do(req)
		if err != nil {
			lastErr = fmt.Errorf("session: %s %s: %w", method, path, err)
			c.rotate()
			continue
		}
		data, readErr := io.ReadAll(io.LimitReader(resp.Body, MaxResponseBytes))
		captured := captureUser(resp)
		resp.Body.Close()
		if captured != "" {
			c.SetToken(captured)
		}
		if readErr != nil {
			lastErr = fmt.Errorf("session: read %s: %w", path, readErr)
			c.rotate()
			continue
		}
		lastStatus = resp.StatusCode
		if resp.StatusCode >= 200 && resp.StatusCode < 300 {
			return data, resp.StatusCode, nil
		}
		lastErr = fmt.Errorf("session: %s %s -> %d", method, path, resp.StatusCode)
		if retryable(resp.StatusCode) {
			c.rotate()
			continue
		}
		return nil, resp.StatusCode, lastErr
	}
	return nil, lastStatus, lastErr
}

// setHeaders applies the gateway's required identity and signing headers.
func (c *Client) setHeaders(req *http.Request, base string, ts int64, h sign.SignedHeaders) {
	req.Header.Set("User-Agent", c.cfg.UserAgent)
	req.Header.Set("Accept", h.Accept)
	req.Header.Set("Content-Type", h.ContentType)
	req.Header.Set("X-Client-Token", h.ClientToken)
	req.Header.Set("x-tr-signature", h.TRSignature)
	req.Header.Set("X-M-Version", c.cfg.AppVersion)
	req.Header.Set("X-Sign-Version", c.cfg.SignVer)
	req.Header.Set("X-Play-Mode", "2")
	req.Header.Set("X-Timestamp", strconv.FormatInt(ts, 10))
	req.Header.Set("X-Client-Status", "0")
	req.Header.Set("appid", c.cfg.AppID)
	req.Header.Set("region", c.cfg.Region)
	req.Header.Set("lang", c.cfg.Lang)
	req.Header.Set("os", c.cfg.OS)
	req.Header.Set("Referer", base+"/")
	if c.cfg.ClientInfo != "" {
		req.Header.Set("X-Client-Info", c.cfg.ClientInfo)
	}
	if tok := c.Token(); tok != "" {
		req.Header.Set("Authorization", "Bearer "+tok)
	}
}

// Guest acquires an anonymous token (visitor-login). Idempotent.
func (c *Client) Guest(ctx context.Context) error {
	if c.Token() != "" {
		return nil
	}
	data, _, err := c.attempt(ctx, http.MethodPost, "/wefeed-mobile-bff/user-api/visitor-login", "{}")
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
	if env.Data.Token == "" {
		return errors.New("session: guest login returned no token")
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

// captureUser extracts a rotated guest token from the gateway's x-user header.
func captureUser(resp *http.Response) string {
	xu := resp.Header.Get("x-user")
	if xu == "" {
		return ""
	}
	var u struct {
		Token string `json:"token"`
	}
	if json.Unmarshal([]byte(xu), &u) == nil {
		return u.Token
	}
	return ""
}

// withHost appends the gateway's mandatory "host" query parameter, which is
// also covered by the request signature.
func withHost(path, host string) string {
	if host == "" {
		return path
	}
	u, err := url.Parse(path)
	if err != nil {
		return path
	}
	q := u.Query()
	q.Set("host", host)
	u.RawQuery = q.Encode()
	return u.String()
}

// hostOf returns the host:port of a base URL.
func hostOf(base string) string {
	if u, err := url.Parse(base); err == nil && u.Host != "" {
		return u.Host
	}
	return base
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
