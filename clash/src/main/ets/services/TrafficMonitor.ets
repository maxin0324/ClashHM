import { getClashService } from './ClashService';
import { TrafficData, createEmptyTraffic } from '../models/TrafficData';
import { ConnectState } from '../models/ClashConfig';
import { Constants } from '../common/Constants';

export type TrafficCallback = (data: TrafficData) => void;

export class TrafficMonitor {
  private timer: number = -1;
  private callback: TrafficCallback | null = null;
  private currentData: TrafficData = createEmptyTraffic();

  setCallback(cb: TrafficCallback): void {
    this.callback = cb;
  }

  start(): void {
    this.stop();
    this.timer = setInterval(() => {
      this.poll();
    }, Constants.TRAFFIC_POLL_INTERVAL);
  }

  stop(): void {
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
    this.currentData = createEmptyTraffic();
    if (this.callback) {
      this.callback(this.currentData);
    }
  }

  isRunning(): boolean {
    return this.timer !== -1;
  }

  getCurrentData(): TrafficData {
    return this.currentData;
  }

  private poll(): void {
    try {
      const service = getClashService();
      if (service.getState() !== ConnectState.CONNECTED) {
        return;
      }
      this.currentData = service.getTraffic();
      if (this.callback) {
        this.callback(this.currentData);
      }
    } catch (_e) {
      // service not ready
    }
  }
}
