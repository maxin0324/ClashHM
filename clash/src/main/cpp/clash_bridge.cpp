#include "napi/native_api.h"
#include <cstdlib>
#include <cstring>

extern "C" {
#ifdef CLASHHM_HAS_RUST_NATIVE_CORE
#include "native_core.h"
#else
#include "native_core_compat.h"
#endif
}

static napi_value returnString(napi_env env, const char* str) {
    napi_value result;
    napi_create_string_utf8(env, str ? str : "", NAPI_AUTO_LENGTH, &result);
    return result;
}

static napi_value returnInt(napi_env env, int value) {
    napi_value result;
    napi_create_int32(env, value, &result);
    return result;
}

static char* getNapiString(napi_env env, napi_value val) {
    size_t len = 0;
    napi_get_value_string_utf8(env, val, nullptr, 0, &len);
    char* buf = static_cast<char*>(malloc(len + 1));
    if (!buf) {
        return nullptr;
    }
    napi_get_value_string_utf8(env, val, buf, len + 1, &len);
    return buf;
}

static int getNapiInt(napi_env env, napi_value val) {
    int32_t value = 0;
    napi_get_value_int32(env, val, &value);
    return value;
}

static napi_value returnOwnedNativeCoreString(napi_env env, char* str) {
    if (!str) {
        return returnString(env, "");
    }
    napi_value result = returnString(env, str);
    clashhm_native_core_free_string(str);
    return result;
}

static napi_value NapiNativeCoreInit(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        return returnInt(env, -1);
    }

    char* homeDir = getNapiString(env, args[0]);
    if (!homeDir) {
        return returnInt(env, -2);
    }
    int ret = clashhm_native_core_init(homeDir);
    free(homeDir);
    return returnInt(env, ret);
}

static napi_value NapiNativeCoreStartTun(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
        return returnInt(env, -1);
    }

    int tunFd = getNapiInt(env, args[0]);
    char* configText = getNapiString(env, args[1]);
    if (!configText) {
        return returnInt(env, -2);
    }
    int ret = clashhm_native_core_start_tun(tunFd, configText);
    free(configText);
    return returnInt(env, ret);
}

static napi_value NapiNativeCoreStop(napi_env env, napi_callback_info) {
    return returnInt(env, clashhm_native_core_stop());
}

static napi_value NapiNativeCoreIsRunning(napi_env env, napi_callback_info) {
    return returnInt(env, clashhm_native_core_is_running());
}

static napi_value NapiNativeCoreGetProxies(napi_env env, napi_callback_info) {
    return returnOwnedNativeCoreString(env, clashhm_native_core_get_proxies_json());
}

static napi_value NapiNativeCoreLoadConfig(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        return returnInt(env, -1);
    }

    char* configText = getNapiString(env, args[0]);
    if (!configText) {
        return returnInt(env, -2);
    }
    int ret = clashhm_native_core_load_config(configText);
    free(configText);
    return returnInt(env, ret);
}

static napi_value NapiNativeCoreParseProxies(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        return returnString(env, "[]");
    }

    char* configText = getNapiString(env, args[0]);
    if (!configText) {
        return returnString(env, "[]");
    }
    napi_value result = returnOwnedNativeCoreString(env, clashhm_native_core_parse_proxies_json(configText));
    free(configText);
    return result;
}

static napi_value NapiNativeCoreSelectProxy(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
        return returnInt(env, -1);
    }

    char* groupName = getNapiString(env, args[0]);
    char* proxyName = getNapiString(env, args[1]);
    if (!groupName || !proxyName) {
        free(groupName);
        free(proxyName);
        return returnInt(env, -2);
    }
    int ret = clashhm_native_core_select_proxy(groupName, proxyName);
    free(groupName);
    free(proxyName);
    return returnInt(env, ret);
}

static napi_value NapiNativeCoreSetMode(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        return returnInt(env, -1);
    }

    char* mode = getNapiString(env, args[0]);
    if (!mode) {
        return returnInt(env, -2);
    }
    int ret = clashhm_native_core_set_mode(mode);
    free(mode);
    return returnInt(env, ret);
}

static napi_value NapiNativeCoreTestDelay(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 3) {
        return returnInt(env, -1);
    }

    char* proxyName = getNapiString(env, args[0]);
    char* url = getNapiString(env, args[1]);
    int timeoutMs = getNapiInt(env, args[2]);
    if (!proxyName || !url) {
        free(proxyName);
        free(url);
        return returnInt(env, -2);
    }
    int ret = clashhm_native_core_test_delay(proxyName, url, timeoutMs);
    free(proxyName);
    free(url);
    return returnInt(env, ret);
}

static napi_value NapiNativeCoreGetTraffic(napi_env env, napi_callback_info) {
    return returnOwnedNativeCoreString(env, clashhm_native_core_get_traffic_json());
}

static napi_value NapiNativeCoreGetConnections(napi_env env, napi_callback_info) {
    return returnOwnedNativeCoreString(env, clashhm_native_core_get_connections_json());
}

static napi_value NapiNativeCoreGetStatus(napi_env env, napi_callback_info) {
    return returnOwnedNativeCoreString(env, clashhm_native_core_get_status_json());
}

static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"nativeCoreInit", nullptr, NapiNativeCoreInit, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"nativeCoreStartTun", nullptr, NapiNativeCoreStartTun, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"nativeCoreStop", nullptr, NapiNativeCoreStop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"nativeCoreIsRunning", nullptr, NapiNativeCoreIsRunning, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"nativeCoreGetProxies", nullptr, NapiNativeCoreGetProxies, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"nativeCoreLoadConfig", nullptr, NapiNativeCoreLoadConfig, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"nativeCoreParseProxies", nullptr, NapiNativeCoreParseProxies, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"nativeCoreSelectProxy", nullptr, NapiNativeCoreSelectProxy, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"nativeCoreSetMode", nullptr, NapiNativeCoreSetMode, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"nativeCoreTestDelay", nullptr, NapiNativeCoreTestDelay, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"nativeCoreGetTraffic", nullptr, NapiNativeCoreGetTraffic, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"nativeCoreGetConnections", nullptr, NapiNativeCoreGetConnections, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"nativeCoreGetStatus", nullptr, NapiNativeCoreGetStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);

    napi_value defaultExport;
    napi_create_object(env, &defaultExport);
    napi_define_properties(env, defaultExport, sizeof(desc) / sizeof(desc[0]), desc);
    napi_set_named_property(env, exports, "default", defaultExport);

    return exports;
}

static napi_module clashModule = {
    NAPI_MODULE_VERSION,
    0,
    nullptr,
    Init,
    "clash",
    nullptr,
    {nullptr},
};

static napi_module libClashModule = {
    NAPI_MODULE_VERSION,
    0,
    nullptr,
    Init,
    "libclash",
    nullptr,
    {nullptr},
};

static napi_module libClashSoModule = {
    NAPI_MODULE_VERSION,
    0,
    nullptr,
    Init,
    "libclash.so",
    nullptr,
    {nullptr},
};

extern "C" __attribute__((constructor)) void RegisterClashModule() {
    napi_module_register(&clashModule);
    napi_module_register(&libClashModule);
    napi_module_register(&libClashSoModule);
}
