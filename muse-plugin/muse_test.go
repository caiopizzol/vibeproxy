package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
)

type roundTrip func(*http.Request) (*http.Response, error)

func (f roundTrip) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func TestRenewalPreservesRequest(t *testing.T) {
	previous := client
	defer func() { client = previous }()
	keys.values = map[string]string{"grant": "expired-key"}
	mints, calls := 0, 0
	client = &http.Client{Transport: roundTrip(func(r *http.Request) (*http.Response, error) {
		status, body := 200, `{"status":"completed","output":[]}`
		switch r.URL.Path {
		case "/muse-code/key":
			mints++
			if r.Header.Get("Authorization") != "Bearer grant" {
				t.Fatal("wrong mint token")
			}
			body = `{"api_key":"renewed","base_url":"https://api.meta.ai/v1"}`
		case "/v1/responses":
			calls++
			data, _ := io.ReadAll(r.Body)
			var payload map[string]any
			json.Unmarshal(data, &payload)
			if payload["max_output_tokens"] != float64(64) || payload["tool_choice"] != "auto" {
				t.Fatal("request semantics changed")
			}
			if bytes.Contains(data, []byte("image_generation")) {
				t.Fatal("injected image tool")
			}
			if calls == 1 {
				status = 401
			} else if r.Header.Get("Authorization") != "Bearer renewed" {
				t.Fatal("key was not renewed")
			}
		default:
			t.Fatal("unexpected endpoint")
		}
		return &http.Response{StatusCode: status, Header: http.Header{}, Body: io.NopCloser(strings.NewReader(body))}, nil
	})}
	_, err := execute(execution{Model: model, Payload: []byte(`{"input":"test","max_output_tokens":64,"tool_choice":"auto"}`), StorageJSON: []byte(`{"access_token":"grant"}`)}, false)
	if err != nil || mints != 1 || calls != 2 {
		t.Fatalf("err=%v mints=%d calls=%d", err, mints, calls)
	}
}
func TestNoRepeatedRenewal(t *testing.T) {
	previous := client
	defer func() { client = previous }()
	keys.values = map[string]string{"grant": "old"}
	calls := 0
	client = &http.Client{Transport: roundTrip(func(r *http.Request) (*http.Response, error) {
		calls++
		status, body := 401, `{}`
		if r.URL.Path == "/muse-code/key" {
			status = 200
			body = `{"api_key":"new","base_url":"https://api.meta.ai/v1"}`
		}
		return &http.Response{StatusCode: status, Body: io.NopCloser(strings.NewReader(body))}, nil
	})}
	_, err := execute(execution{Model: model, Payload: []byte(`{"input":"test"}`), StorageJSON: []byte(`{"access_token":"grant"}`)}, false)
	if err == nil || calls != 3 {
		t.Fatalf("retry not bounded: %v, calls=%d", err, calls)
	}
}

func TestUnsupportedToolChoice(t *testing.T) {
	_, err := execute(execution{Model: model, Payload: []byte(`{"input":"test","tool_choice":"required"}`), StorageJSON: []byte(`{"access_token":"grant"}`)}, false)
	if err == nil || !strings.Contains(err.Error(), "automatic tool choice") {
		t.Fatal("forced tool choice was not rejected")
	}
}
