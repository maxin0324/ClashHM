import { fileIo } from '@kit.CoreFileKit';
import { ClashConfig } from '../models/ClashConfig';
import { Constants } from '../common/Constants';
import { Logger } from '../common/Logger';
import { common } from '@kit.AbilityKit';

export class ConfigManager {
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  getConfigDir(): string {
    return `${this.context.filesDir}/${Constants.CONFIG_DIR}`;
  }

  readConfigFile(filePath: string): string {
    try {
      const file = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(filePath);
      const buf = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buf);
      fileIo.closeSync(file);
      const decoder = new TextDecoder('utf-8');
      return decoder.decode(new Uint8Array(buf));
    } catch (e) {
      Logger.error('Failed to read config: %{public}s', String(e));
      return '';
    }
  }

  writeConfigFile(filePath: string, content: string): void {
    try {
      const dir = filePath.substring(0, filePath.lastIndexOf('/'));
      try {
        fileIo.mkdirSync(dir, true);
      } catch (_e) {
        // directory exists
      }
      const file = fileIo.openSync(filePath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, content);
      fileIo.closeSync(file);
    } catch (e) {
      Logger.error('Failed to write config: %{public}s', String(e));
    }
  }

  configExists(filePath: string): boolean {
    try {
      return fileIo.accessSync(filePath);
    } catch (_e) {
      return false;
    }
  }

  generateMergedConfig(subscriptionPath: string): string {
    let content = this.readConfigFile(subscriptionPath);
    if (!content) {
      return this.getDefaultConfig();
    }
    return this.ensureRequiredFields(content);
  }

  private ensureRequiredFields(content: string): string {
    const lines = content.split('\n');
    const fields: Map<string, string> = new Map();
    for (const line of lines) {
      const idx = line.indexOf(':');
      if (idx > 0 && !line.startsWith(' ') && !line.startsWith('-') && !line.startsWith('#')) {
        fields.set(line.substring(0, idx).trim(), line.substring(idx + 1).trim());
      }
    }

    const additions: string[] = [];
    if (!fields.has('mixed-port')) {
      additions.push(`mixed-port: ${Constants.DEFAULT_MIXED_PORT}`);
    }
    if (!fields.has('allow-lan')) {
      additions.push('allow-lan: false');
    }
    if (!fields.has('mode')) {
      additions.push('mode: rule');
    }
    if (!fields.has('log-level')) {
      additions.push('log-level: info');
    }
    if (!fields.has('external-controller')) {
      additions.push(`external-controller: 127.0.0.1:${Constants.CLASH_API_PORT}`);
    }

    if (additions.length > 0) {
      return additions.join('\n') + '\n' + content;
    }
    return content;
  }

  getDefaultConfig(): string {
    return `mixed-port: ${Constants.DEFAULT_MIXED_PORT}
allow-lan: false
mode: rule
log-level: info
external-controller: 127.0.0.1:${Constants.CLASH_API_PORT}

dns:
  enable: true
  listen: 0.0.0.0:1053
  enhanced-mode: fake-ip
  nameserver:
    - 223.5.5.5
    - 119.29.29.29
  fallback:
    - 8.8.8.8
    - 1.1.1.1

tun:
  enable: true
  stack: mixed
  auto-route: true
  dns-hijack:
    - any:53

proxies: []

proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - DIRECT

rules:
  - MATCH,DIRECT
`;
  }

  parseBasicConfig(content: string): Partial<ClashConfig> {
    const config: Partial<ClashConfig> = {};
    const lines = content.split('\n');
    for (const line of lines) {
      const trimmed = line.trim();
      if (trimmed.startsWith('mixed-port:')) {
        config.mixedPort = parseInt(trimmed.split(':')[1]?.trim() || '7890');
      } else if (trimmed.startsWith('mode:')) {
        config.mode = trimmed.split(':')[1]?.trim() || 'rule';
      } else if (trimmed.startsWith('log-level:')) {
        config.logLevel = trimmed.split(':')[1]?.trim() || 'info';
      } else if (trimmed === 'allow-lan: true') {
        config.allowLan = true;
      } else if (trimmed === 'allow-lan: false') {
        config.allowLan = false;
      }
    }
    return config;
  }
}
