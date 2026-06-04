import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'ClashHM';

export class Logger {
  static debug(msg: string, ...args: string[]): void {
    hilog.debug(DOMAIN, TAG, msg, args);
  }

  static info(msg: string, ...args: string[]): void {
    hilog.info(DOMAIN, TAG, msg, args);
  }

  static warn(msg: string, ...args: string[]): void {
    hilog.warn(DOMAIN, TAG, msg, args);
  }

  static error(msg: string, ...args: string[]): void {
    hilog.error(DOMAIN, TAG, msg, args);
  }
}
