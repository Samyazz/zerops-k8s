package main

import (
	"net/http"
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
