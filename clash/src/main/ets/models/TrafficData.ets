export interface TrafficData {
  uploadSpeed: number; // bytes per second
  downloadSpeed: number; // bytes per second
  sessionUpload: number; // total bytes this session
  sessionDownload: number; // total bytes this session
  activeConnections: number;
}

export function createEmptyTraffic(): TrafficData {
  return {
    uploadSpeed: 0,
    downloadSpeed: 0,
    sessionUpload: 0,
    sessionDownload: 0,
    activeConnections: 0,
  };
}

export function formatSpeed(bytesPerSec: number): string {
  if (bytesPerSec <= 0) {
    return '0 B/s';
  }
  const units: string[] = ['B/s', 'KB/s', 'MB/s', 'GB/s'];
  let unitIndex = 0;
  let value = bytesPerSec;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex++;
  }
  return `${value.toFixed(unitIndex === 0 ? 0 : 1)} ${units[unitIndex]}`;
}
