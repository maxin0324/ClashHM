#include <cstdarg>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>

extern "C" {

int __isoc23_sscanf(const char* str, const char* format, ...) {
    va_list args;
    va_start(args, format);
    int ret = vsscanf(str, format, args);
    va_end(args);
    return ret;
}

long __isoc23_strtol(const char* nptr, char** endptr, int base) {
    return strtol(nptr, endptr, base);
}

typedef void (*SignalHandler)(int);

SignalHandler __sysv_signal(int signum, SignalHandler handler) {
    return signal(signum, handler);
}

int OH_TimeService_GetTimeZone(char* timeZone, unsigned int len) {
    if (timeZone == nullptr || len == 0) {
        return 13000002;
    }
    const char* defaultTimeZone = "Asia/Shanghai";
    size_t copyLen = strlen(defaultTimeZone);
    if (copyLen >= len) {
        copyLen = len - 1;
    }
    memcpy(timeZone, defaultTimeZone, copyLen);
    timeZone[copyLen] = '\0';
    return 0;
}

}
