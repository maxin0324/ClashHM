import { ProxyGroup } from '../models/ClashConfig';
import { ProxyNodeItem } from './ProxyNodeItem';
import { Constants } from '../common/Constants';

@Component
export struct ProxyGroupCard {
  @ObjectLink group: ProxyGroupModel;
  onSelectProxy: (groupName: string, proxyName: string) => void = () => {};
  onTestLatency: (groupName: string) => void = () => {};

  build() {
    Column() {
      // Header
      Row() {
        Column({ space: 2 }) {
          Text(this.group.name)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(`${this.group.type} · ${this.group.now}`)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Button('Test')
          .type(ButtonType.Normal)
          .height(28)
          .fontSize(12)
          .fontColor($r('app.color.primary'))
          .backgroundColor(Color.Transparent)
          .borderWidth(1)
          .borderColor($r('app.color.primary'))
          .borderRadius(14)
          .padding({ left: 12, right: 12 })
          .onClick(() => {
            this.onTestLatency(this.group.name);
          })

        Text(this.group.expanded ? '▲' : '▼')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .margin({ left: 8 })
          .onClick(() => {
            this.getUIContext().animateTo({ duration: 200 }, () => {
              this.group.expanded = !this.group.expanded;
            });
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 14 })

      // Node list
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

        // Built-in options
        ForEach(this.getBuiltinOptions(), (name: string) => {
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
    .borderRadius(12)
  }

  private getBuiltinOptions(): string[] {
    let result: string[] = [];
    for (const name of this.group.all) {
      if (name === 'DIRECT' || name === 'REJECT' || name === 'Proxy' || name === 'Auto') {
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
