// Command cinemacore runs the REST API: the source-of-truth catalog and the
// MovieBox provider gateway.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/solo12345689/cinemacore/core/catalog"
	"github.com/solo12345689/cinemacore/core/provider/moviebox"
	"github.com/solo12345689/cinemacore/core/session"
	"github.com/solo12345689/cinemacore/server"
)

const version = "0.1.0"

// defaultHosts is the gateway host pool (verified in-repo: api6 + api).
var defaultHosts = []string{"api6.aoneroom.com", "api.inmoviebox.com"}

func main() {
	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))

	client := session.New(session.Config{
		Hosts:      hostList(),
		ClientInfo: clientInfo(),
	})
	// Guest bootstrap must not block startup: the gateway may be unreachable.
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := client.Guest(ctx); err != nil {
			log.Warn("guest session unavailable; continuing unauthenticated", "err", err)
			return
		}
		log.Info("guest session acquired")
	}()

	srv := server.New(server.Options{
		Catalog:  catalog.New(moviebox.New(client)),
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
