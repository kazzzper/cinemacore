package sign

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The golden vectors live in contracts/signing-vectors.json and are shared with
// the Swift implementation (CinemacoreCore/Tests). One byte of drift breaks
// every signed request, so this file is the P1 gate for both surfaces: keeping
// the vectors in one place is what stops the two implementations diverging
// silently.

type trCase struct {
	Name            string `json:"name"`
	Method          string `json:"method"`
	URL             string `json:"url"`
	Body            string `json:"body"`
	BodyRepeatChar  string `json:"bodyRepeatChar"`
	BodyRepeatCount int    `json:"bodyRepeatCount"`
	BodyAppend      string `json:"bodyAppend"`
	TSMillis        int64  `json:"tsMillis"`
	Expected        string `json:"expected"`
}

type vectors struct {
	GatewaySecretBase64   string `json:"gatewaySecretBase64"`
	BodySignatureMaxBytes int    `json:"bodySignatureMaxBytes"`
	DefaultAccept         string `json:"defaultAccept"`
	DefaultContentType    string `json:"defaultContentType"`

	ClientTokens []struct {
		TSMillis int64  `json:"tsMillis"`
		Token    string `json:"token"`
	} `json:"clientTokens"`

	TRSignatures []trCase `json:"trSignatures"`

	GslbSign struct {
		PackageName string `json:"packageName"`
		DeviceID    string `json:"deviceID"`
		Expected    string `json:"expected"`
	} `json:"gslbSign"`

	PasswordMD5 struct {
		Input    string `json:"input"`
		Expected string `json:"expected"`
	} `json:"passwordMD5"`

	// Canonical-string cases generated from this implementation and asserted by
	// the Swift suite too, so the two resource() functions cannot drift.
	ResourceVectors struct {
		Cases []struct {
			Input    string `json:"input"`
			Expected string `json:"expected"`
		} `json:"cases"`
	} `json:"resourceVectors"`
}

// body materialises a case's payload. `bodyRepeatChar`/`bodyRepeatCount` exist
// so the 102400-byte truncation case does not put a 100 KB literal in the
// fixture; `bodyAppend` sits deliberately outside the repeated prefix.
func (c trCase) body() string {
	if c.BodyRepeatCount > 0 && c.BodyRepeatChar != "" {
		return strings.Repeat(c.BodyRepeatChar, c.BodyRepeatCount) + c.BodyAppend
	}
	return c.Body
}

func loadVectors(t *testing.T) vectors {
	t.Helper()
	path := filepath.Join("..", "..", "contracts", "signing-vectors.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v (Go tests must run from core/sign)", path, err)
	}
	var v vectors
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatalf("parse %s: %v", path, err)
	}
	if len(v.ClientTokens) == 0 || len(v.TRSignatures) == 0 {
		t.Fatalf("%s loaded but is empty", path)
	}
	return v
}

// The fixture must describe the implementation that actually ships; a mismatch
// here means the shared file has drifted from the compiled-in constants.
func TestVectorsMatchCompiledConstants(t *testing.T) {
	v := loadVectors(t)
	if v.GatewaySecretBase64 != gatewaySecret {
		t.Errorf("gateway secret: fixture %q, code %q", v.GatewaySecretBase64, gatewaySecret)
	}
	if v.BodySignatureMaxBytes != BodySignatureMaxBytes {
		t.Errorf("body max: fixture %d, code %d", v.BodySignatureMaxBytes, BodySignatureMaxBytes)
	}
	if v.DefaultAccept != DefaultAccept {
		t.Errorf("accept: fixture %q, code %q", v.DefaultAccept, DefaultAccept)
	}
	if v.DefaultContentType != DefaultContentType {
		t.Errorf("content type: fixture %q, code %q", v.DefaultContentType, DefaultContentType)
	}
}

func TestClientToken(t *testing.T) {
	for _, tc := range loadVectors(t).ClientTokens {
		if got := ClientToken(tc.TSMillis); got != tc.Token {
			t.Errorf("ClientToken(%d) = %q, want %q", tc.TSMillis, got, tc.Token)
		}
	}
}

func TestTRSignature(t *testing.T) {
	v := loadVectors(t)
	for _, tc := range v.TRSignatures {
		t.Run(tc.Name, func(t *testing.T) {
			got := TRSignature(
				tc.Method, tc.URL, v.DefaultAccept, v.DefaultContentType, tc.body(), tc.TSMillis,
			)
			if got != tc.Expected {
				t.Fatalf("TRSignature = %q, want %q", got, tc.Expected)
			}
		})
	}
}

func TestGslbSignAndPassword(t *testing.T) {
	v := loadVectors(t)
	if got := GslbSign(v.GslbSign.PackageName, v.GslbSign.DeviceID); got != v.GslbSign.Expected {
		t.Errorf("GslbSign = %q, want %q", got, v.GslbSign.Expected)
	}
	if got := PasswordMD5(v.PasswordMD5.Input); got != v.PasswordMD5.Expected {
		t.Errorf("PasswordMD5 = %q, want %q", got, v.PasswordMD5.Expected)
	}
}

// These vectors were generated from this function and are asserted by the Swift
// suite as well: they are what stops the two canonical-string implementations
// drifting on query decoding, sorting, or path escaping.
func TestResourceVectors(t *testing.T) {
	cases := loadVectors(t).ResourceVectors.Cases
	if len(cases) == 0 {
		t.Fatal("no resource vectors loaded")
	}
	for _, tc := range cases {
		if got := resource(tc.Input); got != tc.Expected {
			t.Errorf("resource(%q) = %q, want %q", tc.Input, got, tc.Expected)
		}
	}
}
