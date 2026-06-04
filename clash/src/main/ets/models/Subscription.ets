export interface Subscription {
  id: string;
  name: string;
  url: string;
  nodeCount: number;
  lastUpdate: number; // timestamp ms
  expireDate: number; // timestamp ms, 0 = unknown
  uploadUsed: number; // bytes
  downloadUsed: number; // bytes
  totalData: number; // bytes, 0 = unlimited
  filePath: string; // local config file path
  isActive: boolean;
  autoUpdate: boolean;
  updateInterval: number; // hours
}

export function createDefaultSubscription(): Subscription {
  return {
    id: '',
    name: '',
    url: '',
    nodeCount: 0,
    lastUpdate: 0,
    expireDate: 0,
    uploadUsed: 0,
    downloadUsed: 0,
    totalData: 0,
    filePath: '',
    isActive: false,
    autoUpdate: true,
    updateInterval: 24,
  };
}

export function formatBytes(bytes: number): string {
  if (bytes <= 0) {
    return '0 B';
  }
  const units: string[] = ['B', 'KB', 'MB', 'GB', 'TB'];
  let unitIndex = 0;
  let value = bytes;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex++;
  }
  return `${value.toFixed(unitIndex === 0 ? 0 : 1)} ${units[unitIndex]}`;
}

export function formatTimestamp(ts: number): string {
  if (ts <= 0) {
    return '--';
  }
  const date = new Date(ts);
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, '0');
  const d = String(date.getDate()).padStart(2, '0');
  const h = String(date.getHours()).padStart(2, '0');
  const min = String(date.getMinutes()).padStart(2, '0');
  return `${y}-${m}-${d} ${h}:${min}`;
}
