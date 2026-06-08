export interface AppSettings {
  tunMode: boolean;
  tunStack: string; // system, gvisor, mixed
  dnsMode: string; // fake-ip, redir-host
  routingMode: string; // rule, global, direct
  mixedPort: number;
  allowLan: boolean;
  autoStart: boolean;
  autoConnect: boolean;
  showNotification: boolean;
  theme: string; // system, light, dark
  language: string; // system, zh_CN, en_US
  logLevel: string; // silent, error, warning, info, debug
  tlsClientMode: string; // chrome, rustls
}

export function createDefaultSettings(): AppSettings {
  return {
    tunMode: true,
    tunStack: 'mixed',
    dnsMode: 'fake-ip',
    routingMode: 'rule',
    mixedPort: 7890,
    allowLan: false,
    autoStart: false,
    autoConnect: false,
    showNotification: true,
    theme: 'system',
    language: 'system',
    logLevel: 'info',
    tlsClientMode: 'chrome',
  };
}
