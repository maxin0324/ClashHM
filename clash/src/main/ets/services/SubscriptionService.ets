import { http } from '@kit.NetworkKit';
import { preferences } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { Subscription, createDefaultSubscription } from '../models/Subscription';
import { Constants } from '../common/Constants';
import { Logger } from '../common/Logger';
import { common } from '@kit.AbilityKit';

class ProviderFetchConfig {
  name: string = '';
  section: string = '';
  url: string = '';
  path: string = '';
}

export class SubscriptionService {
  private context: common.UIAbilityContext;
  private store: preferences.Preferences | null = null;
  private subscriptions: Subscription[] = [];

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  async init(): Promise<void> {
    try {
      this.store = await preferences.getPreferences(this.context, 'subscriptions_store');
    } catch (e) {
      Logger.error('Failed to get preferences store: %{public}s', String(e));
      return;
    }
    await this.loadSubscriptions();
  }

  private async loadSubscriptions(): Promise<void> {
    if (!this.store) {
      return;
    }
    try {
      const data = await this.store.get(Constants.SUBSCRIPTIONS_KEY, '[]') as string;
      this.subscriptions = JSON.parse(data) as Subscription[];
      await this.recountLocalSubscriptions();
    } catch (e) {
      Logger.error('Failed to parse subscriptions: %{public}s', String(e));
      this.subscriptions = [];
    }
  }

  private async saveSubscriptions(): Promise<void> {
    if (!this.store) {
      return;
    }
    try {
      await this.store.put(Constants.SUBSCRIPTIONS_KEY, JSON.stringify(this.subscriptions));
      await this.store.flush();
    } catch (e) {
      Logger.error('Failed to save subscriptions: %{public}s', String(e));
    }
  }

  getSubscriptions(): Subscription[] {
    return this.subscriptions;
  }

  getActiveSubscription(): Subscription | null {
    return this.subscriptions.find(s => s.isActive) || null;
  }

  async addSubscription(name: string, url: string): Promise<Subscription> {
    const sub = createDefaultSubscription();
    sub.id = this.generateId();
    sub.name = name;
    sub.url = url;
    sub.isActive = this.subscriptions.length === 0;

    const configDir = `${this.context.filesDir}/${Constants.CONFIG_DIR}`;
    try {
      fileIo.mkdirSync(configDir, true);
    } catch (_e) {
      // directory may exist
    }
    sub.filePath = `${configDir}/${sub.id}.yaml`;

    await this.fetchSubscriptionContent(sub);
    this.subscriptions.push(sub);
    await this.saveSubscriptions();
    return sub;
  }

  async updateSubscription(id: string): Promise<void> {
    const sub = this.subscriptions.find(s => s.id === id);
    if (!sub) {
      return;
    }
    await this.fetchSubscriptionContent(sub);
    sub.lastUpdate = Date.now();
    await this.saveSubscriptions();
  }

  async deleteSubscription(id: string): Promise<void> {
    const sub = this.subscriptions.find(s => s.id === id);
    if (sub) {
      try {
        fileIo.unlinkSync(sub.filePath);
      } catch (_e) {
        // file may not exist
      }
      this.subscriptions = this.subscriptions.filter(s => s.id !== id);
      if (sub.isActive && this.subscriptions.length > 0) {
        this.subscriptions[0].isActive = true;
      }
      await this.saveSubscriptions();
    }
  }

  async setActive(id: string): Promise<void> {
    for (const sub of this.subscriptions) {
      sub.isActive = sub.id === id;
    }
    await this.saveSubscriptions();
  }

  async editSubscription(id: string, name: string, url: string): Promise<void> {
    const sub = this.subscriptions.find(s => s.id === id);
    if (sub) {
      sub.name = name;
      sub.url = url;
      await this.saveSubscriptions();
    }
  }

  private async fetchSubscriptionContent(sub: Subscription): Promise<void> {
    try {
      Logger.info('fetch step 1: creating http request');
      const httpRequest = http.createHttp();
      Logger.info('fetch step 2: sending request to %{public}s', sub.url);
      const response = await httpRequest.request(sub.url, {
        method: http.RequestMethod.GET,
        header: {
          'User-Agent': 'clash-verge/v2.2.0',
        },
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 15000,
        readTimeout: 30000,
      });

      Logger.info('fetch step 3: response code %{public}s', String(response.responseCode));
      const code: number = response.responseCode;
      if (code >= 200 && code < 400) {
        let content = response.result as string;
        if (!content || content.length === 0) {
          Logger.error('fetch: empty response body');
          return;
        }
        content = this.normalizeSubscriptionContent(content);
        content = await this.materializeRemoteProviders(sub, content);
        Logger.info('fetch step 4: content length %{public}s', String(content.length));

        Logger.info('fetch step 5: writing to file %{public}s', sub.filePath);
        const file = fileIo.openSync(sub.filePath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
        fileIo.writeSync(file.fd, content);
        fileIo.closeSync(file);
        Logger.info('fetch step 6: file written');

        sub.lastUpdate = Date.now();
        try {
          if (typeof content === 'string') {
            this.countNodes(sub, content);
          }
        } catch (_e) {
          // node counting is optional
        }
        Logger.info('fetch step 7: done, nodes=%{public}s', String(sub.nodeCount));
      }
      httpRequest.destroy();
    } catch (e) {
      Logger.error('Failed to fetch subscription: %{public}s', String(e));
      throw new Error(String(e));
    }
  }

  private parseSubscriptionInfo(sub: Subscription, headers: Record<string, string>): void {
    const userInfo = headers['subscription-userinfo'] || headers['Subscription-Userinfo'] || '';
    if (userInfo) {
      const parts = userInfo.split(';');
      for (const part of parts) {
        const kv = part.trim().split('=');
        if (kv.length === 2) {
          const key = kv[0].trim();
          const value = parseInt(kv[1].trim());
          if (key === 'upload') sub.uploadUsed = value;
          else if (key === 'download') sub.downloadUsed = value;
          else if (key === 'total') sub.totalData = value;
          else if (key === 'expire') sub.expireDate = value * 1000;
        }
      }
    }
  }

  private async materializeRemoteProviders(sub: Subscription, content: string): Promise<string> {
    const providers = this.parseProviderFetchConfigs(content);
    if (providers.length === 0) {
      return content;
    }

    const configDir = sub.filePath.substring(0, sub.filePath.lastIndexOf('/'));
    const providerDir = `${configDir}/providers`;
    try {
      fileIo.mkdirSync(providerDir, true);
    } catch (_e) {
      // directory may exist
    }

    const proxyLocalPaths: Map<string, string> = new Map();
    const ruleLocalPaths: Map<string, string> = new Map();
    for (const provider of providers) {
      if (!provider.url) {
        continue;
      }
      try {
        const prefix = provider.section === 'rule-providers' ? 'rule' : 'proxy';
        const localPath = `${providerDir}/${sub.id}_${prefix}_${this.safeFileName(provider.name)}.yaml`;
        const providerContent = await this.fetchProviderContent(provider.url);
        this.writeTextFile(localPath, providerContent);
        if (provider.section === 'rule-providers') {
          ruleLocalPaths.set(provider.name, localPath);
        } else {
          proxyLocalPaths.set(provider.name, localPath);
        }
        Logger.info('provider %{public}s saved to %{public}s', provider.name, localPath);
      } catch (e) {
        Logger.error('Failed to fetch provider %{public}s: %{public}s', provider.name, String(e));
      }
    }

    if (proxyLocalPaths.size === 0 && ruleLocalPaths.size === 0) {
      return content;
    }
    let rewritten = content;
    if (proxyLocalPaths.size > 0) {
      rewritten = this.rewriteProviderPaths(rewritten, 'proxy-providers', proxyLocalPaths);
    }
    if (ruleLocalPaths.size > 0) {
      rewritten = this.rewriteProviderPaths(rewritten, 'rule-providers', ruleLocalPaths);
    }
    return rewritten;
  }

  private async fetchProviderContent(url: string): Promise<string> {
    const httpRequest = http.createHttp();
    try {
      const response = await httpRequest.request(url, {
        method: http.RequestMethod.GET,
        header: {
          'User-Agent': 'clash-verge/v2.2.0',
        },
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 15000,
        readTimeout: 30000,
      });
      const code: number = response.responseCode;
      if (code < 200 || code >= 400) {
        throw new Error(`provider response code ${code}`);
      }
      const text = response.result as string;
      if (!text || text.length === 0) {
        throw new Error('empty provider response');
      }
      return this.normalizeSubscriptionContent(text);
    } catch (e) {
      throw new Error(`provider fetch failed: ${String(e)}`);
    } finally {
      httpRequest.destroy();
    }
  }

  private parseProviderFetchConfigs(content: string): ProviderFetchConfig[] {
    const providers: ProviderFetchConfig[] = [];
    const lines = content.split('\n');
    let section = '';
    let current: ProviderFetchConfig | null = null;
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#')) {
        continue;
      }
      const isTopLevel = line.length > 0 && line[0] !== ' ' && line[0] !== '\t' && !line.startsWith('-');
      if (isTopLevel) {
        if (current) {
          providers.push(current);
          current = null;
        }
        if (trimmed === 'proxy-providers:') {
          section = 'proxy-providers';
        } else if (trimmed === 'rule-providers:') {
          section = 'rule-providers';
        } else {
          section = '';
        }
        continue;
      }
      if (section !== 'proxy-providers' && section !== 'rule-providers') {
        continue;
      }
      if (line.startsWith('  ') && !line.startsWith('    ') && trimmed.endsWith(':')) {
        if (current) {
          providers.push(current);
        }
        current = new ProviderFetchConfig();
        current.section = section;
        current.name = this.stripQuotes(trimmed.substring(0, trimmed.length - 1));
      } else if (current && trimmed.startsWith('url:')) {
        current.url = this.stripQuotes(trimmed.substring(4).trim());
      } else if (current && trimmed.startsWith('path:')) {
        current.path = this.stripQuotes(trimmed.substring(5).trim());
      }
    }
    if (current) {
      providers.push(current);
    }
    return providers.filter((provider: ProviderFetchConfig) => provider.name.length > 0 && provider.url.length > 0);
  }

  private rewriteProviderPaths(content: string, targetSection: string, localPaths: Map<string, string>): string {
    const lines = content.split('\n');
    const output: string[] = [];
    let section = '';
    let currentProvider = '';
    let currentLocalPath = '';
    let pathWritten = false;
    for (const line of lines) {
      const trimmed = line.trim();
      const isTopLevel = line.length > 0 && line[0] !== ' ' && line[0] !== '\t' && !line.startsWith('-');
      if (isTopLevel) {
        if (currentLocalPath && !pathWritten) {
          output.push(`    path: ${currentLocalPath}`);
        }
        currentProvider = '';
        currentLocalPath = '';
        pathWritten = false;
        section = trimmed === `${targetSection}:` ? targetSection : '';
        output.push(line);
        continue;
      }
      if (section === targetSection && line.startsWith('  ') && !line.startsWith('    ') && trimmed.endsWith(':')) {
        if (currentLocalPath && !pathWritten) {
          output.push(`    path: ${currentLocalPath}`);
        }
        currentProvider = this.stripQuotes(trimmed.substring(0, trimmed.length - 1));
        currentLocalPath = localPaths.get(currentProvider) || '';
        pathWritten = false;
        output.push(line);
        continue;
      }
      if (section === targetSection && currentLocalPath && trimmed.startsWith('path:')) {
        output.push(`    path: ${currentLocalPath}`);
        pathWritten = true;
        continue;
      }
      output.push(line);
    }
    if (currentLocalPath && !pathWritten) {
      output.push(`    path: ${currentLocalPath}`);
    }
    return output.join('\n');
  }

  private writeTextFile(filePath: string, content: string): void {
    let file: fileIo.File | null = null;
    try {
      file = fileIo.openSync(filePath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, content);
    } catch (e) {
      throw new Error(`write file failed: ${String(e)}`);
    } finally {
      if (file !== null) {
        try {
          fileIo.closeSync(file);
        } catch (_e) {
        }
      }
    }
  }

  private safeFileName(value: string): string {
    let output = '';
    for (let i = 0; i < value.length; i++) {
      const ch = value.charAt(i);
      const code = value.charCodeAt(i);
      const isDigit = code >= 48 && code <= 57;
      const isUpper = code >= 65 && code <= 90;
      const isLower = code >= 97 && code <= 122;
      if (isDigit || isUpper || isLower || ch === '-' || ch === '_') {
        output += ch;
      } else {
        output += '_';
      }
    }
    return output || 'provider';
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

  private countNodes(sub: Subscription, content: string): void {
    let count = 0;
    const lines = content.split('\n');
    let inProxies = false;
    let inProxyProviders = false;
    for (const line of lines) {
      const isTopLevel = line.length > 0 && line[0] !== ' ' && line[0] !== '\t' && !line.startsWith('-');
      const trimmed = line.trim();
      if (isTopLevel && trimmed === 'proxies:') {
        inProxies = true;
        inProxyProviders = false;
        continue;
      }
      if (isTopLevel && trimmed === 'proxy-providers:') {
        inProxyProviders = true;
        inProxies = false;
        continue;
      }
      if (inProxies) {
        if (isTopLevel && trimmed.indexOf(':') > 0 && trimmed !== 'proxies:') {
          inProxies = false;
        } else if (trimmed.startsWith('- {') && (trimmed.indexOf('server:') >= 0 || trimmed.indexOf('"server"') >= 0 || trimmed.indexOf("'server'") >= 0)) {
          count++;
        } else if (trimmed.startsWith('- {"name"') || trimmed.startsWith("- {'name'")) {
          count++;
        } else if (trimmed.startsWith('server:')) {
          count++;
        }
      } else if (inProxyProviders) {
        if (trimmed.startsWith('path:') || trimmed.startsWith('url:')) {
          count++;
        } else if (isTopLevel && trimmed.indexOf(':') > 0 && trimmed !== 'proxy-providers:') {
          inProxyProviders = false;
        }
      }
    }

    if (count === 0) {
      for (const line of lines) {
        const trimmed = line.trim();
        if (trimmed.startsWith('server:') || trimmed.indexOf('"server"') >= 0 || trimmed.indexOf("'server'") >= 0) {
          count++;
        }
      }
    }
    sub.nodeCount = count;
  }

  private async recountLocalSubscriptions(): Promise<void> {
    let changed = false;
    for (const sub of this.subscriptions) {
      if (!sub.filePath) {
        continue;
      }
      try {
        const content = this.readTextFile(sub.filePath);
        const oldCount = sub.nodeCount;
        this.countNodes(sub, content);
        if (sub.nodeCount !== oldCount) {
          changed = true;
        }
      } catch (_e) {
        // Keep stored metadata if the profile file is unavailable.
      }
    }
    if (changed) {
      await this.saveSubscriptions();
    }
  }

  private readTextFile(filePath: string): string {
    try {
      const file = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY);
      let content = '';
      try {
        const stat = fileIo.statSync(filePath);
        const buffer = new ArrayBuffer(stat.size);
        fileIo.readSync(file.fd, buffer);
        const view = new Uint8Array(buffer);
        const bytes: number[] = [];
        for (let i = 0; i < view.length; i++) {
          bytes.push(view[i]);
        }
        content = this.decodeUtf8(bytes);
      } catch (e) {
        Logger.error('Failed to read subscription file: %{public}s', String(e));
      }
      try {
        fileIo.closeSync(file);
      } catch (_e) {
        // ignore close failure
      }
      return content;
    } catch (e) {
      Logger.error('Failed to open subscription file: %{public}s', String(e));
      return '';
    }
  }

  private isBase64(str: string): boolean {
    const trimmed = str.trim();
    if (trimmed.length === 0 || trimmed.includes('proxies:')) {
      return false;
    }
    const base64Regex = /^[A-Za-z0-9+/\n\r]+=*$/;
    return base64Regex.test(trimmed.replace(/\s/g, ''));
  }

  private normalizeSubscriptionContent(content: string): string {
    let normalized = content.trim();
    if (this.isBase64(normalized)) {
      const decoded = this.decodeBase64ToString(normalized);
      if (decoded.length > 0) {
        normalized = decoded.trim();
      }
    }

    if (!normalized.includes('proxies:') && !normalized.includes('proxy-providers:')) {
      const firstLine = normalized.split('\n')[0]?.trim() || '';
      if (firstLine.startsWith('ss://') || firstLine.startsWith('ssr://') ||
        firstLine.startsWith('vmess://') || firstLine.startsWith('vless://') ||
        firstLine.startsWith('trojan://') || firstLine.startsWith('hysteria2://') ||
        firstLine.startsWith('hy2://')) {
        throw new Error('This subscription returns share-link nodes instead of Clash YAML. Link conversion is not implemented yet.');
      }
    }

    return normalized + '\n';
  }

  private decodeBase64ToString(input: string): string {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    const clean = input.replace(/\s/g, '').replace(/-/g, '+').replace(/_/g, '/');
    const bytes: number[] = [];
    let buffer = 0;
    let bits = 0;
    for (let i = 0; i < clean.length; i++) {
      const ch = clean.charAt(i);
      if (ch === '=') {
        break;
      }
      const value = chars.indexOf(ch);
      if (value < 0) {
        continue;
      }
      buffer = (buffer << 6) | value;
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        bytes.push((buffer >> bits) & 0xff);
      }
    }
    return this.decodeUtf8(bytes);
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

  private generateId(): string {
    return `sub_${Date.now()}_${Math.floor(Math.random() * 10000)}`;
  }
}
