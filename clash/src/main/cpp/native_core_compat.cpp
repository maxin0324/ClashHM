#include "native_core_compat.h"

#include <cstdlib>
#include <cstring>
#include <string>

static std::string g_home_dir;
static std::string g_last_error = "Rust native-core staticlib is missing";
static std::string g_selected_group;
static std::string g_selected_proxy;
static int g_last_tun_fd = -1;

static char* copy_string(const std::string& value) {
    char* out = static_cast<char*>(malloc(value.size() + 1));
    if (!out) {
        return nullptr;
    }
    memcpy(out, value.c_str(), value.size() + 1);
    return out;
}

static std::string escape_json(const std::string& value) {
    std::string out;
    for (char ch : value) {
        if (ch == '\\') {
            out += "\\\\";
        } else if (ch == '"') {
            out += "\\\"";
        } else if (ch == '\n') {
            out += "\\n";
        } else if (ch == '\r') {
            out += "\\r";
        } else {
            out += ch;
        }
    }
    return out;
}

extern "C" int clashhm_native_core_init(const char* home_dir) {
    g_home_dir = home_dir ? home_dir : "";
    g_last_error = "Rust native-core staticlib is missing; C++ compatibility layer cannot route TUN traffic";
    return 0;
}

extern "C" int clashhm_native_core_start_tun(int tun_fd, const char* clash_config) {
    g_last_tun_fd = tun_fd;
    const size_t len = clash_config ? strlen(clash_config) : 0;
    g_last_error = "native_core_cpp_compat: Rust native-core staticlib is missing; configLen=" + std::to_string(len);
    return -1001;
}

extern "C" int clashhm_native_core_stop(void) {
    g_last_tun_fd = -1;
    return 0;
}

extern "C" int clashhm_native_core_is_running(void) {
    return 0;
}

extern "C" char* clashhm_native_core_get_proxies_json(void) {
    return copy_string("[]");
}

extern "C" char* clashhm_native_core_parse_proxies_json(const char*) {
    return copy_string("[]");
}

extern "C" int clashhm_native_core_select_proxy(const char* group_name, const char* proxy_name) {
    g_selected_group = group_name ? group_name : "";
    g_selected_proxy = proxy_name ? proxy_name : "";
    return -1001;
}

extern "C" int clashhm_native_core_test_delay(const char* proxy_name, const char* url, int timeout_ms) {
    (void)proxy_name;
    (void)url;
    (void)timeout_ms;
    return -1001;
}

extern "C" char* clashhm_native_core_get_traffic_json(void) {
    return copy_string("{\"uploadSpeed\":0,\"downloadSpeed\":0,\"uploadTotal\":0,\"downloadTotal\":0}");
}

extern "C" char* clashhm_native_core_get_connections_json(void) {
    return copy_string("[]");
}

extern "C" char* clashhm_native_core_get_status_json(void) {
    std::string json = "{\"running\":false,"
        "\"engine\":\"cpp-compat\","
        "\"status\":\"native_core_cpp_compat\","
        "\"tunFd\":" + std::to_string(g_last_tun_fd) + ","
        "\"home\":\"" + escape_json(g_home_dir) + "\","
        "\"selectedGroup\":\"" + escape_json(g_selected_group) + "\","
        "\"selectedProxy\":\"" + escape_json(g_selected_proxy) + "\","
        "\"lastError\":\"" + escape_json(g_last_error) + "\"}";
    return copy_string(json);
}

extern "C" void clashhm_native_core_free_string(char* value) {
    free(value);
}
