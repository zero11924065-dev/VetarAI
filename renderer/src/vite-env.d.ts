/// <reference types="vite/client" />

declare module '*.png' {
  const src: string;
  export default src;
}

interface ElectronAPI {
  callSidecar: (method: string, body?: object) => Promise<any>;
}

declare global {
  interface Window {
    electronAPI: ElectronAPI;
  }
}
