const { app, BrowserWindow, ipcMain, dialog, shell, Menu, nativeImage } = require('electron');
const path = require('path');
const fs = require('fs');
const os = require('os');
const { spawn } = require('child_process');

let mainWindow;
let sidecarProcess = null;

// checkpoint-053（用户需求：应用名全局改为 VetarAI + 关于信息放原生菜单栏）
const APP_NAME = 'VetarAI';
const APP_VERSION = '0.4.0';
const APP_TAGLINE_CN = '一款零生态基础的Agent工具';
const APP_TAGLINE_EN = 'An ecosystem-agnostic Agent tool.';

let aboutWindow = null;

// checkpoint-054（用户 2026-08-30：关于里的 Logo 要用我这张原图）：
// 原生 About 面板在不同 macOS 版本对 iconPath 渲染不稳定，
// 改为点击"关于"打开专属小窗口，完整展示用户指定的 Logo 图片。
function openAboutWindow() {
  if (aboutWindow) { aboutWindow.focus(); return; }

  const logoPath = path.join(__dirname, 'renderer', 'src', 'assets', 'logo.png');
  let logoDataUrl = '';
  try {
    if (fs.existsSync(logoPath)) {
      logoDataUrl = 'data:image/png;base64,' + fs.readFileSync(logoPath).toString('base64');
    }
  } catch (e) { console.log('[about] logo load failed:', e.message); }

  const html = `<!DOCTYPE html><html><head><meta charset="utf-8"><style>
    * { margin:0; padding:0; box-sizing:border-box; }
    body { font-family:-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif; background:#fff;
           display:flex; flex-direction:column; align-items:center; justify-content:center;
           height:100vh; text-align:center; -webkit-user-select:none; }
    img { width:96px; height:96px; border-radius:14px; border:1px solid #1a1a1e; margin-bottom:20px; }
    .name { font-size:28px; font-weight:700; color:#1a1a1e; }
    .ver { margin-top:8px; font-size:13px; color:#8e8e99; font-family:Menlo,monospace; }
    .cn { margin-top:12px; font-size:14px; font-weight:500; color:#5c5c66; }
    .en { margin-top:4px; font-size:12px; color:#8e8e99; }
  </style></head><body>
    ${logoDataUrl ? `<img src="${logoDataUrl}" alt="${APP_NAME}">` : ''}
    <div class="name">${APP_NAME}</div>
    <div class="ver">版本号：${APP_VERSION}</div>
    <div class="cn">${APP_TAGLINE_CN}</div>
    <div class="en">${APP_TAGLINE_EN}</div>
  </body></html>`;

  aboutWindow = new BrowserWindow({
    width: 380, height: 460,
    resizable: false, minimizable: false, maximizable: false, fullscreenable: false,
    title: `关于 ${APP_NAME}`,
    webPreferences: { contextIsolation: true },
  });
  aboutWindow.setMenuBarVisibility(false);
  aboutWindow.loadURL('data:text/html;charset=utf-8,' + encodeURIComponent(html));
  aboutWindow.on('closed', () => { aboutWindow = null; });
}

function setupAppBranding() {
  app.setName(APP_NAME);

  // 原生"关于"面板（兜底）
  const aboutOptions = {
    applicationName: APP_NAME,
    applicationVersion: APP_VERSION,
    version: APP_VERSION,
    copyright: `${APP_TAGLINE_CN}\n${APP_TAGLINE_EN}`,
  };
  const logoPath = path.join(__dirname, 'renderer', 'src', 'assets', 'logo.png');
  if (fs.existsSync(logoPath)) aboutOptions.iconPath = logoPath;
  app.setAboutPanelOptions(aboutOptions);

  // macOS Dock 图标（checkpoint-054 → checkpoint-065 修正）：
  // 旧版直接用原始 logo.png 铺满画布，导致 Dock 里图标视觉偏大。
  // 现优先用标准比例合成图 dock_icon.png（白圆角底 + 80% 居中留边）；缺失时回退 logo。
  if (process.platform === 'darwin') {
    try {
      const dockIconPath = path.join(__dirname, 'renderer', 'src', 'assets', 'dock_icon.png');
      const iconPath = fs.existsSync(dockIconPath) ? dockIconPath : logoPath;
      if (fs.existsSync(iconPath)) app.dock.setIcon(nativeImage.createFromPath(iconPath));
    } catch (e) { console.log('[branding] dock icon failed:', e.message); }
  }

  // 原生应用菜单（macOS 顶部菜单栏）：应用菜单 + 编辑/视图/窗口标准菜单
  const template = [];
  if (process.platform === 'darwin') {
    template.push({
      label: APP_NAME,
      submenu: [
        { label: `关于 ${APP_NAME}`, click: () => openAboutWindow() },
        { type: 'separator' },
        { role: 'services' },
        { type: 'separator' },
        { role: 'hide', label: `隐藏 ${APP_NAME}` },
        { role: 'hideOthers' },
        { role: 'unhide' },
        { type: 'separator' },
        { role: 'quit', label: `退出 ${APP_NAME}` },
      ],
    });
  }
  template.push({ role: 'editMenu' });   // 复制/粘贴等（输入框需要）
  template.push({ role: 'viewMenu' });     // 刷新/缩放/开发者工具
  template.push({ role: 'windowMenu' });
  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

// checkpoint-043（用户需求：日志默认保存在应用文件内的日志文件夹）：
// 开发模式（应用目录可写）→ <应用目录>/logs/；打包模式（目录只读）→ 回退数据目录。
function resolveLogsDir(cfg) {
  const appLogs = path.join(__dirname, 'logs');
  try {
    fs.mkdirSync(appLogs, { recursive: true });
    const probe = path.join(appLogs, '.probe');
    fs.writeFileSync(probe, '');
    fs.unlinkSync(probe);
    return appLogs;
  } catch (e) {
    const dataRootExpanded = (cfg.dataRoot || '~/.subagent').replace(/^~/, os.homedir());
    return path.join(dataRootExpanded, 'logs');
  }
}

// ── Read config.json (single source of truth) ──────────────
function readConfig() {
  const cfg = {
    ollamaBaseUrl: 'http://localhost:11434',
    sidecarHost: '127.0.0.1',
    sidecarPort: 8765,
    vitePort: 5173,
    dataRoot: '~/.subagent',
    defaultModel: 'qwen3.8',
    configPath: '',
  };
  try {
    const home = os.homedir();
    const expand = (p) => p.replace(/^~/, home);
    const dataRoot = expand('~/.subagent'); // initial guess to find config
    // data_root may itself be configured; read a first-pass config to resolve it
    const firstPass = path.join(dataRoot, 'config.json');
    let parsed = null;
    if (fs.existsSync(firstPass)) parsed = JSON.parse(fs.readFileSync(firstPass, 'utf8'));
    let root = parsed && parsed.data_root ? expand(parsed.data_root) : dataRoot;
    const cfgPath = path.join(root, 'config.json');
    if (fs.existsSync(cfgPath)) parsed = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
    if (parsed) {
      cfg.ollamaBaseUrl = parsed.ollama_base_url || cfg.ollamaBaseUrl;
      cfg.sidecarHost = parsed.sidecar_host || cfg.sidecarHost;
      cfg.sidecarPort = parsed.sidecar_port || cfg.sidecarPort;
      cfg.vitePort = parsed.vite_port || cfg.vitePort;
      cfg.dataRoot = parsed.data_root || cfg.dataRoot;
      cfg.defaultModel = parsed.default_model || cfg.defaultModel;
    }
    cfg.configPath = cfgPath;
  } catch (e) {
    console.log('[main] config read error, using defaults:', e.message);
  }
  return cfg;
}

function createWindow() {
  const cfg = readConfig();
  mainWindow = new BrowserWindow({
    width: 1400, height: 900,
    title: APP_NAME,
    show: false, // checkpoint-064：等内容加载完再显示，衔接加载页，避免白屏闪烁
    // TS-103 B03：关闭 nodeIntegration + 开启 contextIsolation，
    // 渲染进程通过 preload.js（contextBridge）获得最小能力：
    //   window.__SUBAGENT__（配置注入）+ window.subagent.chooseWorkingDir()（B3 目录选择）
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      preload: path.join(__dirname, 'preload.js'),
    },
  });
  // 内容就绪 → 显示主窗口并关闭加载页
  mainWindow.once('ready-to-show', () => { mainWindow.show(); destroySplash(); });

  // checkpoint-063 封装：打包模式加载应用内静态前端产物（不依赖 Vite 开发服务器）；
  // 开发模式保持原逻辑（探测 Vite 端口）。
  if (app.isPackaged) {
    mainWindow.loadFile(path.join(__dirname, 'renderer', 'dist', 'index.html'));
  } else {
    // Auto-detect Vite port: configured port first, then neighbors
    const base = cfg.vitePort || 5173;
    const ports = [base, base + 1, base + 2];
    let idx = 0;

    const tryLoad = () => {
      if (idx >= ports.length) return;
      const url = `http://127.0.0.1:${ports[idx]}/`;
      mainWindow.loadURL(url).catch(() => {
        idx++;
        if (idx < ports.length) setTimeout(tryLoad, 500);
      });
    };
    tryLoad();

    mainWindow.webContents.openDevTools();
  }
}

function startSidecar() {
  const cfg = readConfig();

  // TS-102 B10：sidecar stderr 落盘日志（原先 'ignore' 全丢弃，崩溃无任何痕迹）
  // checkpoint-043：目录改为应用内 logs/（打包回退数据目录）
  const logDir = resolveLogsDir(cfg);
  const logFile = path.join(logDir, 'sidecar.log');
  const MAX_LOG_BYTES = 5 * 1024 * 1024; // >5MB 轮转为 .old（单文件，简单可靠）
  let logStream = null;
  try {
    fs.mkdirSync(logDir, { recursive: true });
    logStream = fs.createWriteStream(logFile, { flags: 'a' });
    logStream.on('error', () => { logStream = null; }); // 日志失败不影响应用运行
  } catch (e) { console.log('[main] log stream open failed:', e.message); }

  // checkpoint-063 封装：打包模式启动应用内的侧车独立二进制（无需目标机安装 Python）；
  // 开发模式保持原逻辑（源码目录 venv + uvicorn 字符串模块）。
  if (app.isPackaged) {
    const sidecarBin = path.join(process.resourcesPath, 'sidecar', 'vetarai-sidecar');
    sidecarProcess = spawn(sidecarBin, [], {
      env: {
        ...process.env,
        VETARAI_HOST: cfg.sidecarHost,
        VETARAI_PORT: String(cfg.sidecarPort),
      },
      stdio: ['pipe', 'ignore', 'pipe'],
    });
  } else {
    const sidecarDir = path.join(__dirname, 'sidecar');
    const venvPython = path.join(sidecarDir, '.venv', 'bin', 'python3');
    sidecarProcess = spawn(venvPython,
      ['-m', 'uvicorn', 'sidecar.app:app', '--host', cfg.sidecarHost, '--port', String(cfg.sidecarPort)],
      {
        cwd: __dirname,
        env: { ...process.env, PYTHONDONTWRITEBYTECODE: '1', PYTHONPATH: __dirname },
        stdio: ['pipe', 'ignore', 'pipe'], // stderr 捕获（stdout 仍丢弃）
      });
  }

  if (logStream) {
    sidecarProcess.stderr.on('data', (chunk) => {
      try {
        const ts = new Date().toISOString();
        logStream.write(`[${ts}] ${chunk}`);
        // 轮转：超阈值 → 关闭流，改名 .old，重开
        if (logStream.bytesWritten > MAX_LOG_BYTES) {
          logStream.end();
          fs.renameSync(logFile, logFile + '.old');
          logStream = fs.createWriteStream(logFile, { flags: 'a' });
        }
      } catch (e) { /* 日志失败不阻塞 */ }
    });
  }

  sidecarProcess.on('error', (err) => console.log('[sidecar spawn error]', err));
  sidecarProcess.on('close', () => { sidecarProcess = null; });
}

function stopSidecar() { if (sidecarProcess) { sidecarProcess.kill('SIGTERM'); sidecarProcess = null; } }

// ── IPC: choose working directory for a new project (B3) ──────────
ipcMain.handle('choose-working-dir', async (_event, options = {}) => {
  if (!mainWindow) return null;
  try {
    const res = await dialog.showOpenDialog(mainWindow, {
      title: options.title || '选择项目工作目录',
      properties: ['openDirectory', 'createDirectory'],
    });
    if (res.canceled || !res.filePaths || res.filePaths.length === 0) return null;
    return res.filePaths[0];
  } catch (e) {
    console.log('[ipc choose-working-dir]', e);
    return null;
  }
});

// ── IPC: 0.2.2 工作流文件输入节点——选择本机文件（只读对话框，不读取内容）──
// 0.2.4（W6）：支持多选文件 + 新增独立的"选文件夹"处理器。
ipcMain.handle('choose-input-file', async (_event, options = {}) => {
  if (!mainWindow) return null;
  try {
    const res = await dialog.showOpenDialog(mainWindow, {
      title: options.title || '选择文件',
      properties: options.multiple ? ['openFile', 'multiSelections'] : ['openFile'],
    });
    if (res.canceled || !res.filePaths || res.filePaths.length === 0) return null;
    return options.multiple ? res.filePaths : res.filePaths[0];
  } catch (e) {
    console.log('[ipc choose-input-file]', e);
    return null;
  }
});

// ── IPC: 0.2.4（W6）工作流文件节点——选择本机文件夹（只读对话框）──
ipcMain.handle('choose-input-dir', async (_event, options = {}) => {
  if (!mainWindow) return null;
  try {
    const res = await dialog.showOpenDialog(mainWindow, {
      title: options.title || '选择文件夹',
      properties: ['openDirectory', 'createDirectory'],
    });
    if (res.canceled || !res.filePaths || res.filePaths.length === 0) return null;
    return res.filePaths[0];
  } catch (e) {
    console.log('[ipc choose-input-dir]', e);
    return null;
  }
});

// ── IPC: 打开日志文件夹（checkpoint-043 用户需求：报错日志可打开排查）──
ipcMain.handle('open-logs-folder', async () => {
  try {
    const cfg = readConfig();
    const dir = resolveLogsDir(cfg);
    fs.mkdirSync(dir, { recursive: true });
    const err = await shell.openPath(dir);  // 空串 = 成功
    return { ok: !err, dir, error: err || '' };
  } catch (e) {
    return { ok: false, dir: '', error: String(e && e.message || e) };
  }
});

// ── IPC: 打开数据缓存目录（问题5修复：与日志目录分开——数据库/导出/知识索引/全局知识都在这里）──
ipcMain.handle('open-data-dir', async () => {
  try {
    const cfg = readConfig();
    const dir = (cfg.dataRoot || '~/.subagent').replace(/^~/, os.homedir());
    fs.mkdirSync(dir, { recursive: true });
    const err = await shell.openPath(dir);
    return { ok: !err, dir, error: err || '' };
  } catch (e) {
    return { ok: false, dir: '', error: String(e && e.message || e) };
  }
});

// ── IPC: 同步下发配置（2026-08-28 修复）────────────────────────────
// 沙盒化渲染进程的 preload 不能读文件系统（禁 require fs），
// 改由主进程在 preload 加载时同步提供配置注入对象。
ipcMain.on('get-injected-config', (event) => {
  const cfg = readConfig();
  event.returnValue = {
    sidecarHost: cfg.sidecarHost,
    sidecarPort: cfg.sidecarPort,
    ollamaBaseUrl: cfg.ollamaBaseUrl,
    dataRoot: cfg.dataRoot,
    defaultModel: cfg.defaultModel,
    configPath: cfg.configPath,
  };
});

// checkpoint-064：等待侧车就绪。封装后侧车是冻结二进制，首次启动需数秒；
// 前端若先于侧车加载会报"无法连接侧车"。主进程轮询 /api/config 直到就绪再开窗。
// 超时后仍开窗（前端显示错误提示，至少让用户看到界面与日志入口）。
const http = require('http');
function waitForSidecar(cfg, timeoutMs = 30000) {
  return new Promise((resolve) => {
    const deadline = Date.now() + timeoutMs;
    const tryOnce = () => {
      const req = http.get(
        { host: cfg.sidecarHost, port: cfg.sidecarPort, path: '/api/config', timeout: 2000 },
        (res) => { res.resume(); resolve(true); });
      req.on('error', () => {
        if (Date.now() >= deadline) resolve(false);
        else setTimeout(tryOnce, 300);
      });
      req.on('timeout', () => { req.destroy(); req.emit('error', new Error('timeout')); });
    };
    tryOnce();
  });
}

// checkpoint-064（用户体验）：启动加载页（Splash）。
// checkpoint-064b（用户反馈）：加载页与主窗口同尺寸、保留正常窗口边框，仅居中显示 Logo，
// 不带版本号/标语/步骤文案（"关于页"风格被用户否决）。
// 后台完成"启动侧车 → 就绪"后再切换到主窗口，杜绝白屏/误报"无法连接侧车"。
let splashWindow = null;
function createSplash() {
  splashWindow = new BrowserWindow({
    width: 1400, height: 900, // 与主窗口一致
    show: false,
    frame: true,              // 正常窗口边框（用户要求"正常应用页面"）
    resizable: false,
    title: APP_NAME,
    backgroundColor: '#F7F7F8',
    webPreferences: { nodeIntegration: false, contextIsolation: true },
  });
  splashWindow.loadFile(path.join(__dirname, 'splash.html'));
  splashWindow.once('ready-to-show', () => splashWindow.show());
  // 注入 Logo（开发/打包路径不同，统一用 renderer/src/assets/logo.png）
  splashWindow.webContents.once('did-finish-load', () => {
    try {
      const logoPath = path.join(__dirname, 'renderer', 'src', 'assets', 'logo.png');
      let logoDataUrl = '';
      if (fs.existsSync(logoPath)) {
        logoDataUrl = 'data:image/png;base64,' + fs.readFileSync(logoPath).toString('base64');
      }
      splashWindow.webContents.executeJavaScript(
        `document.getElementById('logo').src=${JSON.stringify(logoDataUrl)};`
      ).catch(() => {});
    } catch (e) { console.log('[splash] inject failed:', e.message); }
  });
}
// 更新加载页步骤文案（加载页关闭后静默忽略）
function setSplashStep(text) {
  if (!splashWindow || splashWindow.isDestroyed()) return;
  splashWindow.webContents.executeJavaScript(`window.setStep(${JSON.stringify(text)})`).catch(() => {});
}
function destroySplash() {
  if (splashWindow && !splashWindow.isDestroyed()) splashWindow.close();
  splashWindow = null;
}

app.whenReady().then(async () => {
  setupAppBranding();
  createSplash();
  setSplashStep('正在启动本地引擎…');
  startSidecar();
  setSplashStep('正在连接后端服务…');
  const ready = await waitForSidecar(readConfig());
  if (!ready) console.log('[main] sidecar 未能在超时内就绪，仍打开窗口（前端将显示连接提示）');
  setSplashStep(ready ? '引擎已就绪，正在加载界面…' : '正在加载界面…');
  createWindow();
});
app.on('window-all-closed', () => { stopSidecar(); app.quit(); });
app.on('before-quit', () => { stopSidecar(); destroySplash(); });
