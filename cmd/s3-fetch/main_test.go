package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

func TestObjectURL(t *testing.T) {
	u, err := objectURL("https://storage.example/api/", "bucket", "node images/archive.tar.gz")
	if err != nil {
		t.Fatal(err)
	}
	if got, want := u.String(), "https://storage.example/api/bucket/node%20images/archive.tar.gz"; got != want {
		t.Fatalf("URL = %q, want %q", got, want)
	}
}

func TestDownloadRetriesWithEndpointRegion(t *testing.T) {
	wanted := []byte("checksum")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") == "" {
			t.Error("request is unsigned")
		}
		if r.Header.Get("Authorization") != "" && !strings.Contains(r.Header.Get("Authorization"), "/us-west-1/s3/aws4_request") {
			w.WriteHeader(http.StatusBadRequest)
			_, _ = w.Write([]byte(`<Error><Code>AuthorizationHeaderMalformed</Code><Region>us-west-1</Region></Error>`))
			return
		}
		_, _ = w.Write(wanted)
	}))
	defer server.Close()

	output := t.TempDir() + "/object"
	err := download(config{
		Endpoint: server.URL, Bucket: "bucket", Object: "object", Output: output,
		AccessKey: "access", SecretKey: "secret", Region: "us-east-1",
	})
	if err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(output)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(wanted) {
		t.Fatalf("output = %q, want %q", got, wanted)
	}
}

func TestSign(t *testing.T) {
	req, err := http.NewRequest(http.MethodGet, "https://storage.example/bucket/object", nil)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 7, 17, 12, 34, 56, 0, time.UTC)
	sign(req, "access", "secret", "us-east-1", now)
	if req.Header.Get("X-Amz-Date") != "20260717T123456Z" {
		t.Fatalf("unexpected x-amz-date: %s", req.Header.Get("X-Amz-Date"))
	}
	if req.Header.Get("Authorization") == "" {
		t.Fatal("authorization header is empty")
	}
}
