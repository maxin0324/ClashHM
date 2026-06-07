#ifndef CLASHHM_NATIVE_CORE_COMPAT_H
#define CLASHHM_NATIVE_CORE_COMPAT_H

#ifdef __cplusplus
extern "C" {
#endif

int clashhm_native_core_init(const char* home_dir);
int clashhm_native_core_start_tun(int tun_fd, const char* clash_config);
int clashhm_native_core_stop(void);
int clashhm_native_core_is_running(void);
char* clashhm_native_core_get_proxies_json(void);
char* clashhm_native_core_parse_proxies_json(const char* clash_config);
int clashhm_native_core_select_proxy(const char* group_name, const char* proxy_name);
int clashhm_native_core_test_delay(const char* proxy_name, const char* url, int timeout_ms);
char* clashhm_native_core_get_traffic_json(void);
char* clashhm_native_core_get_connections_json(void);
char* clashhm_native_core_get_status_json(void);
void clashhm_native_core_free_string(char* value);

#ifdef __cplusplus
}
#endif

#endif
