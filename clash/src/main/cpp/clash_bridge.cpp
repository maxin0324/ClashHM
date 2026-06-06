#include "napi/native_api.h"
#include <cstring>
#include <cstdlib>
#include <unistd.h>
#include <errno.h>
#include <dlfcn.h>
#include <pthread.h>
#include <algorithm>
#include <cctype>
#include <map>
#include <string>
#include <vector>
#include <sstream>

extern "C" {
#include "hev-main.h"
}

struct MihomoEngine {
    void* handle = nullptr;
    char* (*ClashInit)(char*) = nullptr;
    char* (*ClashStartFile)(char*) = nullptr;
    char* (*ClashStartContent)(char*) = nullptr;
    void (*ClashStop)() = nullptr;
    int (*ClashIsRunning)() = nullptr;
    char* (*ClashGetProxies)() = nullptr;
    int (*ClashSelectProxy)(char*, char*) = nullptr;
    int (*ClashTestDelay)(char*, char*, int) = nullptr;
    char* (*ClashGetTraffic)() = nullptr;
    char* (*ClashGetConnections)() = nullptr;
    void (*ClashCloseAllConnections)() = nullptr;
    void (*ClashCloseConnection)(char*) = nullptr;
    char* (*ClashGetMode)() = nullptr;
    void (*ClashSetMode)(char*) = nullptr;
    void (*ClashSetTunFd)(int) = nullptr;
    void (*ClashFreeString)(char*) = nullptr;
};

static MihomoEngine engine;
static bool engineReady = false;
static pthread_mutex_t tun2socksMutex = PTHREAD_MUTEX_INITIALIZER;
static bool tun2socksRunning = false;
static std::string tun2socksStatus = "not_started";
static std::string tun2socksConfig;
static int tun2socksFd = -1;

static napi_value NapiLoadEngine(napi_env env, napi_callback_info info);

static napi_value returnString(napi_env env, const char* str) {
    napi_value result;
    napi_create_string_utf8(env, str, strlen(str), &result);
    return result;
}

static napi_value returnInt(napi_env env, int value) {
    napi_value result;
    napi_create_int32(env, value, &result);
    return result;
}

static napi_value returnUndefined(napi_env env) {
    napi_value undef;
    napi_get_undefined(env, &undef);
    return undef;
}

static char* getNapiString(napi_env env, napi_value val) {
    size_t len = 0;
    napi_get_value_string_utf8(env, val, nullptr, 0, &len);
    char* buf = static_cast<char*>(malloc(len + 1));
    napi_get_value_string_utf8(env, val, buf, len + 1, &len);
    return buf;
}

static int getNapiInt(napi_env env, napi_value val) {
    int32_t value = 0;
    napi_get_value_int32(env, val, &value);
    return value;
}

static napi_value returnOwnedGoString(napi_env env, char* str) {
    if (!str) {
        return returnString(env, "");
    }
    napi_value result = returnString(env, str);
    free(str);
    return result;
}

static bool engineLoaded() {
    return engineReady;
}

template <typename T>
static bool loadSym(void* handle, const char* name, T& target, std::string& missing) {
    target = reinterpret_cast<T>(dlsym(handle, name));
    if (!target) {
        missing = name;
        return false;
    }
    return true;
}

static bool loadEngineSymbols(void* handle, std::string& missing) {
    return
        loadSym(handle, "ClashInit", engine.ClashInit, missing) &&
        loadSym(handle, "ClashStartFile", engine.ClashStartFile, missing) &&
        loadSym(handle, "ClashStartContent", engine.ClashStartContent, missing) &&
        loadSym(handle, "ClashStop", engine.ClashStop, missing) &&
        loadSym(handle, "ClashIsRunning", engine.ClashIsRunning, missing) &&
        loadSym(handle, "ClashGetProxies", engine.ClashGetProxies, missing) &&
        loadSym(handle, "ClashSelectProxy", engine.ClashSelectProxy, missing) &&
        loadSym(handle, "ClashTestDelay", engine.ClashTestDelay, missing) &&
        loadSym(handle, "ClashGetTraffic", engine.ClashGetTraffic, missing) &&
        loadSym(handle, "ClashGetConnections", engine.ClashGetConnections, missing) &&
        loadSym(handle, "ClashCloseAllConnections", engine.ClashCloseAllConnections, missing) &&
        loadSym(handle, "ClashCloseConnection", engine.ClashCloseConnection, missing) &&
        loadSym(handle, "ClashGetMode", engine.ClashGetMode, missing) &&
        loadSym(handle, "ClashSetMode", engine.ClashSetMode, missing) &&
        loadSym(handle, "ClashSetTunFd", engine.ClashSetTunFd, missing) &&
        loadSym(handle, "ClashFreeString", engine.ClashFreeString, missing);
}

static std::string getCurrentLibraryDir() {
    Dl_info info;
    if (dladdr(reinterpret_cast<void*>(&NapiLoadEngine), &info) == 0 || !info.dli_fname) {
        return "";
    }
    std::string path(info.dli_fname);
    size_t slash = path.rfind('/');
    if (slash == std::string::npos) {
        return "";
    }
    return path.substr(0, slash);
}

static void* tryDlopen(const std::string& path, std::string& error) {
    dlerror();
    void* handle = dlopen(path.c_str(), RTLD_NOW | RTLD_GLOBAL);
    if (handle) return handle;
    const char* first = dlerror();
    error = first ? first : "unknown";

    dlerror();
    handle = dlopen(path.c_str(), RTLD_LAZY | RTLD_GLOBAL);
    if (handle) return handle;
    const char* second = dlerror();
    if (second) error = second;

    dlerror();
    handle = dlopen(path.c_str(), RTLD_LAZY);
    if (handle) return handle;
    const char* third = dlerror();
    if (third) error = third;
    return nullptr;
}

static std::vector<std::string> makeCandidates(const std::string& base) {
    std::vector<std::string> candidates;
    auto addCandidate = [&candidates](const std::string& path) {
        if (path.empty()) return;
        for (const std::string& existing : candidates) {
            if (existing == path) return;
        }
        candidates.push_back(path);
    };

    if (!base.empty()) {
        if (base.size() >= 3 && base.rfind(".so") == base.size() - 3) {
            addCandidate(base);
        } else {
            addCandidate(base + "/libmihomo.so");
        }
    }

    std::string currentDir = getCurrentLibraryDir();
    if (!currentDir.empty()) {
        addCandidate(currentDir + "/libmihomo.so");
        if (currentDir.find("/libs/arm64") == std::string::npos &&
            currentDir.find("/libs/arm64-v8a") == std::string::npos) {
            addCandidate(currentDir + "/arm64-v8a/libmihomo.so");
            addCandidate(currentDir + "/arm64/libmihomo.so");
        }
    }

    addCandidate("libmihomo.so");
    addCandidate("/data/storage/el1/bundle/libs/arm64/libmihomo.so");
    addCandidate("/data/storage/el1/bundle/libs/arm64-v8a/libmihomo.so");
    return candidates;
}

struct Socks5ProxyConfig {
    std::string address;
    std::string port;
    std::string username;
    std::string password;
};

static std::string trim(const std::string& value) {
    size_t begin = 0;
    while (begin < value.size() && std::isspace(static_cast<unsigned char>(value[begin]))) {
        begin++;
    }
    size_t end = value.size();
    while (end > begin && std::isspace(static_cast<unsigned char>(value[end - 1]))) {
        end--;
    }
    return value.substr(begin, end - begin);
}

static std::string lowerAscii(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    return value;
}

static std::string unquote(std::string value) {
    value = trim(value);
    if (value.size() >= 2) {
        char first = value[0];
        char last = value[value.size() - 1];
        if ((first == '\'' && last == '\'') || (first == '"' && last == '"')) {
            return value.substr(1, value.size() - 2);
        }
    }
    return value;
}

static bool parseKeyValue(const std::string& text, std::string& key, std::string& value) {
    size_t colon = text.find(':');
    if (colon == std::string::npos) {
        return false;
    }
    key = lowerAscii(unquote(trim(text.substr(0, colon))));
    value = unquote(trim(text.substr(colon + 1)));
    return !key.empty();
}

static void putProxyValue(std::map<std::string, std::string>& values, const std::string& key, const std::string& value) {
    if (key == "type" || key == "server" || key == "address" || key == "port" ||
        key == "username" || key == "user" || key == "password" || key == "pass") {
        values[key] = value;
    }
}

static bool isSocks5Proxy(const std::map<std::string, std::string>& values) {
    auto type = values.find("type");
    if (type == values.end()) {
        return false;
    }
    std::string proxyType = lowerAscii(type->second);
    return proxyType == "socks" || proxyType == "socks5";
}

static bool finishProxy(const std::map<std::string, std::string>& values, Socks5ProxyConfig& out) {
    if (!isSocks5Proxy(values)) {
        return false;
    }
    auto server = values.find("server");
    if (server == values.end()) {
        server = values.find("address");
    }
    auto port = values.find("port");
    if (server == values.end() || port == values.end() || server->second.empty() || port->second.empty()) {
        return false;
    }
    out.address = server->second;
    out.port = port->second;
    auto username = values.find("username");
    if (username == values.end()) {
        username = values.find("user");
    }
    auto password = values.find("password");
    if (password == values.end()) {
        password = values.find("pass");
    }
    if (username != values.end()) {
        out.username = username->second;
    }
    if (password != values.end()) {
        out.password = password->second;
    }
    return true;
}

static void parseInlineMap(const std::string& line, std::map<std::string, std::string>& values) {
    size_t begin = line.find('{');
    size_t end = line.rfind('}');
    if (begin == std::string::npos || end == std::string::npos || end <= begin) {
        return;
    }
    std::string body = line.substr(begin + 1, end - begin - 1);
    size_t start = 0;
    while (start <= body.size()) {
        size_t comma = body.find(',', start);
        std::string part = body.substr(start, comma == std::string::npos ? std::string::npos : comma - start);
        std::string key;
        std::string value;
        if (parseKeyValue(part, key, value)) {
            putProxyValue(values, key, value);
        }
        if (comma == std::string::npos) {
            break;
        }
        start = comma + 1;
    }
}

static bool parseFirstSocks5Proxy(const std::string& configText, Socks5ProxyConfig& out) {
    std::istringstream input(configText);
    std::string line;
    bool inProxies = false;
    bool inItem = false;
    std::map<std::string, std::string> values;

    while (std::getline(input, line)) {
        std::string text = trim(line);
        if (text.empty() || text[0] == '#') {
            continue;
        }
        if (text == "proxies:") {
            inProxies = true;
            continue;
        }
        if (inProxies && line.size() > 0 && !std::isspace(static_cast<unsigned char>(line[0])) && text[0] != '-') {
            if (finishProxy(values, out)) {
                return true;
            }
            break;
        }
        if (!inProxies) {
            continue;
        }
        if (text.rfind("- ", 0) == 0) {
            if (finishProxy(values, out)) {
                return true;
            }
            values.clear();
            inItem = true;
            if (text.find('{') != std::string::npos) {
                parseInlineMap(text, values);
                if (finishProxy(values, out)) {
                    return true;
                }
            } else {
                std::string rest = trim(text.substr(2));
                std::string key;
                std::string value;
                if (parseKeyValue(rest, key, value)) {
                    putProxyValue(values, key, value);
                }
            }
            continue;
        }
        if (inItem) {
            std::string key;
            std::string value;
            if (parseKeyValue(text, key, value)) {
                putProxyValue(values, key, value);
            }
        }
    }
    return finishProxy(values, out);
}

static std::string yamlQuote(const std::string& value) {
    std::string result = "'";
    for (char ch : value) {
        if (ch == '\'') {
            result += "''";
        } else {
            result += ch;
        }
    }
    result += "'";
    return result;
}

static bool makeHevConfig(const std::string& inputConfig, std::string& outputConfig, std::string& summary) {
    bool hasTunnel = inputConfig.rfind("tunnel:", 0) == 0 || inputConfig.find("\ntunnel:") != std::string::npos;
    bool hasSocks5 = inputConfig.rfind("socks5:", 0) == 0 || inputConfig.find("\nsocks5:") != std::string::npos;
    if (hasTunnel && hasSocks5) {
        outputConfig = inputConfig;
        summary = "hev_config";
        return true;
    }

    Socks5ProxyConfig proxy;
    if (!parseFirstSocks5Proxy(inputConfig, proxy)) {
        summary = "no socks5 proxy found in Clash config";
        return false;
    }

    std::ostringstream out;
    out << "tunnel:\n"
        << "  name: vpn-tun\n"
        << "  mtu: 1400\n"
        << "  multi-queue: false\n"
        << "  ipv4: 10.249.0.1\n"
        << "\n"
        << "socks5:\n"
        << "  address: " << yamlQuote(proxy.address) << "\n"
        << "  port: " << proxy.port << "\n"
        << "  udp: 'udp'\n";
    if (!proxy.username.empty()) {
        out << "  username: " << yamlQuote(proxy.username) << "\n";
    }
    if (!proxy.password.empty()) {
        out << "  password: " << yamlQuote(proxy.password) << "\n";
    }
    out << "\n"
        << "misc:\n"
        << "  task-stack-size: 24576\n"
        << "  tcp-buffer-size: 4096\n"
        << "  connect-timeout: 10000\n"
        << "  tcp-read-write-timeout: 300000\n"
        << "  udp-read-write-timeout: 60000\n"
        << "  log-level: warn\n";
    outputConfig = out.str();
    summary = proxy.address + ":" + proxy.port;
    return true;
}

static void setTun2SocksStatus(const std::string& status) {
    pthread_mutex_lock(&tun2socksMutex);
    tun2socksStatus = status;
    pthread_mutex_unlock(&tun2socksMutex);
}

static void* tun2socksThreadMain(void*) {
    std::string config;
    int fd;
    pthread_mutex_lock(&tun2socksMutex);
    config = tun2socksConfig;
    fd = tun2socksFd;
    pthread_mutex_unlock(&tun2socksMutex);

    int result = hev_socks5_tunnel_main_from_str(reinterpret_cast<const unsigned char*>(config.c_str()),
                                                 static_cast<unsigned int>(config.size()), fd);

    pthread_mutex_lock(&tun2socksMutex);
    tun2socksRunning = false;
    tun2socksStatus = std::string("exited:") + std::to_string(result);
    pthread_mutex_unlock(&tun2socksMutex);
    return nullptr;
}

static napi_value NapiLoadEngine(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (engineLoaded()) {
        return returnString(env, "loaded:already");
    }

    std::string linkedMissing;
    if (loadEngineSymbols(RTLD_DEFAULT, linkedMissing)) {
        engine.handle = RTLD_DEFAULT;
        engineReady = true;
        return returnString(env, "loaded:linked");
    }

    char* input = nullptr;
    std::string base;
    if (argc > 0) {
        input = getNapiString(env, args[0]);
        base = input;
        free(input);
    }

    std::ostringstream failures;
    for (const std::string& path : makeCandidates(base)) {
        bool exists = access(path.c_str(), F_OK) == 0;
        std::string openError;
        void* handle = tryDlopen(path, openError);
        if (!handle) {
            if (failures.tellp() > 0) {
                failures << " | ";
            }
            failures << path << "(exists=" << (exists ? "true" : "false") << "):" << openError;
            continue;
        }

        std::string missing;
        if (!loadEngineSymbols(handle, missing)) {
            dlclose(handle);
            return returnString(env, (std::string("failed:missing_symbol:") + missing + " at " + path).c_str());
        }

        engine.handle = handle;
        engineReady = true;
        return returnString(env, (std::string("loaded:") + path).c_str());
    }

    return returnString(env, (std::string("failed:") + failures.str()).c_str());
}

static napi_value NapiInit(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (!engineLoaded()) return returnString(env, "{\"error\":\"engine not loaded\"}");

    char* dir = getNapiString(env, args[0]);
    char* result = engine.ClashInit(dir);
    free(dir);
    return returnOwnedGoString(env, result);
}

static napi_value NapiStartFile(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (!engineLoaded()) return returnString(env, "{\"error\":\"engine not loaded\"}");

    char* path = getNapiString(env, args[0]);
    char* result = engine.ClashStartFile(path);
    free(path);
    return returnOwnedGoString(env, result);
}

static napi_value NapiStartContent(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (!engineLoaded()) return returnString(env, "{\"error\":\"engine not loaded\"}");

    char* content = getNapiString(env, args[0]);
    char* result = engine.ClashStartContent(content);
    free(content);
    return returnOwnedGoString(env, result);
}

static napi_value NapiStop(napi_env env, napi_callback_info) {
    if (engineLoaded()) engine.ClashStop();
    return returnUndefined(env);
}

static napi_value NapiIsRunning(napi_env env, napi_callback_info) {
    return returnInt(env, engineLoaded() ? engine.ClashIsRunning() : 0);
}

static napi_value NapiGetProxies(napi_env env, napi_callback_info) {
    if (!engineLoaded()) return returnString(env, "[]");
    return returnOwnedGoString(env, engine.ClashGetProxies());
}

static napi_value NapiSelectProxy(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (!engineLoaded()) return returnInt(env, -99);

    char* group = getNapiString(env, args[0]);
    char* proxy = getNapiString(env, args[1]);
    int ret = engine.ClashSelectProxy(group, proxy);
    free(group);
    free(proxy);
    return returnInt(env, ret);
}

static napi_value NapiTestDelay(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (!engineLoaded()) return returnInt(env, 0);

    char* name = getNapiString(env, args[0]);
    char* url = getNapiString(env, args[1]);
    int timeout = getNapiInt(env, args[2]);
    int ret = engine.ClashTestDelay(name, url, timeout);
    free(name);
    free(url);
    return returnInt(env, ret);
}

static napi_value NapiGetTraffic(napi_env env, napi_callback_info) {
    if (!engineLoaded()) return returnString(env, "{}");
    return returnOwnedGoString(env, engine.ClashGetTraffic());
}

static napi_value NapiGetConnections(napi_env env, napi_callback_info) {
    if (!engineLoaded()) return returnString(env, "[]");
    return returnOwnedGoString(env, engine.ClashGetConnections());
}

static napi_value NapiCloseAllConnections(napi_env env, napi_callback_info) {
    if (engineLoaded()) engine.ClashCloseAllConnections();
    return returnUndefined(env);
}

static napi_value NapiCloseConnection(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (engineLoaded()) {
        char* id = getNapiString(env, args[0]);
        engine.ClashCloseConnection(id);
        free(id);
    }
    return returnUndefined(env);
}

static napi_value NapiGetMode(napi_env env, napi_callback_info) {
    if (!engineLoaded()) return returnString(env, "rule");
    return returnOwnedGoString(env, engine.ClashGetMode());
}

static napi_value NapiSetMode(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (engineLoaded()) {
        char* mode = getNapiString(env, args[0]);
        engine.ClashSetMode(mode);
        free(mode);
    }
    return returnUndefined(env);
}

static napi_value NapiSetTunFd(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (engineLoaded()) {
        engine.ClashSetTunFd(getNapiInt(env, args[0]));
    }
    return returnUndefined(env);
}

static napi_value NapiStartTun2SocksContent(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
        return returnString(env, "invalid_args");
    }

    char* configRaw = getNapiString(env, args[0]);
    int tunFd = getNapiInt(env, args[1]);
    std::string inputConfig(configRaw);
    free(configRaw);

    if (inputConfig.empty() || tunFd <= 0) {
        return returnString(env, "invalid_args");
    }

    pthread_mutex_lock(&tun2socksMutex);
    bool alreadyRunning = tun2socksRunning;
    pthread_mutex_unlock(&tun2socksMutex);
    if (alreadyRunning) {
        return returnString(env, "already_running");
    }

    std::string hevConfig;
    std::string summary;
    if (!makeHevConfig(inputConfig, hevConfig, summary)) {
        std::string status = "config_error:" + summary;
        setTun2SocksStatus(status);
        return returnString(env, status.c_str());
    }

    pthread_mutex_lock(&tun2socksMutex);
    tun2socksConfig = hevConfig;
    tun2socksFd = tunFd;
    tun2socksRunning = true;
    tun2socksStatus = "starting:" + summary;
    pthread_mutex_unlock(&tun2socksMutex);

    pthread_t thread;
    int ret = pthread_create(&thread, nullptr, tun2socksThreadMain, nullptr);
    if (ret != 0) {
        pthread_mutex_lock(&tun2socksMutex);
        tun2socksRunning = false;
        tun2socksStatus = std::string("thread_create_failed:") + strerror(ret);
        std::string status = tun2socksStatus;
        pthread_mutex_unlock(&tun2socksMutex);
        return returnString(env, status.c_str());
    }
    pthread_detach(thread);

    std::string result = "started:upstream=" + summary + ",configLen=" + std::to_string(hevConfig.size());
    setTun2SocksStatus(result);
    return returnString(env, result.c_str());
}

static napi_value NapiStopTun2Socks(napi_env env, napi_callback_info) {
    pthread_mutex_lock(&tun2socksMutex);
    bool wasRunning = tun2socksRunning;
    pthread_mutex_unlock(&tun2socksMutex);
    if (wasRunning) {
        hev_socks5_tunnel_quit();
        setTun2SocksStatus("stop_requested");
    }
    return returnUndefined(env);
}

static napi_value NapiGetTun2SocksStatus(napi_env env, napi_callback_info) {
    pthread_mutex_lock(&tun2socksMutex);
    std::string status = tun2socksStatus;
    pthread_mutex_unlock(&tun2socksMutex);
    return returnString(env, status.c_str());
}

static napi_value NapiTestDlopen(napi_env env, napi_callback_info info) {
    if (engineLoaded()) {
        return returnString(env, "linked=static;ClashInit=found");
    }

    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char* path = getNapiString(env, args[0]);

    bool exists = access(path, F_OK) == 0;
    std::string error;
    void* handle = tryDlopen(path, error);
    std::string result = std::string("exists=") + (exists ? "true" : "false") + ";";
    if (handle) {
        result += dlsym(handle, "ClashInit") ? "dlopen=ok;ClashInit=found" : "dlopen=ok;ClashInit=missing";
        dlclose(handle);
    } else {
        result += "dlopen=failed;" + error;
    }

    free(path);
    return returnString(env, result.c_str());
}

static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"loadEngine", nullptr, NapiLoadEngine, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"init", nullptr, NapiInit, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startFile", nullptr, NapiStartFile, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startContent", nullptr, NapiStartContent, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stop", nullptr, NapiStop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isRunning", nullptr, NapiIsRunning, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getProxies", nullptr, NapiGetProxies, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"selectProxy", nullptr, NapiSelectProxy, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"testDelay", nullptr, NapiTestDelay, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getTraffic", nullptr, NapiGetTraffic, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getConnections", nullptr, NapiGetConnections, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"closeConnection", nullptr, NapiCloseConnection, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"closeAllConnections", nullptr, NapiCloseAllConnections, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getMode", nullptr, NapiGetMode, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setMode", nullptr, NapiSetMode, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setTunFd", nullptr, NapiSetTunFd, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startTun2SocksContent", nullptr, NapiStartTun2SocksContent, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopTun2Socks", nullptr, NapiStopTun2Socks, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getTun2SocksStatus", nullptr, NapiGetTun2SocksStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"testDlopen", nullptr, NapiTestDlopen, nullptr, nullptr, nullptr, napi_default, nullptr},
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

extern "C" __attribute__((constructor)) void RegisterClashModule(void) {
    napi_module_register(&clashModule);
    napi_module_register(&libClashModule);
    napi_module_register(&libClashSoModule);
}

NAPI_MODULE_INIT() {
    return Init(env, exports);
}
