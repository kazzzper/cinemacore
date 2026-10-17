package sign

import "testing"

// Golden vectors generated from the reference implementation
// (moviebox-internal-api/moviebox_api/utils.py). One byte of drift here breaks
// every signed request, so these are the P1 gate.
func TestClientToken(t *testing.T) {
	got := ClientToken(1700000000000)
	want := "1700000000000,e41bb805cc23fdc5541917da93d608d5"
	if got != want {
		t.Fatalf("ClientToken = %q, want %q", got, want)
	}
}

func TestTRSignature(t *testing.T) {
	cases := []struct {
		name, method, url, body string
		ts                      int64
		want                    string
	}{
		{
			name: "get with query", method: "GET",
			url: "https://apig.inmoviebox.com/wefeed-mobile-bff/subject-api/detail?subjectId=123&page=1&tab=0",
			ts:  1700000000000, want: "1700000000000|2|5i4LuyUxUltzHNIEBhHQVA==",
		},
		{
			name: "post json body", method: "POST",
			url:  "https://apig.inmoviebox.com/wefeed-mobile-bff/user-api/visitor-login",
			body: `{"clientInfo":{"package_name":"com.community.oneroom"}}`,
			ts:   1700000000001, want: "1700000000001|2|M9uRwz5I5tm5vSBI8KEIzg==",
		},
		{
			name: "get no query", method: "GET",
			url: "https://apig.inmoviebox.com/wefeed-mobile-bff/search",
			ts:  1700000000002, want: "1700000000002|2|V6DlEMNh1yxoNFQh540fzQ==",
		},
		{
			name: "body truncated at 102400", method: "POST",
			url:  "https://apig.inmoviebox.com/x",
			body: repeat("a", 102400) + "TRAILING_MUST_BE_IGNORED",
			ts:   1700000000003, want: "1700000000003|2|pyBOv/j+5I0FP6C30+yt5Q==",
		},
		{
			name: "duplicate + blank query keys", method: "GET",
			url: "https://apig.inmoviebox.com/p?b=2&a=1&a=3&c=",
			ts:  1700000000004, want: "1700000000004|2|vD/OjEvR95UT2iXamt5jbA==",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := TRSignature(tc.method, tc.url, DefaultAccept, DefaultContentType, tc.body, tc.ts)
			if got != tc.want {
				t.Fatalf("TRSignature = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestGslbSignAndPassword(t *testing.T) {
	if got, want := GslbSign("com.community.oneroom", "868203051234567"), "9071b411e7812cd20d564c3b523dda1c1b0abed0e9824273ff59cf3d903bb17d"; got != want {
		t.Fatalf("GslbSign = %q, want %q", got, want)
	}
	if got, want := PasswordMD5("secret123"), "5d7845ac6ee7cfffafc5fe5f35cf666d"; got != want {
		t.Fatalf("PasswordMD5 = %q, want %q", got, want)
	}
}

func repeat(s string, n int) string {
	out := make([]byte, 0, n*len(s))
	for i := 0; i < n; i++ {
		out = append(out, s...)
	}
	return string(out)
}
