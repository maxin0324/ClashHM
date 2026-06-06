import { fileIo } from '@kit.CoreFileKit';
import { ClashConfig, ProxyGroup, ProxyNode } from '../models/ClashConfig';
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
      const view = new Uint8Array(buf);
      const bytes: number[] = [];
      for (let i = 0; i < view.length; i++) {
        bytes.push(view[i]);
      }
      return this.decodeUtf8(bytes);
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

  parseProxyGroupsFromFile(filePath: string): ProxyGroup[] {
    const content = this.readConfigFile(filePath);
    if (!content) {
      return [];
    }
    return this.parseProxyGroupsFromContent(content);
  }

  parseProxyGroupsFromContent(content: string): ProxyGroup[] {
    const nodesByName: Map<string, ProxyNode> = new Map();
    const groups: ProxyGroup[] = [];
    const lines = content.split('\n');
    let section = '';
    let currentNode: ProxyNode | null = null;
    let currentGroup: ProxyGroup | null = null;
    let readingGroupProxies = false;

    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#')) {
        continue;
      }

      const topLevel = this.isTopLevel(line);
      if (topLevel) {
        if (currentNode) {
          nodesByName.set(currentNode.name, currentNode);
          currentNode = null;
        }
        if (currentGroup) {
          groups.push(currentGroup);
          currentGroup = null;
        }
        readingGroupProxies = false;
        if (trimmed === 'proxies:') {
          section = 'proxies';
        } else if (trimmed === 'proxy-groups:') {
          section = 'proxy-groups';
        } else {
          section = '';
        }
        continue;
      }

      if (section === 'proxies') {
        if (trimmed.startsWith('- {')) {
          const name = this.parseFlowValue(trimmed, 'name');
          if (name) {
            const node = this.createProxyNode(name, this.parseFlowValue(trimmed, 'type'));
            node.server = this.parseFlowValue(trimmed, 'server');
            node.port = this.parseNumber(this.parseFlowValue(trimmed, 'port'));
            nodesByName.set(node.name, node);
          }
          currentNode = null;
        } else if (trimmed.startsWith('- name:')) {
          if (currentNode) {
            nodesByName.set(currentNode.name, currentNode);
          }
          currentNode = this.createProxyNode(this.stripQuotes(trimmed.substring(7).trim()), '');
        } else if (currentNode) {
          if (trimmed.startsWith('type:')) {
            currentNode.type = this.stripQuotes(trimmed.substring(5).trim());
          } else if (trimmed.startsWith('server:')) {
            currentNode.server = this.stripQuotes(trimmed.substring(7).trim());
          } else if (trimmed.startsWith('port:')) {
            currentNode.port = this.parseNumber(trimmed.substring(5).trim());
          }
        }
      } else if (section === 'proxy-groups') {
        if (trimmed.startsWith('- {')) {
          if (currentGroup) {
            groups.push(currentGroup);
          }
          const name = this.parseFlowValue(trimmed, 'name');
          currentGroup = this.createProxyGroup(name, this.parseFlowValue(trimmed, 'type'));
          currentGroup.all = this.parseFlowList(trimmed, 'proxies');
          readingGroupProxies = false;
        } else if (trimmed.startsWith('- name:')) {
          if (currentGroup) {
            groups.push(currentGroup);
          }
          currentGroup = this.createProxyGroup(this.stripQuotes(trimmed.substring(7).trim()), '');
          readingGroupProxies = false;
        } else if (currentGroup) {
          if (trimmed.startsWith('type:')) {
            currentGroup.type = this.stripQuotes(trimmed.substring(5).trim());
          } else if (trimmed === 'proxies:') {
            readingGroupProxies = true;
          } else if (readingGroupProxies && trimmed.startsWith('- ')) {
            currentGroup.all.push(this.stripQuotes(trimmed.substring(2).trim()));
          } else if (trimmed.indexOf(':') > 0 && !trimmed.startsWith('- ')) {
            readingGroupProxies = false;
          }
        }
      }
    }

    if (currentNode) {
      nodesByName.set(currentNode.name, currentNode);
    }
    if (currentGroup) {
      groups.push(currentGroup);
    }

    for (const group of groups) {
      group.nodes = [];
      for (const name of group.all) {
        const node = nodesByName.get(name);
        if (node) {
          group.nodes.push(node);
        }
      }
      if (!group.now && group.all.length > 0) {
        group.now = group.all[0];
      }
      if (!group.type) {
        group.type = 'select';
      }
    }
    return groups.filter((group: ProxyGroup) => group.all.length > 0 || group.nodes.length > 0);
  }

  private isTopLevel(line: string): boolean {
    return line.length > 0 && line[0] !== ' ' && line[0] !== '\t' && !line.startsWith('-');
  }

  private createProxyNode(name: string, type: string): ProxyNode {
    return {
      name,
      type: type || 'proxy',
      server: '',
      port: 0,
      latency: -1,
      alive: true,
    };
  }

  private createProxyGroup(name: string, type: string): ProxyGroup {
    return {
      name,
      type: type || 'select',
      now: '',
      all: [],
      nodes: [],
      expanded: false,
    };
  }

  private parseFlowValue(line: string, key: string): string {
    const marker = `${key}:`;
    const start = line.indexOf(marker);
    if (start < 0) {
      return '';
    }
    let valueStart = start + marker.length;
    while (valueStart < line.length && line.charAt(valueStart) === ' ') {
      valueStart++;
    }
    let quote = '';
    let value = '';
    for (let i = valueStart; i < line.length; i++) {
      const ch = line.charAt(i);
      if ((ch === '"' || ch === "'") && quote === '') {
        quote = ch;
        continue;
      }
      if (quote !== '' && ch === quote) {
        quote = '';
        continue;
      }
      if (quote === '' && (ch === ',' || ch === '}')) {
        break;
      }
      value += ch;
    }
    return this.stripQuotes(value.trim());
  }

  private parseFlowList(line: string, key: string): string[] {
    const marker = `${key}:`;
    const start = line.indexOf(marker);
    if (start < 0) {
      return [];
    }
    const open = line.indexOf('[', start + marker.length);
    const close = line.indexOf(']', open + 1);
    if (open < 0 || close < 0) {
      return [];
    }
    const text = line.substring(open + 1, close);
    const parts = text.split(',');
    const result: string[] = [];
    for (const part of parts) {
      const value = this.stripQuotes(part.trim());
      if (value) {
        result.push(value);
      }
    }
    return result;
  }

  private parseNumber(text: string): number {
    const value = parseInt(this.stripQuotes(text));
    if (value !== value) {
      return 0;
    }
    return value;
  }

  private stripQuotes(text: string): string {
    let value = text.trim();
    if (value.length >= 2) {
      const first = value.charAt(0);
      const last = value.charAt(value.length - 1);
      if ((first === '"' && last === '"') || (first === "'" && last === "'")) {
        value = value.substring(1, value.length - 1);
      }
    }
    return value;
  }

  private decodeUtf8(bytes: number[]): string {
    let result = '';
    for (let i = 0; i < bytes.length; i++) {
      const b0 = bytes[i];
      if (b0 < 0x80) {
        result += String.fromCharCode(b0);
      } else if ((b0 & 0xe0) === 0xc0 && i + 1 < bytes.length) {
        const b1 = bytes[++i];
        result += String.fromCharCode(((b0 & 0x1f) << 6) | (b1 & 0x3f));
      } else if ((b0 & 0xf0) === 0xe0 && i + 2 < bytes.length) {
        const b1 = bytes[++i];
        const b2 = bytes[++i];
        result += String.fromCharCode(((b0 & 0x0f) << 12) | ((b1 & 0x3f) << 6) | (b2 & 0x3f));
      } else if ((b0 & 0xf8) === 0xf0 && i + 3 < bytes.length) {
        const b1 = bytes[++i];
        const b2 = bytes[++i];
        const b3 = bytes[++i];
        let codePoint = ((b0 & 0x07) << 18) | ((b1 & 0x3f) << 12) | ((b2 & 0x3f) << 6) | (b3 & 0x3f);
        codePoint -= 0x10000;
        result += String.fromCharCode(0xd800 + (codePoint >> 10));
        result += String.fromCharCode(0xdc00 + (codePoint & 0x3ff));
      }
    }
    return result;
  }
}
