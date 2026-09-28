package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestRootHandler(t *testing.T) {
	// Force a known version for this test.
	saved := version
	version = "1.0.0"
	defer func() { version = saved }()

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	rr := httptest.NewRecorder()

	rootHandler(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("want 200, got %d", rr.Code)
	}
	body, _ := io.ReadAll(rr.Body)
	got := string(body)
	if !strings.Contains(got, "Hello, DevOps!") {
		t.Errorf("missing greeting: %q", got)
	}
	if !strings.Contains(got, "version=1.0.0") {
		t.Errorf("missing version: %q", got)
	}
}

func TestHealthHandler(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rr := httptest.NewRecorder()

	healthHandler(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("want 200, got %d", rr.Code)
	}
	body, _ := io.ReadAll(rr.Body)
	if strings.TrimSpace(string(body)) != "ok" {
		t.Errorf("want body 'ok', got %q", body)
	}
}

func TestVersionEndpoint(t *testing.T) {
	saved := version
	version = "2.3.4"
	defer func() { version = saved }()

	req := httptest.NewRequest(http.MethodGet, "/version", nil)
	rr := httptest.NewRecorder()

	versionHandler(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("want 200, got %d", rr.Code)
	}
	body, _ := io.ReadAll(rr.Body)
	if strings.TrimSpace(string(body)) != "2.3.4" {
		t.Errorf("want 2.3.4, got %q", body)
	}
}
