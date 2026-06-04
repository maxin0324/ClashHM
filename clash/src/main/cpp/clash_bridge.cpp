#include "napi/native_api.h"
#include <cstring>
#include <cstdlib>
#include <unistd.h>
#include <signal.h>
#include <sys/wait.h>
#include <string>

static pid_t mihomoPid = -1;

static napi_value returnString(napi_env env, const char* str) {
    napi_value result;
    napi_create_string_utf8(env, str, strlen(str), &result);
    return result;
}

static char* getNapiString(napi_env env, napi_value val) {
    size_t len = 0;
    napi_get_value_string_utf8(env, val, nullptr, 0, &len);
    char* buf = (char*)malloc(len + 1);
    napi_get_value_string_utf8(env, val, buf, len + 1, &len);
    return buf;
}

// startProcess(binaryPath, configDir)
static napi_value NapiStartProcess(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    char* binaryPath = getNapiString(env, args[0]);
    char* configDir = getNapiString(env, args[1]);

    if (mihomoPid > 0) {
        free(binaryPath);
        free(configDir);
        return returnString(env, "already_running");
    }

    // Make binary executable
    chmod(binaryPath, 0755);

    pid_t pid = fork();
    if (pid == 0) {
        // Child process
        std::string dirArg = std::string("-d") + " " + configDir;
        execl(binaryPath, "mihomo", "-d", configDir, (char*)nullptr);
        _exit(127); // exec failed
    } else if (pid > 0) {
        mihomoPid = pid;
        free(binaryPath);
        free(configDir);
        return returnString(env, "started");
    } else {
        free(binaryPath);
        free(configDir);
        return returnString(env, "fork_failed");
    }
}

// stopProcess()
static napi_value NapiStopProcess(napi_env env, napi_callback_info info) {
    if (mihomoPid > 0) {
        kill(mihomoPid, SIGTERM);
        int status;
        waitpid(mihomoPid, &status, WNOHANG);
        mihomoPid = -1;
    }
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// isProcessRunning()
static napi_value NapiIsProcessRunning(napi_env env, napi_callback_info info) {
    napi_value result;
    int running = 0;
    if (mihomoPid > 0) {
        int status;
        pid_t ret = waitpid(mihomoPid, &status, WNOHANG);
        if (ret == 0) {
            running = 1; // still running
        } else {
            mihomoPid = -1; // process ended
        }
    }
    napi_create_int32(env, running, &result);
    return result;
}

static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"startProcess", nullptr, NapiStartProcess, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopProcess", nullptr, NapiStopProcess, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isProcessRunning", nullptr, NapiIsProcessRunning, nullptr, nullptr, nullptr, napi_default, nullptr},
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
