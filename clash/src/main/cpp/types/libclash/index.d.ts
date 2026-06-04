export const startProcess: (binaryPath: string, configDir: string) => string;
export const stopProcess: () => void;
export const isProcessRunning: () => number;
export const testDlopen: (libPath: string) => string;
