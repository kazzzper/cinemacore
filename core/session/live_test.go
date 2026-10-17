package session

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// TestDoAddsHostParamAndIdentityHeaders guards the two things the gateway
// filters on: the signed "host" query parameter and the app identity headers.
func TestDoAddsHostParamAndIdentityHeaders(t *testing.T) {
	var gotHost, gotMVersion, gotAppID, gotClientInfo, gotSig string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotHost = r.URL.Query().Get("host")
		gotMVersion = r.Header.Get("X-M-Version")
		gotAppID = r.Header.Get("appid")
		gotClientInfo = r.Header.Get("X-Client-Info")
		gotSig = r.Header.Get("x-tr-signature")
		_, _ = w.Write([]byte(`{"code":0,"data":{}}`))
	}))
	defer srv.Close()

	c := New(Config{Hosts: []string{srv.URL}, ClientInfo: `{"sp_code":"404"}`})
	if _, err := c.Do(context.Background(), http.MethodGet, "/wefeed-mobile-bff/subject-api/get?subjectId=1", ""); err != nil {
		t.Fatalf("Do: %v", err)
	}
	wantHost := strings.TrimPrefix(srv.URL, "http://")
	if gotHost != wantHost {
		t.Errorf("host param = %q, want %q", gotHost, wantHost)
	}
	if gotMVersion != "4.0.02" {
		t.Errorf("X-M-Version = %q, want 4.0.02", gotMVersion)
	}
	if gotAppID == "" {
		t.Error("appid header missing")
	}
	if gotClientInfo != `{"sp_code":"404"}` {
		t.Errorf("X-Client-Info = %q", gotClientInfo)
	}
	if !strings.Contains(gotSig, "|2|") {
		t.Errorf("x-tr-signature = %q, want ts|2|sig", gotSig)
	}
}

// TestDoCapturesXUserToken verifies the guest token minted in the x-user
// response header is reused as a bearer on the next request.
func TestDoCapturesXUserToken(t *testing.T) {
	var gotAuth string
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		gotAuth = r.Header.Get("Authorization")
		if calls == 1 {
			w.Header().Set("x-user", `{"token":"guest-123","userId":"9"}`)
		}
		_, _ = w.Write([]byte(`{"code":0}`))
	}))
	defer srv.Close()

	c := New(Config{Hosts: []string{srv.URL}})
	_, _ = c.Do(context.Background(), http.MethodGet, "/one", "")
	if c.Token() != "guest-123" {
		t.Fatalf("token = %q, want guest-123", c.Token())
	}
	_, _ = c.Do(context.Background(), http.MethodGet, "/two", "")
	if gotAuth != "Bearer guest-123" {
		t.Errorf("second request Authorization = %q, want Bearer guest-123", gotAuth)
	}
}

// TestDoRebootstrapsOnMissToken verifies a 441 triggers visitor-login and a
// replay of the original request with the fresh token.
func TestDoRebootstrapsOnMissToken(t *testing.T) {
	var loginCalls, contentCalls int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/visitor-login"):
			loginCalls++
			_ = json.NewEncoder(w).Encode(map[string]any{
				"code": 0,
				"data": map[string]any{"token": "fresh-token"},
			})
		default:
			contentCalls++
			if r.Header.Get("Authorization") == "" {
				w.WriteHeader(statusMissToken)
				_, _ = w.Write([]byte(`{"code":441,"message":"miss token"}`))
				return
			}
			_, _ = w.Write([]byte(`{"code":0,"data":{"ok":true}}`))
		}
	}))
	defer srv.Close()

	c := New(Config{Hosts: []string{srv.URL}})
	body, err := c.Do(context.Background(), http.MethodGet, "/wefeed-mobile-bff/subject-api/get?subjectId=1", "")
	if err != nil {
		t.Fatalf("Do after re-auth: %v", err)
	}
	if !strings.Contains(string(body), `"ok":true`) {
		t.Fatalf("body = %s", body)
	}
	if loginCalls != 1 || contentCalls != 2 {
		t.Errorf("loginCalls=%d contentCalls=%d, want 1 and 2", loginCalls, contentCalls)
	}
	if c.Token() != "fresh-token" {
		t.Errorf("token = %q, want fresh-token", c.Token())
	}
}

// TestWithHost checks query merging without clobbering existing params.
func TestWithHost(t *testing.T) {
	got := withHost("/a/b?subjectId=1", "api.example.com")
	if !strings.Contains(got, "subjectId=1") || !strings.Contains(got, "host=api.example.com") {
		t.Fatalf("withHost = %q", got)
	}
}
