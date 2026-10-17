// Package sign implements the MovieBox gateway request-signing contract.
//
// The contract is implemented independently in the Python API
// (moviebox_api/utils.py) and the Rust TUI
// (moviebox-tui/src/providers/moviebox/crypto.rs); both agree for ASCII
// payloads. This package is the single Go source of truth for every surface.
//
// Canonical string:
//
//	METHOD \n Accept \n Content-Type \n Content-Length \n ts_ms \n bodyMD5 \n path?sorted_query
package sign

import (
	"crypto/hmac"
	"crypto/md5"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"net/url"
	"sort"
	"strconv"
	"strings"
)

// gatewaySecret is base64(GATEWAY_SECRET_ONLINE): 30 bytes, byte-identical to
// the Rust DEFAULT_SECRET_BYTES constant.
const gatewaySecret = "76iRl07s0xSN9jqmEWAt79EBJZulIQIsV64FZr2O"

// BodySignatureMaxBytes mirrors the app's 0x19000 (102400) body truncation.
const BodySignatureMaxBytes = 0x19000

// Default signing headers used by the MovieBox app.
const (
	DefaultAccept      = "application/json"
	DefaultContentType = "application/json;charset=UTF-8"
)

// MD5Hex returns the lowercase hex MD5 of s ("" for empty, matching Python).
func MD5Hex(s string) string {
	if s == "" {
		return ""
	}
	sum := md5.Sum([]byte(s))
	return hex.EncodeToString(sum[:])
}

// SHA256Hex returns the lowercase hex SHA-256 of s ("" for empty).
func SHA256Hex(s string) string {
	if s == "" {
		return ""
	}
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}

// ClientToken builds the X-Client-Token: "<ts>,<md5(reversed ts)>".
func ClientToken(tsMillis int64) string {
	ts := strconv.FormatInt(tsMillis, 10)
	return ts + "," + MD5Hex(reverse(ts))
}

// TRSignature builds x-tr-signature: "<ts>|2|<base64(HMAC-MD5(secret, canonical))>".
func TRSignature(method, rawURL, accept, contentType, body string, tsMillis int64) string {
	bodyHash, bodyLen := "", ""
	if body != "" {
		truncated := body
		if len(truncated) > BodySignatureMaxBytes {
			truncated = truncated[:BodySignatureMaxBytes]
		}
		bodyHash = MD5Hex(truncated)
		bodyLen = strconv.Itoa(len(body))
	}

	canonical := strings.Join([]string{
		strings.ToUpper(method),
		accept,
		contentType,
		bodyLen,
		strconv.FormatInt(tsMillis, 10),
		bodyHash,
		resource(rawURL),
	}, "\n")

	key, err := base64.StdEncoding.DecodeString(gatewaySecret)
	if err != nil {
		// Unreachable: the constant is valid base64. Fail closed.
		panic("sign: invalid gateway secret: " + err.Error())
	}
	mac := hmac.New(md5.New, key)
	mac.Write([]byte(canonical))
	return fmt.Sprintf("%d|2|%s", tsMillis, base64.StdEncoding.EncodeToString(mac.Sum(nil)))
}

// SignedHeaders is the canonical set of gateway headers for one request.
type SignedHeaders struct {
	Accept      string
	ContentType string
	ClientToken string
	TRSignature string
}

// Headers returns the signing headers for a request at tsMillis.
func Headers(method, rawURL, body string, tsMillis int64) SignedHeaders {
	return SignedHeaders{
		Accept:      DefaultAccept,
		ContentType: DefaultContentType,
		ClientToken: ClientToken(tsMillis),
		TRSignature: TRSignature(method, rawURL, DefaultAccept, DefaultContentType, body, tsMillis),
	}
}

// GslbSign builds X-Gslb-Sign: sha256(packageName + sha256(deviceID)).
func GslbSign(packageName, deviceID string) string {
	return SHA256Hex(packageName + SHA256Hex(deviceID))
}

// PasswordMD5 mirrors the login password transform.
func PasswordMD5(password string) string { return MD5Hex(password) }

// resource returns "path?sorted_query": query pairs are URL-decoded and
// stably sorted by key, then joined with '&' (no re-encoding).
func resource(rawURL string) string {
	u, err := url.Parse(rawURL)
	if err != nil {
		return rawURL
	}
	base := u.EscapedPath()
	if base == "" {
		base = "/"
	}
	if u.RawQuery == "" {
		return base
	}

	type pair struct{ k, v string }
	var pairs []pair
	for _, kv := range strings.Split(u.RawQuery, "&") {
		if kv == "" {
			continue
		}
		k, v, _ := strings.Cut(kv, "=")
		dk, _ := url.QueryUnescape(k)
		dv, _ := url.QueryUnescape(v)
		pairs = append(pairs, pair{dk, dv})
	}
	sort.SliceStable(pairs, func(i, j int) bool { return pairs[i].k < pairs[j].k })

	var sb strings.Builder
	for i, p := range pairs {
		if i > 0 {
			sb.WriteByte('&')
		}
		sb.WriteString(p.k)
		sb.WriteByte('=')
		sb.WriteString(p.v)
	}
	return base + "?" + sb.String()
}

func reverse(s string) string {
	r := []rune(s)
	for i, j := 0, len(r)-1; i < j; i, j = i+1, j-1 {
		r[i], r[j] = r[j], r[i]
	}
	return string(r)
}
