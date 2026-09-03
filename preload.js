/**
 * Electron preload 脚本（最小权限桥接）。
 *
 * 职责：
 *   1. 注入配置对象到 window.__SUBAGENT__（apiBase.ts 读取，零 Node 依赖）
 *   2. 暴露 window.subagent.chooseWorkingDir()（B3 目录选择器，走 IPC）
 *   3. 暴露 window.subagent.chooseInputFile()（0.2.2 工作流文件输入节点）
 *
 * 安全：仅暴露上述三项，不暴露任意 ipcRenderer / Node API。
 * contextIsolation=true 下渲染进程无法访问 Node，本脚本是唯一桥接点。
 *
 * ⚠️ 沙盒约束（2026-08-28 修复）：
 * Electron ≥20 渲染进程默认沙盒化，沙盒内 preload 只允许 require
 * electron(受限)/events/timers/url 四个模块——**禁止 require fs/path/os**
 * （旧版因此崩溃，window.subagent 从未注入，用户被降级到手动填路径）。
 * 配置改由主进程经同步 IPC 提供，本脚本不再触碰文件系统。
 */
const { contextBridge, ipcRenderer } = require('electron');

// 从主进程同步获取配置（主进程持有 readConfig()，读 ~/.subagent/config.json）
let injected = {};
try {
  injected = ipcRenderer.sendSync('get-injected-config') || {};
} catch (e) {
  console.log('[preload] config fetch failed:', e.message);
}

// 配置注入（apiBase.ts getInjected() 读取；对象被序列化到隔离世界）
contextBridge.exposeInMainWorld('__SUBAGENT__', injected);

// 最小 IPC 桥：仅暴露目录选择器（B3）、打开日志文件夹（checkpoint-043）、
// 文件选择器（0.2.2 工作流文件输入节点），不暴露任意 invoke
contextBridge.exposeInMainWorld('subagent', {
  chooseWorkingDir: () => ipcRenderer.invoke('choose-working-dir'),
  openLogsFolder: () => ipcRenderer.invoke('open-logs-folder'),
  chooseInputFile: () => ipcRenderer.invoke('choose-input-file'),
});
