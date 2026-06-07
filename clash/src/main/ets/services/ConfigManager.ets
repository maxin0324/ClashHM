import { fileIo } from '@kit.CoreFileKit';
import { ClashConfig, ProxyGroup, ProxyNode } from '../models/ClashConfig';
import { Constants } from '../common/Constants';
import { Logger } from '../common/Logger';
import { common } from '@kit.AbilityKit';

class ProviderConfig {
  name: string = '';
  path: string = '';
}

class ProviderContent {
  name: string = '';
  proxyLines: string[] = [];
  proxyNames: string[] = [];
}

class RuleProviderConfig {
  name: string = '';
  path: string = '';
  behavior: string = '';
}

class RuleProviderContent {
  name: string = '';
  ruleLines: string[] = [];
}

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
    content = this.expandLocalProxyProviders(content, subscriptionPath);
    content = this.expandLocalRuleProviders(content, subscriptionPath);
    return this.ensureRequiredFields(content);
  }

  private expandLocalProxyProviders(content: string, subscriptionPath: string): string {
    const providers = this.parseProviderConfigs(content, subscriptionPath);
    if (providers.length === 0) {
      return content;
    }

    const providerContents: ProviderContent[] = [];
    for (const provider of providers) {
      if (!provider.path || !this.configExists(provider.path)) {
        continue;
      }
      const providerText = this.readConfigFile(provider.path);
      const providerContent = this.parseProviderContent(provider.name, providerText);
      if (providerContent.proxyLines.length > 0) {
        providerContents.push(providerContent);
      }
    }

    if (providerContents.length === 0) {
      return content;
    }

    let merged = this.injectProviderProxyLines(content, providerContents);
    merged = this.expandGroupUseEntries(merged, providerContents);
    return merged;
  }

  private expandLocalRuleProviders(content: string, subscriptionPath: string): string {
    const providers = this.parseRuleProviderConfigs(content, subscriptionPath);
    if (providers.length === 0) {
      return content;
    }

    const providerRules: Map<string, RuleProviderContent> = new Map();
    for (const provider of providers) {
      if (!provider.path || !this.configExists(provider.path)) {
        continue;
      }
      const providerText = this.readConfigFile(provider.path);
      const providerContent = this.parseRuleProviderContent(provider, providerText);
      if (providerContent.ruleLines.length > 0) {
        providerRules.set(providerContent.name, providerContent);
      }
    }
    if (providerRules.size === 0) {
      return content;
    }
    return this.expandRuleSetEntries(content, providerRules);
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

  private parseProviderConfigs(content: string, subscriptionPath: string): ProviderConfig[] {
    const result: ProviderConfig[] = [];
    const lines = content.split('\n');
    let section = '';
    let current: ProviderConfig | null = null;
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#')) {
        continue;
      }
      if (this.isTopLevel(line)) {
        if (current) {
          result.push(current);
          current = null;
        }
        section = trimmed === 'proxy-providers:' ? 'proxy-providers' : '';
        continue;
      }
      if (section !== 'proxy-providers') {
        continue;
      }
      if (line.startsWith('  ') && !line.startsWith('    ') && trimmed.endsWith(':')) {
        if (current) {
          result.push(current);
        }
        current = new ProviderConfig();
        current.name = this.stripQuotes(trimmed.substring(0, trimmed.length - 1));
      } else if (current && trimmed.startsWith('path:')) {
        current.path = this.resolveProviderPath(subscriptionPath, this.stripQuotes(trimmed.substring(5).trim()));
      }
    }
    if (current) {
      result.push(current);
    }
    return result.filter((provider: ProviderConfig) => provider.name.length > 0);
  }

  private parseRuleProviderConfigs(content: string, subscriptionPath: string): RuleProviderConfig[] {
    const result: RuleProviderConfig[] = [];
    const lines = content.split('\n');
    let section = '';
    let current: RuleProviderConfig | null = null;
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#')) {
        continue;
      }
      if (this.isTopLevel(line)) {
        if (current) {
          result.push(current);
          current = null;
        }
        section = trimmed === 'rule-providers:' ? 'rule-providers' : '';
        continue;
      }
      if (section !== 'rule-providers') {
        continue;
      }
      if (line.startsWith('  ') && !line.startsWith('    ') && trimmed.endsWith(':')) {
        if (current) {
          result.push(current);
        }
        current = new RuleProviderConfig();
        current.name = this.stripQuotes(trimmed.substring(0, trimmed.length - 1));
      } else if (current && trimmed.startsWith('path:')) {
        current.path = this.resolveProviderPath(subscriptionPath, this.stripQuotes(trimmed.substring(5).trim()));
      } else if (current && trimmed.startsWith('behavior:')) {
        current.behavior = this.stripQuotes(trimmed.substring(9).trim()).toLowerCase();
      }
    }
    if (current) {
      result.push(current);
    }
    return result.filter((provider: RuleProviderConfig) => provider.name.length > 0);
  }

  private resolveProviderPath(subscriptionPath: string, providerPath: string): string {
    if (!providerPath) {
      return '';
    }
    if (providerPath.startsWith('/')) {
      return providerPath;
    }
    const baseDir = subscriptionPath.substring(0, subscriptionPath.lastIndexOf('/'));
    if (providerPath.startsWith('./')) {
      return `${baseDir}/${providerPath.substring(2)}`;
    }
    return `${baseDir}/${providerPath}`;
  }

  private parseProviderContent(name: string, content: string): ProviderContent {
    const provider = new ProviderContent();
    provider.name = name;
    const lines = content.split('\n');
    let section = '';
    let currentNodeLines: string[] = [];
    for (const line of lines) {
      const trimmed = line.trim();
      const topLevel = this.isTopLevel(line);
      if (topLevel) {
        if (currentNodeLines.length > 0) {
          this.pushProviderNode(provider, currentNodeLines);
          currentNodeLines = [];
        }
        section = trimmed === 'proxies:' ? 'proxies' : '';
        continue;
      }
      if (section !== 'proxies') {
        continue;
      }
      if (trimmed.startsWith('- ')) {
        if (currentNodeLines.length > 0) {
          this.pushProviderNode(provider, currentNodeLines);
        }
        currentNodeLines = [`  ${trimmed}`];
      } else if (currentNodeLines.length > 0 && (line.startsWith('    ') || line.startsWith('\t'))) {
        currentNodeLines.push(line.startsWith('  ') ? line : `  ${trimmed}`);
      }
    }
    if (currentNodeLines.length > 0) {
      this.pushProviderNode(provider, currentNodeLines);
    }
    return provider;
  }

  private parseRuleProviderContent(config: RuleProviderConfig, content: string): RuleProviderContent {
    const provider = new RuleProviderContent();
    provider.name = config.name;
    const behavior = this.detectRuleProviderBehavior(config.behavior, content);
    const entries = this.parseRuleProviderEntries(content);
    for (const entry of entries) {
      const rule = this.convertRuleProviderEntry(entry, behavior);
      if (rule) {
        provider.ruleLines.push(rule);
      }
    }
    return provider;
  }

  private detectRuleProviderBehavior(configBehavior: string, content: string): string {
    if (configBehavior) {
      return configBehavior.toLowerCase();
    }
    const lines = content.split('\n');
    for (const line of lines) {
      const trimmed = line.trim();
      if (trimmed.startsWith('behavior:')) {
        return this.stripQuotes(trimmed.substring(9).trim()).toLowerCase();
      }
    }
    return 'classical';
  }

  private parseRuleProviderEntries(content: string): string[] {
    const entries: string[] = [];
    const lines = content.split('\n');
    let section = '';
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#')) {
        continue;
      }
      const topLevel = this.isTopLevel(line);
      if (topLevel) {
        if (trimmed === 'payload:' || trimmed === 'rules:') {
          section = trimmed.substring(0, trimmed.length - 1);
        } else {
          section = '';
        }
        continue;
      }
      if (section === 'payload' || section === 'rules') {
        if (trimmed.startsWith('- ')) {
          const value = this.stripQuotes(trimmed.substring(2).trim());
          if (value) {
            entries.push(value);
          }
        }
      }
    }
    if (entries.length > 0) {
      return entries;
    }
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#') || trimmed.indexOf(':') >= 0) {
        continue;
      }
      entries.push(this.stripQuotes(trimmed));
    }
    return entries;
  }

  private convertRuleProviderEntry(entry: string, behavior: string): string {
    const value = this.stripQuotes(entry.trim());
    if (!value || value.startsWith('#')) {
      return '';
    }
    if (behavior === 'domain') {
      return `DOMAIN-SUFFIX,${this.normalizeDomainRuleValue(value)}`;
    }
    if (behavior === 'ipcidr' || behavior === 'ip-cidr') {
      const ruleType = value.indexOf(':') >= 0 ? 'IP-CIDR6' : 'IP-CIDR';
      return `${ruleType},${value}`;
    }
    const parts = this.splitRuleParts(value);
    if (parts.length < 2) {
      return '';
    }
    const ruleType = parts[0].toUpperCase();
    if (this.isSupportedExpandedRuleType(ruleType)) {
      return `${ruleType},${parts[1]}`;
    }
    return '';
  }

  private normalizeDomainRuleValue(value: string): string {
    let domain = value;
    if (domain.startsWith('+.')) {
      domain = domain.substring(2);
    } else if (domain.startsWith('.')) {
      domain = domain.substring(1);
    }
    return domain;
  }

  private isSupportedExpandedRuleType(ruleType: string): boolean {
    return ruleType === 'DOMAIN' || ruleType === 'DOMAIN-SUFFIX' || ruleType === 'IP-CIDR' ||
      ruleType === 'IP-CIDR6' || ruleType === 'DST-PORT';
  }

  private splitRuleParts(value: string): string[] {
    const parts: string[] = [];
    const rawParts = value.split(',');
    for (const rawPart of rawParts) {
      const part = this.stripQuotes(rawPart.trim());
      if (part) {
        parts.push(part);
      }
    }
    return parts;
  }

  private expandRuleSetEntries(content: string, providerRules: Map<string, RuleProviderContent>): string {
    const lines = content.split('\n');
    const output: string[] = [];
    let inRules = false;
    for (const line of lines) {
      const trimmed = line.trim();
      const topLevel = this.isTopLevel(line);
      if (topLevel) {
        inRules = trimmed === 'rules:';
        output.push(line);
        continue;
      }
      if (inRules && trimmed.startsWith('- ')) {
        const expanded = this.expandRuleSetLine(line, providerRules);
        if (expanded.length > 0) {
          for (const expandedLine of expanded) {
            output.push(expandedLine);
          }
          continue;
        }
      }
      output.push(line);
    }
    return output.join('\n');
  }

  private expandRuleSetLine(line: string, providerRules: Map<string, RuleProviderContent>): string[] {
    const dashIndex = line.indexOf('-');
    const indent = dashIndex > 0 ? line.substring(0, dashIndex) : '  ';
    const value = line.substring(dashIndex + 1).trim();
    const parts = this.splitRuleParts(value);
    if (parts.length < 3 || parts[0].toUpperCase() !== 'RULE-SET') {
      return [];
    }
    const provider = providerRules.get(parts[1]);
    const target = parts[2];
    if (!provider || provider.ruleLines.length === 0 || !target) {
      return [];
    }
    const expanded: string[] = [];
    for (const rule of provider.ruleLines) {
      expanded.push(`${indent}- ${rule},${target}`);
    }
    return expanded;
  }

  private pushProviderNode(provider: ProviderContent, nodeLines: string[]): void {
    const name = this.extractNodeName(nodeLines);
    if (!name) {
      return;
    }
    provider.proxyNames.push(name);
    for (const line of nodeLines) {
      provider.proxyLines.push(line);
    }
  }

  private extractNodeName(nodeLines: string[]): string {
    if (nodeLines.length === 0) {
      return '';
    }
    const first = nodeLines[0].trim();
    if (first.startsWith('- {')) {
      return this.parseFlowValue(first, 'name');
    }
    if (first.startsWith('- name:')) {
      return this.stripQuotes(first.substring(7).trim());
    }
    for (const line of nodeLines) {
      const trimmed = line.trim();
      if (trimmed.startsWith('name:')) {
        return this.stripQuotes(trimmed.substring(5).trim());
      }
    }
    return '';
  }

  private injectProviderProxyLines(content: string, providers: ProviderContent[]): string {
    const providerLines: string[] = [];
    for (const provider of providers) {
      for (const line of provider.proxyLines) {
        providerLines.push(line);
      }
    }
    if (providerLines.length === 0) {
      return content;
    }
    const lines = content.split('\n');
    const output: string[] = [];
    let inProxies = false;
    let inserted = false;
    for (const line of lines) {
      const trimmed = line.trim();
      const topLevel = this.isTopLevel(line);
      if (topLevel && inProxies && !trimmed.startsWith('proxies:')) {
        for (const providerLine of providerLines) {
          output.push(providerLine);
        }
        inserted = true;
        inProxies = false;
      }
      if (topLevel && trimmed.startsWith('proxies:')) {
        output.push('proxies:');
        inProxies = true;
        if (trimmed !== 'proxies:') {
          continue;
        }
      } else {
        output.push(line);
      }
    }
    if (inProxies && !inserted) {
      for (const providerLine of providerLines) {
        output.push(providerLine);
      }
      inserted = true;
    }
    if (!inserted) {
      output.push('proxies:');
      for (const providerLine of providerLines) {
        output.push(providerLine);
      }
    }
    return output.join('\n');
  }

  private expandGroupUseEntries(content: string, providers: ProviderContent[]): string {
    const providerNames: Map<string, string[]> = new Map();
    for (const provider of providers) {
      providerNames.set(provider.name, provider.proxyNames);
    }
    const lines = content.split('\n');
    const output: string[] = [];
    let inProxyGroups = false;
    let groupLines: string[] = [];
    for (const line of lines) {
      const trimmed = line.trim();
      const topLevel = this.isTopLevel(line);
      if (topLevel) {
        this.flushProxyGroupBlock(output, groupLines, providerNames);
        groupLines = [];
        inProxyGroups = trimmed === 'proxy-groups:';
        output.push(line);
        continue;
      }
      if (inProxyGroups && (trimmed.startsWith('- name:') || trimmed.startsWith('- {'))) {
        this.flushProxyGroupBlock(output, groupLines, providerNames);
        groupLines = [line];
        continue;
      }
      if (inProxyGroups && groupLines.length > 0) {
        groupLines.push(line);
      } else {
        output.push(line);
      }
    }
    this.flushProxyGroupBlock(output, groupLines, providerNames);
    return output.join('\n');
  }

  private flushProxyGroupBlock(output: string[], groupLines: string[], providerNames: Map<string, string[]>): void {
    if (groupLines.length === 0) {
      return;
    }
    const expandedNames = this.getExpandedProviderNames(groupLines, providerNames);
    if (expandedNames.length === 0) {
      for (const line of groupLines) {
        output.push(line);
      }
      return;
    }
    const firstLine = groupLines[0].trim();
    if (firstLine.startsWith('- {')) {
      this.writeFlowGroupAsBlock(output, firstLine, expandedNames);
      return;
    }
    let inserted = false;
    for (const line of groupLines) {
      output.push(line);
      if (!inserted && line.trim() === 'proxies:') {
        for (const name of expandedNames) {
          output.push(`      - ${name}`);
        }
        inserted = true;
      }
    }
    if (!inserted) {
      output.push('    proxies:');
      for (const name of expandedNames) {
        output.push(`      - ${name}`);
      }
    }
  }

  private getExpandedProviderNames(groupLines: string[], providerNames: Map<string, string[]>): string[] {
    const expanded: string[] = [];
    let readingUse = false;
    for (const line of groupLines) {
      const trimmed = line.trim();
      if (trimmed.startsWith('- {')) {
        const flowProviders = this.parseFlowList(trimmed, 'use');
        for (const provider of flowProviders) {
          this.appendProviderNames(expanded, providerNames, provider);
        }
      }
      if (trimmed.startsWith('use:')) {
        const flowProviders = this.parseFlowList(trimmed, 'use');
        for (const provider of flowProviders) {
          this.appendProviderNames(expanded, providerNames, provider);
        }
        readingUse = trimmed === 'use:';
        continue;
      }
      if (readingUse) {
        if (trimmed.startsWith('- ')) {
          this.appendProviderNames(expanded, providerNames, this.stripQuotes(trimmed.substring(2).trim()));
          continue;
        }
        if (trimmed.indexOf(':') >= 0) {
          readingUse = false;
        }
      }
    }
    return expanded;
  }

  private appendProviderNames(output: string[], providerNames: Map<string, string[]>, providerName: string): void {
    const names = providerNames.get(providerName);
    if (!names || names.length === 0) {
      return;
    }
    for (const name of names) {
      if (output.indexOf(name) < 0) {
        output.push(name);
      }
    }
  }

  private writeFlowGroupAsBlock(output: string[], line: string, expandedNames: string[]): void {
    const name = this.parseFlowValue(line, 'name');
    const type = this.parseFlowValue(line, 'type') || 'select';
    const existingNames = this.parseFlowList(line, 'proxies');
    output.push(`  - name: ${name}`);
    output.push(`    type: ${type}`);
    output.push('    proxies:');
    for (const proxyName of existingNames) {
      output.push(`      - ${proxyName}`);
    }
    for (const proxyName of expandedNames) {
      if (existingNames.indexOf(proxyName) < 0) {
        output.push(`      - ${proxyName}`);
      }
    }
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
    let squareDepth = 0;
    let curlyDepth = 0;
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
      if (quote === '') {
        if (ch === '[') {
          squareDepth++;
        } else if (ch === ']') {
          squareDepth = Math.max(0, squareDepth - 1);
        } else if (ch === '{') {
          curlyDepth++;
        } else if (ch === '}') {
          if (squareDepth === 0 && curlyDepth === 0) {
            break;
          }
          curlyDepth = Math.max(0, curlyDepth - 1);
        } else if (ch === ',' && squareDepth === 0 && curlyDepth === 0) {
          break;
        }
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
    if (open < 0) {
      return [];
    }
    let close = -1;
    let quote = '';
    let depth = 0;
    for (let i = open; i < line.length; i++) {
      const ch = line.charAt(i);
      if ((ch === '"' || ch === "'") && quote === '') {
        quote = ch;
        continue;
      }
      if (quote !== '' && ch === quote) {
        quote = '';
        continue;
      }
      if (quote === '') {
        if (ch === '[') {
          depth++;
        } else if (ch === ']') {
          depth--;
          if (depth === 0) {
            close = i;
            break;
          }
        }
      }
    }
    if (close < 0) {
      return [];
    }
    const text = line.substring(open + 1, close);
    const parts = this.splitFlowListItems(text);
    const result: string[] = [];
    for (const part of parts) {
      const value = this.stripQuotes(part.trim());
      if (value) {
        result.push(value);
      }
    }
    return result;
  }

  private splitFlowListItems(text: string): string[] {
    const result: string[] = [];
    let quote = '';
    let squareDepth = 0;
    let curlyDepth = 0;
    let current = '';
    for (let i = 0; i < text.length; i++) {
      const ch = text.charAt(i);
      if ((ch === '"' || ch === "'") && quote === '') {
        quote = ch;
        current += ch;
        continue;
      }
      if (quote !== '' && ch === quote) {
        quote = '';
        current += ch;
        continue;
      }
      if (quote === '') {
        if (ch === '[') {
          squareDepth++;
        } else if (ch === ']') {
          squareDepth = Math.max(0, squareDepth - 1);
        } else if (ch === '{') {
          curlyDepth++;
        } else if (ch === '}') {
          curlyDepth = Math.max(0, curlyDepth - 1);
        } else if (ch === ',' && squareDepth === 0 && curlyDepth === 0) {
          result.push(current);
          current = '';
          continue;
        }
      }
      current += ch;
    }
    if (current.length > 0) {
      result.push(current);
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
