package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"
)

type responseError struct {
	status  int
	message string
}

func (e responseError) Error() string { return e.message }

const model = "muse-spark-1.3"
const origin = "https://api.meta.ai"

var client = &http.Client{Timeout: 5 * time.Minute, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
var keys = struct {
	sync.Mutex
	values map[string]string
}{values: map[string]string{}}

type credential struct {
	Type        string `json:"type"`
	AccessToken string `json:"access_token"`
	Email       string `json:"email"`
	Disabled    bool   `json:"disabled"`
}
type execution struct {
	Model, Format, SourceFormat string
	Payload, StorageJSON        []byte
	AuthMetadata                map[string]any
	StreamID                    string `json:"stream_id"`
}

func registration() any {
	return map[string]any{"schema_version": 1, "metadata": map[string]any{"Name": "muse", "Version": "0.1.0", "Author": "caiopizzol", "GitHubRepository": "https://github.com/caiopizzol/vibeproxy", "ConfigFields": []any{}}, "capabilities": map[string]any{
		"auth_provider": true, "model_provider": true, "executor": true, "executor_model_scope": "oauth", "executor_input_formats": []string{"responses"}, "executor_output_formats": []string{"responses"},
	}}
}
func dispatch(method string, raw []byte) (any, error) {
	switch method {
	case "plugin.register", "plugin.reconfigure":
		return registration(), nil
	case "auth.identifier", "executor.identifier":
		return map[string]any{"identifier": "muse"}, nil
	case "auth.parse":
		var req struct {
			FileName string
			RawJSON  []byte
		}
		if err := json.Unmarshal(raw, &req); err != nil {
			return nil, err
		}
		var c credential
		if json.Unmarshal(req.RawJSON, &c) != nil || c.Type != "muse" {
			return map[string]any{"Handled": false}, nil
		}
		if c.AccessToken == "" {
			return nil, errors.New("Muse account has no login token")
		}
		return map[string]any{"Handled": true, "Auth": map[string]any{"Provider": "muse", "ID": req.FileName, "FileName": req.FileName, "Label": c.Email, "Disabled": c.Disabled, "StorageJSON": req.RawJSON, "Metadata": map[string]any{"type": "muse", "email": c.Email, "access_token": c.AccessToken}}}, nil
	case "model.static", "model.for_auth":
		return map[string]any{"Provider": "muse", "Models": []any{map[string]any{"ID": model, "Object": "model", "OwnedBy": "meta", "DisplayName": "Muse Spark 1.3", "UserDefined": true}}}, nil
	case "executor.execute", "executor.execute_stream":
		var req execution
		if err := json.Unmarshal(raw, &req); err != nil {
			return nil, err
		}
		return execute(req, method == "executor.execute_stream")
	case "auth.refresh":
		// The Meta grant is not an OAuth refresh token; expired grants require login.
		return nil, errors.New("Reconnect Muse to renew the Meta login")
	default:
		return nil, fmt.Errorf("Muse does not support %s", method)
	}
}
func mint(token string) (string, error) {
	req, _ := http.NewRequest("POST", origin+"/muse-code/key", strings.NewReader("{}"))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("x-api-version", "1.0.0")
	resp, err := client.Do(req)
	if err != nil {
		return "", errors.New("Muse credential service unavailable")
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return "", fmt.Errorf("Muse credential renewal failed (HTTP %d); reconnect Muse", resp.StatusCode)
	}
	var body struct {
		Key  string `json:"api_key"`
		Base string `json:"base_url"`
	}
	if json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&body) != nil || body.Key == "" || body.Base != origin+"/v1" {
		return "", errors.New("Invalid Muse credential response")
	}
	return body.Key, nil
}
func apiKey(token string, rejected string) (string, error) {
	keys.Lock()
	defer keys.Unlock()
	if key := keys.values[token]; key != "" && key != rejected {
		return key, nil
	}
	key, err := mint(token)
	if err == nil {
		keys.values[token] = key
	}
	return key, err
}
func execute(req execution, stream bool) (any, error) {
	if req.Model != model {
		return nil, errors.New("Unsupported Muse model")
	}
	var c credential
	_ = json.Unmarshal(req.StorageJSON, &c)
	if c.AccessToken == "" {
		c.AccessToken, _ = req.AuthMetadata["access_token"].(string)
	}
	if c.AccessToken == "" {
		return nil, errors.New("Reconnect Muse: missing login token")
	}
	var body map[string]json.RawMessage
	if json.Unmarshal(req.Payload, &body) != nil {
		return nil, errors.New("Invalid Muse request")
	}
	if req.Format != "" && req.Format != "responses" && req.Format != "openai-response" {
		return nil, responseError{400, "Muse requires the Responses API"}
	}
	if choice, exists := body["tool_choice"]; exists && string(choice) != `"auto"` {
		return nil, responseError{400, "Muse supports only automatic tool choice"}
	}
	body["model"], _ = json.Marshal(model)
	body["stream"], _ = json.Marshal(stream)
	payload, _ := json.Marshal(body)
	key, err := apiKey(c.AccessToken, "")
	if err != nil {
		return nil, err
	}
	var resp *http.Response
	for attempt := 0; attempt < 2; attempt++ {
		upstream, _ := http.NewRequest("POST", origin+"/v1/responses", bytes.NewReader(payload))
		upstream.Header.Set("Authorization", "Bearer "+key)
		upstream.Header.Set("Content-Type", "application/json")
		resp, err = client.Do(upstream)
		if err != nil {
			return nil, errors.New("Muse request failed")
		}
		if resp.StatusCode != 401 || attempt == 1 {
			break
		}
		resp.Body.Close()
		key, err = apiKey(c.AccessToken, key)
		if err != nil {
			return nil, err
		}
	}
	if resp.StatusCode != 200 {
		defer resp.Body.Close()
		return nil, responseError{resp.StatusCode, fmt.Sprintf("Muse rejected the request (HTTP %d)", resp.StatusCode)}
	}
	headers := http.Header{"Content-Type": []string{resp.Header.Get("Content-Type")}}
	if !stream {
		defer resp.Body.Close()
		data, err := io.ReadAll(io.LimitReader(resp.Body, 32<<20))
		return map[string]any{"Payload": data, "Headers": headers}, err
	}
	if req.StreamID == "" {
		resp.Body.Close()
		return nil, errors.New("Muse streaming requires host stream support")
	}
	go func() {
		defer resp.Body.Close()
		defer hostCall("host.stream.close", map[string]any{"stream_id": req.StreamID})
		scanner := bufio.NewScanner(resp.Body)
		scanner.Buffer(make([]byte, 65536), 16<<20)
		var event []byte
		for scanner.Scan() {
			event = append(event, scanner.Bytes()...)
			event = append(event, '\n')
			if len(scanner.Bytes()) == 0 {
				if !hostCall("host.stream.emit", map[string]any{"stream_id": req.StreamID, "payload": event}) {
					return
				}
				event = nil
			}
		}
		if scanner.Err() != nil {
			hostCall("host.stream.emit", map[string]any{"stream_id": req.StreamID, "error": "Muse stream interrupted"})
		}
	}()
	return map[string]any{"headers": headers, "stream_id": req.StreamID}, nil
}
