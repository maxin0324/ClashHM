#include "napi/native_api.h"
#include "libmihomo.h"
#include <cstring>
#include <cstdlib>
#include <string>

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
    ClashFreeString(str);
    return result;
}

static char* getNapiString(napi_env env, napi_value val) {
    size_t len = 0;
    napi_get_value_string_utf8(env, val, nullptr, 0, &len);
    char* buf = (char*)malloc(len + 1);
    napi_get_value_string_utf8(env, val, buf, len + 1, &len);
    return buf;
}

static napi_value NapiLoadEngine(napi_env env, napi_callback_info info) {
    return returnString(env, "loaded:linked");
}

static napi_value NapiClashInit(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char* homeDir = getNapiString(env, args[0]);
    char* r = ClashInit(homeDir);
    free(homeDir);
    return returnGoString(env, r);
}

static napi_value NapiClashStartFile(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char* path = getNapiString(env, args[0]);
    char* r = ClashStartFile(path);
    free(path);
    if (r) return returnGoString(env, r);
    return returnString(env, "{\"error\":\"start returned null\"}");
}

static napi_value NapiClashStop(napi_env env, napi_callback_info info) {
    ClashStop();
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

static napi_value NapiClashIsRunning(napi_env env, napi_callback_info info) {
    napi_value result;
    napi_create_int32(env, ClashIsRunning(), &result);
    return result;
}

static napi_value NapiClashGetProxies(napi_env env, napi_callback_info info) {
    char* r = ClashGetProxies();
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
    napi_create_int32(env, ClashSelectProxy(group, proxy), &result);
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
    napi_create_int32(env, ClashTestDelay(name, url, timeout), &result);
    free(name);
    free(url);
    return result;
}

static napi_value NapiClashGetTraffic(napi_env env, napi_callback_info info) {
    char* r = ClashGetTraffic();
    if (r) return returnGoString(env, r);
    return returnString(env, "{\"uploadSpeed\":0,\"downloadSpeed\":0,\"uploadTotal\":0,\"downloadTotal\":0}");
}

static napi_value NapiClashGetConnections(napi_env env, napi_callback_info info) {
    char* r = ClashGetConnections();
    if (r) return returnGoString(env, r);
    return returnString(env, "[]");
}

static napi_value NapiClashCloseAllConnections(napi_env env, napi_callback_info info) {
    ClashCloseAllConnections();
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

static napi_value NapiClashCloseConnection(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char* id = getNapiString(env, args[0]);
    ClashCloseConnection(id);
    free(id);
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

static napi_value NapiClashGetMode(napi_env env, napi_callback_info info) {
    char* r = ClashGetMode();
    if (r) return returnGoString(env, r);
    return returnString(env, "rule");
}

static napi_value NapiClashSetMode(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char* mode = getNapiString(env, args[0]);
    ClashSetMode(mode);
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
    ClashSetTunFd(fd);
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
