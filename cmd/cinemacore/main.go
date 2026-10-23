// Command cinemacore runs the REST API: the source-of-truth catalog and the
// provider gateway (MovieBox, StreamHype or both, per CINEMACORE_PROVIDER).
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/solo12345689/cinemacore/core/catalog"
	"github.com/solo12345689/cinemacore/core/provider"
	"github.com/solo12345689/cinemacore/core/provider/moviebox"
	"github.com/solo12345689/cinemacore/core/provider/streamhype"
	"github.com/solo12345689/cinemacore/core/session"
	"github.com/solo12345689/cinemacore/server"
)

const version = "0.1.0"

// defaultHosts is the gateway host pool (verified in-repo: api6 + api).
var defaultHosts = []string{"api6.aoneroom.com", "api.inmoviebox.com"}

func main() {
	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))

	providers, err := buildProviders(log)
	if err != nil {
		log.Error("provider configuration failed", "err", err)
		os.Exit(1)
	}

	srv := server.New(server.Options{
		Catalog:  catalog.New(providers...),
		Version:  version,
		SpecPath: envOr("CINEMACORE_SPEC", "contracts/openapi.yaml"),
		Logger:   log,
	})

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	errCh := make(chan error, 1)
	go func() { errCh <- srv.ListenAndServe(envOr("CINEMACORE_ADDR", ":8080")) }()

	select {
	case <-ctx.Done():
		log.Info("shutdown signal received")
	case err := <-errCh:
		if err != nil && !errors.Is(err, context.Canceled) {
			log.Error("server error", "err", err)
			os.Exit(1)
		}
	}
	time.Sleep(50 * time.Millisecond)
}

// buildProviders resolves CINEMACORE_PROVIDER (moviebox | streamhype | all)
// into the catalog's provider list. moviebox stays the default, so the
// deployed gateway does not change shape unintentionally; "all" merges search
// across both and falls through detail/stream in list order.
func buildProviders(log *slog.Logger) ([]provider.Provider, error) {
	switch envOr("CINEMACORE_PROVIDER", "moviebox") {
	case "streamhype":
		key := os.Getenv("TMDB_API_KEY")
		if key == "" {
			return nil, fmt.Errorf("CINEMACORE_PROVIDER=streamhype requires TMDB_API_KEY")
		}
		log.Info("catalog source: streamhype (TMDB + web embeds)")
		return []provider.Provider{streamhype.New(key)}, nil
	case "all":
		list := []provider.Provider{moviebox.New(newMovieboxClient(log))}
		if key := os.Getenv("TMDB_API_KEY"); key != "" {
			log.Info("catalog source: moviebox + streamhype")
			list = append(list, streamhype.New(key))
		} else {
			log.Warn("catalog source: moviebox only (TMDB_API_KEY unset, streamhype disabled)")
		}
		return list, nil
	case "moviebox":
		log.Info("catalog source: moviebox")
		return []provider.Provider{moviebox.New(newMovieboxClient(log))}, nil
	default:
		return nil, fmt.Errorf("unknown CINEMACORE_PROVIDER %q: want moviebox, streamhype or all", os.Getenv("CINEMACORE_PROVIDER"))
	}
}

// newMovieboxClient boots the signed session client and warms the guest
// session in the background; the gateway may be unreachable, so it must not
// block startup.
func newMovieboxClient(log *slog.Logger) *session.Client {
	client := session.New(session.Config{
		Hosts:      hostList(),
		ClientInfo: clientInfo(),
	})
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := client.Guest(ctx); err != nil {
			log.Warn("guest session unavailable; continuing unauthenticated", "err", err)
			return
		}
		log.Info("guest session acquired")
	}()
	return client
}

// hostList reads the gateway host pool; CINEMACORE_HOSTS overrides.
func hostList() []string {
	if h := os.Getenv("CINEMACORE_HOSTS"); h != "" {
		var hosts []string
		if json.Unmarshal([]byte(h), &hosts) == nil && len(hosts) > 0 {
			return hosts
		}
	}
	return defaultHosts
}

// clientInfo mirrors the official app's device metadata envelope. The gateway
// filters on it, so the fields (and the region/MCC pair) matter.
func clientInfo() string {
	info := map[string]any{
		"package_name":    "com.community.oneroom",
		"version_name":    "4.0.02",
		"version_code":    50020126,
		"os":              "android",
		"os_version":      "14",
		"install_ch":      "ps",
		"device_id":       "868203051234567",
		"install_store":   "ps",
		"gaid":            "",
		"brand":           "Google",
		"model":           "Pixel 6",
		"system_language": "en",
		"net":             "wifi",
		"region":          "IN",
		"timezone":        "Asia/Kolkata",
		"sp_code":         "404",
	}
	b, _ := json.Marshal(info)
	return string(b)
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
