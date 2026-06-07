import { ProxyGroup } from '../models/ClashConfig';
import { ProxyNodeItem } from './ProxyNodeItem';

@Component
export struct ProxyGroupCard {
  @ObjectLink group: ProxyGroupModel;
  @Prop canTestLatency: boolean = false;
  @Prop isTesting: boolean = false;
  onSelectProxy: (groupName: string, proxyName: string) => void = () => {};
  onTestGroup: (groupName: string) => void = () => {};

  build() {
    Column() {
      Row() {
        Column({ space: 4 }) {
          Text(this.group.name)
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(`${this.group.type} · ${this.group.now}`)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Text(this.isTesting ? '...' : 'ms')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.canTestLatency ? $r('app.color.primary') : $r('app.color.text_secondary'))
          .width(38)
          .height(30)
          .textAlign(TextAlign.Center)
          .padding({ top: 7 })
          .backgroundColor($r('app.color.page_bg'))
          .borderRadius(7)
          .opacity(this.canTestLatency ? 1 : 0.48)
          .margin({ left: 10 })
          .onClick(() => {
            if (this.canTestLatency && !this.isTesting) {
              this.onTestGroup(this.group.name);
            }
          })

        Text(this.group.expanded ? '⌃' : '⌄')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_secondary'))
          .width(34)
          .height(30)
          .textAlign(TextAlign.Center)
          .margin({ left: 10 })
          .onClick(() => {
            this.getUIContext().animateTo({ duration: 200 }, () => {
              this.group.expanded = !this.group.expanded;
            });
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 14 })

      if (this.group.expanded) {
        Divider()
          .color($r('app.color.divider'))
          .margin({ left: 16, right: 16 })

        ForEach(this.group.nodes, (node: ProxyNodeModel) => {
          ProxyNodeItem({
            node: node,
            isSelected: node.name === this.group.now,
            onTap: () => {
              this.onSelectProxy(this.group.name, node.name);
            }
          })
        }, (node: ProxyNodeModel) => node.name)

        ForEach(this.getAdditionalOptions(), (name: string) => {
          Row() {
            Radio({ value: name, group: this.group.name })
              .checked(name === this.group.now)
              .width(20)
              .height(20)
              .onChange((isChecked: boolean) => {
                if (isChecked) {
                  this.onSelectProxy(this.group.name, name);
                }
              })

            Text(name)
              .fontSize(14)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ left: 12 })

            Blank()

            if (name === 'DIRECT') {
              Text('0 ms')
                .fontSize(12)
                .fontColor($r('app.color.latency_good'))
            }
          }
          .width('100%')
          .height(44)
          .padding({ left: 16, right: 16 })
          .onClick(() => {
            this.onSelectProxy(this.group.name, name);
          })
        }, (name: string) => `builtin_${name}`)
      }
    }
    .width('100%')
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(8)
    .border({ width: 1, color: $r('app.color.divider') })
  }

  private getAdditionalOptions(): string[] {
    let result: string[] = [];
    const nodeNames: string[] = this.group.nodes.map((node: ProxyNodeModel) => node.name);
    for (const name of this.group.all) {
      if (nodeNames.indexOf(name) < 0) {
        result.push(name);
      }
    }
    return result;
  }
}

@Observed
export class ProxyGroupModel {
  name: string = '';
  type: string = '';
  now: string = '';
  all: string[] = [];
  nodes: ProxyNodeModel[] = [];
  expanded: boolean = false;

  constructor(group: ProxyGroup) {
    this.name = group.name;
    this.type = group.type;
    this.now = group.now;
    this.all = group.all;
    this.nodes = group.nodes.map(n => new ProxyNodeModel(n.name, n.type, n.server, n.port, n.latency, n.alive));
    this.expanded = group.expanded;
  }
}

@Observed
export class ProxyNodeModel {
  name: string;
  type: string;
  server: string;
  port: number;
  latency: number;
  alive: boolean;

  constructor(name: string, type: string, server: string, port: number, latency: number, alive: boolean) {
    this.name = name;
    this.type = type;
    this.server = server;
    this.port = port;
    this.latency = latency;
    this.alive = alive;
  }
}
