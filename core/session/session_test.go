package session

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestDoSignsAndReads(t *testing.T) {
	var gotToken, gotSig string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotToken = r.Header.Get("X-Client-Token")
		gotSig = r.Header.Get("x-tr-signature")
		_, _ = w.Write([]byte(`{"ok":true}`))
	}))
	defer srv.Close()

	c := New(Config{Hosts: []string{srv.URL}})
	body, err := c.Do(context.Background(), http.MethodGet, "/v1/thing", "")
	if err != nil {
		t.Fatalf("Do: %v", err)
	}
	if string(body) != `{"ok":true}` {
		t.Fatalf("body = %q", body)
	}
	if gotToken == "" || gotSig == "" {
		t.Fatalf("missing signing headers: token=%q sig=%q", gotToken, gotSig)
	}
}

func TestDoFailsOverOnForbidden(t *testing.T) {
	bad := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusForbidden)
	}))
	defer bad.Close()
	good := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`"ok"`))
	}))
	defer good.Close()

	c := New(Config{Hosts: []string{bad.URL, good.URL}})
	body, err := c.Do(context.Background(), http.MethodGet, "/x", "")
	if err != nil {
		t.Fatalf("Do after failover: %v", err)
	}
	if string(body) != `"ok"` {
		t.Fatalf("body = %q", body)
	}
}

func TestGetIsCached(t *testing.T) {
	hits := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hits++
		_, _ = w.Write([]byte(`1`))
	}))
	defer srv.Close()

	c := New(Config{Hosts: []string{srv.URL}})
	for i := 0; i < 3; i++ {
		if _, err := c.Do(context.Background(), http.MethodGet, "/cached", ""); err != nil {
			t.Fatalf("Do: %v", err)
		}
	}
	if hits != 1 {
		t.Fatalf("upstream hits = %d, want 1 (cached)", hits)
	}
}
