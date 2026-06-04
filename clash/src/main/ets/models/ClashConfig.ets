export interface ProxyNode {
  name: string;
  type: string; // ss, vmess, vless, trojan, hysteria2, tuic, etc.
  server: string;
  port: number;
  latency: number; // ms, -1 = untested, 0 = timeout
  alive: boolean;
}

export interface ProxyGroup {
  name: string;
  type: string; // select, url-test, fallback, load-balance
  now: string; // currently selected proxy name
  all: string[]; // all proxy names in this group
  nodes: ProxyNode[];
  expanded: boolean;
}

export interface Rule {
  type: string; // DOMAIN, DOMAIN-SUFFIX, GEOIP, MATCH, etc.
  payload: string;
  proxy: string;
}

export interface DnsConfig {
  enable: boolean;
  listen: string;
  enhancedMode: string; // fake-ip, redir-host
  nameservers: string[];
  fallback: string[];
}

export interface TunConfig {
  enable: boolean;
  stack: string; // system, gvisor, mixed
  dnsHijack: string[];
  autoRoute: boolean;
}

export interface ClashConfig {
  port: number;
  socksPort: number;
  mixedPort: number;
  allowLan: boolean;
  mode: string; // rule, global, direct
  logLevel: string; // silent, error, warning, info, debug
  dns: DnsConfig;
  tun: TunConfig;
  proxies: ProxyNode[];
  proxyGroups: ProxyGroup[];
  rules: Rule[];
}

export enum ConnectionMode {
  RULE = 'rule',
  GLOBAL = 'global',
  DIRECT = 'direct'
}

export enum ConnectState {
  DISCONNECTED = 'disconnected',
  CONNECTING = 'connecting',
  CONNECTED = 'connected'
}
