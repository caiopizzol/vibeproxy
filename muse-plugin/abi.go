package main

/*
#include <stdint.h>
#include <stdlib.h>

typedef struct {
	void* ptr;
	size_t len;
} cliproxy_buffer;

typedef int (*cliproxy_host_call_fn)(void*, const char*, const uint8_t*, size_t, cliproxy_buffer*);
typedef void (*cliproxy_host_free_fn)(void*, size_t);

typedef struct {
	uint32_t abi_version;
	void* host_ctx;
	cliproxy_host_call_fn call;
	cliproxy_host_free_fn free_buffer;
} cliproxy_host_api;

typedef int (*cliproxy_plugin_call_fn)(char*, uint8_t*, size_t, cliproxy_buffer*);
typedef void (*cliproxy_plugin_free_fn)(void*, size_t);
typedef void (*cliproxy_plugin_shutdown_fn)(void);

typedef struct {
	uint32_t abi_version;
	cliproxy_plugin_call_fn call;
	cliproxy_plugin_free_fn free_buffer;
	cliproxy_plugin_shutdown_fn shutdown;
} cliproxy_plugin_api;

extern int cliproxyPluginCall(char*, uint8_t*, size_t, cliproxy_buffer*);
extern void cliproxyPluginFree(void*, size_t);
extern void cliproxyPluginShutdown(void);

static const cliproxy_host_api* stored_host;

static void store_host_api(const cliproxy_host_api* host) {
	stored_host = host;
}

static int call_host_api(const char* method, const uint8_t* request, size_t request_len, cliproxy_buffer* response) {
	if (stored_host == NULL || stored_host->call == NULL) {
		return 1;
	}
	return stored_host->call(stored_host->host_ctx, method, request, request_len, response);
}

static void free_host_buffer(void* ptr, size_t len) {
	if (stored_host != NULL && stored_host->free_buffer != NULL && ptr != NULL) {
		stored_host->free_buffer(ptr, len);
	}
}
*/
import "C"

import (
	"encoding/json"
	"errors"
	"unsafe"
)

//export cliproxy_plugin_init
func cliproxy_plugin_init(host *C.cliproxy_host_api, plugin *C.cliproxy_plugin_api) C.int {
	if host == nil || plugin == nil || host.abi_version != 1 {
		return 1
	}
	C.store_host_api(host)
	plugin.abi_version = 1
	plugin.call = C.cliproxy_plugin_call_fn(C.cliproxyPluginCall)
	plugin.free_buffer = C.cliproxy_plugin_free_fn(C.cliproxyPluginFree)
	plugin.shutdown = C.cliproxy_plugin_shutdown_fn(C.cliproxyPluginShutdown)
	return 0
}

//export cliproxyPluginCall
func cliproxyPluginCall(method *C.char, request *C.uint8_t, size C.size_t, response *C.cliproxy_buffer) C.int {
	if response == nil || method == nil {
		return 1
	}
	response.ptr = nil
	response.len = 0
	result, err := dispatch(C.GoString(method), C.GoBytes(unsafe.Pointer(request), C.int(size)))
	envelope := map[string]any{"ok": err == nil, "result": result}
	if err != nil {
		status := 502
		var upstream responseError
		if errors.As(err, &upstream) {
			status = upstream.status
		}
		envelope["error"] = map[string]any{"code": "muse_error", "message": err.Error(), "http_status": status}
	}
	raw, _ := json.Marshal(envelope)
	response.ptr = C.CBytes(raw)
	response.len = C.size_t(len(raw))
	return 0
}

//export cliproxyPluginFree
func cliproxyPluginFree(ptr unsafe.Pointer, size C.size_t) { C.free(ptr) }

//export cliproxyPluginShutdown
func cliproxyPluginShutdown() { client.CloseIdleConnections() }

func hostCall(method string, payload any) bool {
	raw, err := json.Marshal(payload)
	if err != nil {
		return false
	}
	name := C.CString(method)
	defer C.free(unsafe.Pointer(name))
	data := C.CBytes(raw)
	defer C.free(data)
	var response C.cliproxy_buffer
	status := C.call_host_api(name, (*C.uint8_t)(data), C.size_t(len(raw)), &response)
	if response.ptr == nil {
		return false
	}
	defer C.free_host_buffer(response.ptr, response.len)
	var envelope struct {
		OK bool `json:"ok"`
	}
	return status == 0 && json.Unmarshal(C.GoBytes(response.ptr, C.int(response.len)), &envelope) == nil && envelope.OK
}

func main() {}
