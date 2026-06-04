export interface LogEntry {
  id: string;
  timestamp: number;
  type: LogType;
  network: string; // TCP, UDP
  sourceIP: string;
  sourcePort: number;
  destinationIP: string;
  destinationPort: number;
  host: string;
  rule: string;
  rulePayload: string;
  proxyChain: string[];
  downloadBytes: number;
  uploadBytes: number;
}

export enum LogType {
  HTTP = 'HTTP',
  HTTPS = 'HTTPS',
  TCP = 'TCP',
  UDP = 'UDP',
  DNS = 'DNS'
}

export function formatLogEntry(entry: LogEntry): string {
  const chain = entry.proxyChain.join(' -> ');
  return `${entry.host || entry.destinationIP}:${entry.destinationPort} [${entry.rule}] -> ${chain}`;
}
