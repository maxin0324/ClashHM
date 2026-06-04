#include "napi/native_api.h"
#include <cstring>
#include <cstdlib>
#include <dlfcn.h>
#include <string>

typedef char* (*fn_clash_init)(char*);
typedef char* (*fn_clash_start_file)(char*);
typedef void  (*fn_clash_stop)();
typedef int   (*fn_clash_is_running)();
typedef char* (*fn_clash_get_proxies)();
typedef int   (*fn_clash_select_proxy)(char*, char*);
typedef int   (*fn_clash_test_delay)(char*, char*, int);
typedef char* (*fn_clash_get_traffic)();
typedef char* (*fn_clash_get_connections)();
typedef void  (*fn_clash_close_all_connections)();
typedef void  (*fn_clash_close_connection)(char*);
typedef char* (*fn_clash_get_mode)();
typedef void  (*fn_clash_set_mode)(char*);
typedef void  (*fn_clash_set_tun_fd)(int);
typedef void  (*fn_clash_free_string)(char*);

static fn_clash_init               p_ClashInit = nullptr;
static fn_clash_start_file         p_ClashStartFile = nullptr;
static fn_clash_stop               p_ClashStop = nullptr;
static fn_clash_is_running         p_ClashIsRunning = nullptr;
static fn_clash_get_proxies        p_ClashGetProxies = nullptr;
static fn_clash_select_proxy       p_ClashSelectProxy = nullptr;
static fn_clash_test_delay         p_ClashTestDelay = nullptr;
static fn_clash_get_traffic        p_ClashGetTraffic = nullptr;
static fn_clash_get_connections    p_ClashGetConnections = nullptr;
static fn_clash_close_all_connections p_ClashCloseAllConnections = nullptr;
static fn_clash_close_connection   p_ClashCloseConnection = nullptr;
static fn_clash_get_mode           p_ClashGetMode = nullptr;
static fn_clash_set_mode           p_ClashSetMode = nullptr;
static fn_clash_set_tun_fd         p_ClashSetTunFd = nullptr;
static fn_clash_free_string        p_ClashFreeString = nullptr;

static void* mihomoLib = nullptr;
static bool engineLoaded = false;

static napi_value returnString(napi_env env, const char* str) {
    napi_value result;
    napi_create_string_utf8(env, str, strlen(str), &result);
    return result;
}

static napi_value returnGoString(napi_env env, char* str) {
    napi_value result;
    if (str == nullptr) {
        napi_get_null(env, &result);
        return result;
    }
    napi_create_string_utf8(env, str, strlen(str), &result);
    if (p_ClashFreeString) p_ClashFreeString(str);
    return result;
}

static char* getNapiString(napi_env env, napi_value val) {
    size_t len = 0;
    napi_get_value_string_utf8(env, val, nullptr, 0, &len);
    char* buf = (char*)malloc(len + 1);
    napi_get_value_string_utf8(env, val, buf, len + 1, &len);
    return buf;
}

static bool LoadMihomoFromPath(const char* path) {
    if (mihomoLib) return true;

    mihomoLib = dlopen(path, RTLD_LAZY);
    if (!mihomoLib) return false;

    p_ClashInit = (fn_clash_init)dlsym(mihomoLib, "ClashInit");
    p_ClashStartFile = (fn_clash_start_file)dlsym(mihomoLib, "ClashStartFile");
    p_ClashStop = (fn_clash_stop)dlsym(mihomoLib, "ClashStop");
    p_ClashIsRunning = (fn_clash_is_running)dlsym(mihomoLib, "ClashIsRunning");
    p_ClashGetProxies = (fn_clash_get_proxies)dlsym(mihomoLib, "ClashGetProxies");
    p_ClashSelectProxy = (fn_clash_select_proxy)dlsym(mihomoLib, "ClashSelectProxy");
    p_ClashTestDelay = (fn_clash_test_delay)dlsym(mihomoLib, "ClashTestDelay");
    p_ClashGetTraffic = (fn_clash_get_traffic)dlsym(mihomoLib, "ClashGetTraffic");
    p_ClashGetConnections = (fn_clash_get_connections)dlsym(mihomoLib, "ClashGetConnections");
    p_ClashCloseAllConnections = (fn_clash_close_all_connections)dlsym(mihomoLib, "ClashCloseAllConnections");
    p_ClashCloseConnection = (fn_clash_close_connection)dlsym(mihomoLib, "ClashCloseConnection");
    p_ClashGetMode = (fn_clash_get_mode)dlsym(mihomoLib, "ClashGetMode");
    p_ClashSetMode = (fn_clash_set_mode)dlsym(mihomoLib, "ClashSetMode");
    p_ClashSetTunFd = (fn_clash_set_tun_fd)dlsym(mihomoLib, "ClashSetTunFd");
    p_ClashFreeString = (fn_clash_free_string)dlsym(mihomoLib, "ClashFreeString");

    engineLoaded = (p_ClashInit != nullptr);
    return engineLoaded;
}

// --- NAPI Functions ---

static napi_value NapiLoadEngine(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    char* libDir = getNapiString(env, args[0]);
    std::string result = "failed";

    // Try multiple paths
    std::string paths[] = {
        std::string(libDir) + "/libmihomo.so",
        std::string(libDir) + "/libs/arm64-v8a/libmihomo.so",
        std::string(libDir) + "/libs/arm64/libmihomo.so",
        "libmihomo.so",
    };

    for (const auto& path : paths) {
        if (LoadMihomoFromPath(path.c_str())) {
            result = "loaded:" + path;
            break;
        }
    }

    if (!engineLoaded) {
        const char* err = dlerror();
        result = std::string("failed:") + (err ? err : "unknown");
    }

    free(libDir);
    return returnString(env, result.c_str());
}

static napi_value NapiClashInit(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char* homeDir = getNapiString(env, args[0]);
    char* r = p_ClashInit ? p_ClashInit(homeDir) : nullptr;
    free(homeDir);
    if (r) return returnGoString(env, r);
    return returnString(env, engineLoaded ? "{\"status\":\"ok\"}" : "{\"error\":\"engine not loaded\"}");
}

static napi_value NapiClashStartFile(napi_env env, napi_callback_info info) {
    if (!p_ClashStartFile) {
        return returnString(env, "{\"error\":\"engine not loaded\"}");
    }
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char* path = getNapiString(env, args[0]);
    char* r = p_ClashStartFile(path);
    free(path);
    if (r) return returnGoString(env, r);
    return returnString(env, "{\"error\":\"start returned null\"}");
}

static napi_value NapiClashStop(napi_env env, napi_callback_info info) {
    if (p_ClashStop) p_ClashStop();
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

static napi_value NapiClashIsRunning(napi_env env, napi_callback_info info) {
    napi_value result;
    napi_create_int32(env, p_ClashIsRunning ? p_ClashIsRunning() : 0, &result);
    return result;
}

static napi_value NapiClashGetProxies(napi_env env, napi_callback_info info) {
    char* r = p_ClashGetProxies ? p_ClashGetProxies() : nullptr;
    if (r) return returnGoString(env, r);
    return returnString(env, "[]");
}

static napi_value NapiClashSelectProxy(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char* group = getNapiString(env, args[0]);
    char* proxy = getNapiString(env, args[1]);
    napi_value result;
    napi_create_int32(env, p_ClashSelectProxy ? p_ClashSelectProxy(group, proxy) : -1, &result);
    free(group);
    free(proxy);
    return result;
}

static napi_value NapiClashTestDelay(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char* name = getNapiString(env, args[0]);
    char* url = getNapiString(env, args[1]);
    int timeout = 5000;
    napi_get_value_int32(env, args[2], &timeout);
    napi_value result;
    napi_create_int32(env, p_ClashTestDelay ? p_ClashTestDelay(name, url, timeout) : -1, &result);
    free(name);
    free(url);
    return result;
}

static napi_value NapiClashGetTraffic(napi_env env, napi_callback_info info) {
    char* r = p_ClashGetTraffic ? p_ClashGetTraffic() : nullptr;
    if (r) return returnGoString(env, r);
    return returnString(env, "{\"uploadSpeed\":0,\"downloadSpeed\":0,\"uploadTotal\":0,\"downloadTotal\":0}");
}

static napi_value NapiClashGetConnections(napi_env env, napi_callback_info info) {
    char* r = p_ClashGetConnections ? p_ClashGetConnections() : nullptr;
    if (r) return returnGoString(env, r);
    return returnString(env, "[]");
}

static napi_value NapiClashCloseAllConnections(napi_env env, napi_callback_info info) {
    if (p_ClashCloseAllConnections) p_ClashCloseAllConnections();
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

static napi_value NapiClashCloseConnection(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char* id = getNapiString(env, args[0]);
    if (p_ClashCloseConnection) p_ClashCloseConnection(id);
    free(id);
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

static napi_value NapiClashGetMode(napi_env env, napi_callback_info info) {
    char* r = p_ClashGetMode ? p_ClashGetMode() : nullptr;
    if (r) return returnGoString(env, r);
    return returnString(env, "rule");
}

static napi_value NapiClashSetMode(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char* mode = getNapiString(env, args[0]);
    if (p_ClashSetMode) p_ClashSetMode(mode);
    free(mode);
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

static napi_value NapiClashSetTunFd(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int fd = 0;
    napi_get_value_int32(env, args[0], &fd);
    if (p_ClashSetTunFd) p_ClashSetTunFd(fd);
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"loadEngine", nullptr, NapiLoadEngine, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"init", nullptr, NapiClashInit, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startFile", nullptr, NapiClashStartFile, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stop", nullptr, NapiClashStop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isRunning", nullptr, NapiClashIsRunning, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getProxies", nullptr, NapiClashGetProxies, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"selectProxy", nullptr, NapiClashSelectProxy, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"testDelay", nullptr, NapiClashTestDelay, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getTraffic", nullptr, NapiClashGetTraffic, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getConnections", nullptr, NapiClashGetConnections, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"closeAllConnections", nullptr, NapiClashCloseAllConnections, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"closeConnection", nullptr, NapiClashCloseConnection, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getMode", nullptr, NapiClashGetMode, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setMode", nullptr, NapiClashSetMode, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setTunFd", nullptr, NapiClashSetTunFd, nullptr, nullptr, nullptr, napi_default, nullptr},
    };

    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

static napi_module clashModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "clash",
    .nm_priv = ((void*)0),
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterClashModule(void) {
    napi_module_register(&clashModule);
}
