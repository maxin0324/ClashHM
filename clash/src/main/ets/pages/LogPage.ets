import { getClashService, IClashService } from '../services/ClashService';
import { ConnectState } from '../models/ClashConfig';
import { LogEntry, LogType } from '../models/LogEntry';
import { LogItem, LogItemModel } from '../components/LogItem';
import { NativeCoreExtensionService } from '../services/NativeCoreExtensionService';
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';

interface ExtensionConnectionInfo {
  id: string;
  host: string;
  destinationIP: string;
  destinationPort: number;
  sourceIP: string;
  sourcePort: number;
  network: string;
  type: string;
  rule: string;
  rulePayload: string;
  proxyChain: string[];
  uploadBytes: number;
  downloadBytes: number;
}

@Entry
@Component
struct LogPage {
  @State logs: LogItemModel[] = [];
  @State filterText: string = '';
  @State diagnosticText: string = '';
  @State isLive: boolean = true;
  @State copyStatus: string = '';
  private service: IClashService | null = null;
  private pollTimer: number = -1;
  private listScroller: Scroller = new Scroller();
  private logHistory: LogEntry[] = [];

  aboutToAppear(): void {
    try {
      this.service = getClashService();
      this.loadLogs();
      this.startPolling();
    } catch (_e) {
      // service not ready
    }
  }

  aboutToDisappear(): void {
    this.stopPolling();
  }

  private async loadLogs(): Promise<void> {
    if (!this.service) {
      return;
    }
    await this.loadDiagnostics();
    const rawLogs = await this.getConnectionLogs();
    this.mergeConnectionLogs(rawLogs);
    this.applyFilter();
  }

  private applyFilter(): void {
    let filtered = this.logHistory;
    if (this.filterText.length > 0) {
      const keyword = this.filterText.toLowerCase();
      filtered = this.logHistory.filter((l: LogEntry) =>
        l.host.toLowerCase().includes(keyword) ||
        l.destinationIP.toLowerCase().includes(keyword) ||
        l.rule.toLowerCase().includes(keyword) ||
        l.proxyChain.join(' ').toLowerCase().includes(keyword)
      );
    }
    this.logs = filtered
      .slice()
      .sort((a: LogEntry, b: LogEntry) => b.timestamp - a.timestamp)
      .map((l: LogEntry) => LogItemModel.fromLogEntry(l));
  }

  private mergeConnectionLogs(incoming: LogEntry[]): void {
    const now = Date.now();
    for (const entry of incoming) {
      const stableId = this.stableLogId(entry);
      const index = this.logHistory.findIndex((item: LogEntry) => item.id === stableId);
      entry.id = stableId;
      if (index >= 0) {
        const old = this.logHistory[index];
        entry.timestamp = old.timestamp;
        this.logHistory[index] = entry;
      } else {
        entry.timestamp = entry.timestamp > 0 ? entry.timestamp : now;
        this.logHistory.push(entry);
      }
    }
    if (this.logHistory.length > 500) {
      this.logHistory = this.logHistory
        .slice()
        .sort((a: LogEntry, b: LogEntry) => b.timestamp - a.timestamp)
        .slice(0, 500);
    }
  }

  private stableLogId(entry: LogEntry): string {
    if (entry.id.length > 0) {
      return entry.id;
    }
    return `${entry.network}:${entry.sourceIP}:${entry.sourcePort}->${entry.host || entry.destinationIP}:${entry.destinationPort}`;
  }

  private async loadDiagnostics(): Promise<void> {
    if (!this.service || this.service.getState() !== ConnectState.CONNECTED) {
      this.diagnosticText = '';
      return;
    }
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const status = await new NativeCoreExtensionService(context).getStatus();
      if (status.ok && status.data) {
        this.diagnosticText = status.data;
      } else {
        this.diagnosticText = status.error || status.data || 'Native status unavailable';
      }
    } catch (e) {
      this.diagnosticText = `Native status unavailable: ${String(e)}`;
    }
  }

  private async getConnectionLogs(): Promise<LogEntry[]> {
    if (!this.service) {
      return [];
    }
    if (this.service.getState() === ConnectState.CONNECTED) {
      try {
        const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
        const result = await new NativeCoreExtensionService(context).getConnections();
        if (result.ok && result.data) {
          const conns = JSON.parse(result.data) as ExtensionConnectionInfo[];
          return conns.map((conn: ExtensionConnectionInfo): LogEntry => {
            return {
              id: conn.id,
              timestamp: Date.now(),
              type: this.mapLogType(conn.network),
              network: conn.network,
              sourceIP: conn.sourceIP,
              sourcePort: conn.sourcePort,
              destinationIP: conn.destinationIP,
              destinationPort: conn.destinationPort,
              host: conn.host,
              rule: conn.rule,
              rulePayload: conn.rulePayload,
              proxyChain: conn.proxyChain || [],
              downloadBytes: conn.downloadBytes,
              uploadBytes: conn.uploadBytes,
            };
          });
        }
        this.diagnosticText = `${this.diagnosticText}\nconnections: ${result.error || result.data || 'empty response'}`;
      } catch (e) {
        this.diagnosticText = `${this.diagnosticText}\nconnections: ${String(e)}`;
      }
    }
    return this.service.getConnections();
  }

  private mapLogType(network: string): LogType {
    const upper = network.toUpperCase();
    if (upper === 'UDP') {
      return LogType.UDP;
    }
    if (upper === 'DNS') {
      return LogType.DNS;
    }
    if (upper === 'HTTP') {
      return LogType.HTTP;
    }
    if (upper === 'HTTPS') {
      return LogType.HTTPS;
    }
    return LogType.TCP;
  }

  private startPolling(): void {
    this.pollTimer = setInterval(() => {
      if (this.isLive) {
        this.loadLogs();
      }
    }, 2000);
  }

  private stopPolling(): void {
    if (this.pollTimer !== -1) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  private async clearConnections(): Promise<void> {
    if (this.service) {
      if (this.service.getState() === ConnectState.CONNECTED) {
        await this.service.closeAllConnections();
      }
      this.logHistory = [];
      this.logs = [];
    }
  }

  private async copyVisibleLogs(): Promise<void> {
    const text = this.buildCopyText();
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      await pasteboard.getSystemPasteboard().setData(data);
      this.copyStatus = 'Copied';
    } catch (e) {
      this.copyStatus = `Copy failed: ${String(e)}`;
    }
  }

  private buildCopyText(): string {
    const lines: string[] = [];
    if (this.diagnosticText.length > 0) {
      lines.push('[Diagnostics]');
      lines.push(this.diagnosticText);
      lines.push('');
    }
    lines.push('[Connections]');
    for (const item of this.logs) {
      const target = item.host.length > 0 ? item.host : item.destinationIP;
      const chain = item.proxyChain.join(' -> ');
      lines.push(`${this.formatTime(item.timestamp)} ${item.network} ${target}:${item.destinationPort} rule=${item.rule} proxy=${chain} up=${item.uploadBytes} down=${item.downloadBytes}`);
    }
    return lines.join('\n');
  }

  private formatTime(ts: number): string {
    const d = new Date(ts);
    const h = String(d.getHours()).padStart(2, '0');
    const m = String(d.getMinutes()).padStart(2, '0');
    const s = String(d.getSeconds()).padStart(2, '0');
    return `${h}:${m}:${s}`;
  }

  build() {
    Column() {
      // Header
      Row() {
        Button($r('app.string.back'))
          .height(34)
          .fontSize(13)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.surface_glass'))
          .borderRadius(11)
          .border({ width: 1, color: $r('app.color.divider') })
          .padding({ left: 12, right: 12 })
          .onClick(() => {
            this.getUIContext().getRouter().back();
          })

        Column({ space: 4 }) {
          Text($r('app.string.logs'))
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text($r('app.string.connections_count', this.logs.length))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 12 })

        Row({ space: 4 }) {
          Circle()
            .width(8)
            .height(8)
            .fill(this.isLive ? $r('app.color.connected_color') : $r('app.color.text_secondary'))
          Text($r('app.string.live'))
            .fontSize(12)
            .fontColor(this.isLive ? $r('app.color.connected_color') : $r('app.color.text_secondary'))
        }
        .onClick(() => {
          this.isLive = !this.isLive;
        })
        .margin({ right: 10 })

        Button($r('app.string.copy'))
          .type(ButtonType.Normal)
          .height(34)
          .fontSize(12)
          .fontColor($r('app.color.primary'))
          .backgroundColor($r('app.color.surface_glass'))
          .borderRadius(11)
          .border({ width: 1, color: $r('app.color.divider') })
          .padding({ left: 12, right: 12 })
          .onClick(() => {
            this.copyVisibleLogs();
          })
          .margin({ right: 8 })

        Button($r('app.string.clear'))
          .type(ButtonType.Normal)
          .height(34)
          .fontSize(12)
          .fontColor($r('app.color.error_color'))
          .backgroundColor($r('app.color.surface_glass'))
          .borderRadius(11)
          .border({ width: 1, color: $r('app.color.divider') })
          .padding({ left: 12, right: 12 })
          .onClick(() => {
            this.clearConnections();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 34, bottom: 12 })

      Row() {
        Text($r('app.string.search'))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))

        TextInput({ placeholder: $r('app.string.filter_placeholder'), text: this.filterText })
          .layoutWeight(1)
          .height(36)
          .backgroundColor(Color.Transparent)
          .fontSize(14)
          .margin({ left: 8 })
          .onChange((value: string) => {
            this.filterText = value;
            this.loadLogs();
          })
          .onSubmit(() => {
            this.applyFilter();
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12 })
      .margin({ left: 16, right: 16, bottom: 10 })
      .height(42)
      .backgroundColor($r('app.color.surface_glass'))
      .backgroundBlurStyle(BlurStyle.Thin)
      .borderRadius(14)
      .border({ width: 1, color: $r('app.color.divider') })

      if (this.diagnosticText) {
        Column({ space: 6 }) {
          Text($r('app.string.latest_status'))
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(this.diagnosticText)
            .fontSize(10)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(6)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .copyOption(CopyOptions.LocalDevice)
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .margin({ left: 16, right: 16, bottom: 10 })
        .backgroundColor($r('app.color.surface_glass'))
        .backgroundBlurStyle(BlurStyle.Thin)
        .borderRadius(14)
        .border({ width: 1, color: $r('app.color.divider') })
      }

      if (this.copyStatus) {
        Text(this.copyStatus)
          .fontSize(10)
          .fontColor(this.copyStatus === 'Copied' ? $r('app.color.connected_color') : $r('app.color.error_color'))
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 8 })
      }

      List({ scroller: this.listScroller }) {
        ForEach(this.logs, (log: LogItemModel) => {
          ListItem() {
            LogItem({ entry: log })
          }
          .padding({ left: 16, right: 16, bottom: 8 })
        }, (log: LogItemModel) => log.id)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
  }
}
