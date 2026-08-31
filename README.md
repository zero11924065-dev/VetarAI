# VetarAI — Ollama 驱动的本地多 Agent 编排桌面应用

> 一款零生态基础的 Agent 工具 | An ecosystem-agnostic Agent tool.
>
> 当前版本：0.1.66（macOS · Apple Silicon）

<div align="center">

**⬇️ [下载 VetarAI 0.1.66 安装包](https://github.com/zero11924065-dev/VetarAI/releases/tag/v0.1.66)**

（132MB · macOS Apple Silicon · dmg 格式）

</div>

**如何安装**：下载 `VetarAI-0.1.66-arm64.dmg` → 双击挂载 → 把 VetarAI 拖入「应用程序」文件夹 → 从启动台打开。
> 首装因未签名可能提示"无法验证开发者"：右键 → 打开，或终端执行 `xattr -cr /Applications/VetarAI.app`。

VetarAI 是一个运行在本地的桌面应用，让你在应用内自由创建/管理多个**项目**，每个项目内动态创建**主 Agent** 与**子 Agent**。各 Agent 独立运行、独立上下文，通过 Ollama 调用本地大模型对话，并支持把大任务**委派**给子 Agent、让多个 Agent **圆桌讨论**。全部数据保存在本地，不依赖任何云端服务。

## 核心功能

- **多项目隔离**：每个项目独立工作目录、独立数据库、独立会话，互不干扰。
- **主-子委派**：主 Agent 可把任务委派给子 Agent，子 Agent 独立执行并按固定契约"交卷"汇报；失败自动追问一次，仍失败标记异常不中断。
- **独立 Agent**：与项目平级的一等公民，不属于任何项目，可单独创建/删除，删项目不影响它。
- **圆桌讨论**：多个 Agent 围绕议题共享讨论纪要，支持用户/AI 主持，用户掌握结束权；可手动停止。
- **多模态**：图片走视觉入流，多模态模型可直接读图（OCR/识别）。
- **大批量任务稳健性**：委派活性超时（防模型僵死无限等待）、相同任务去重 + 失败重试上限（防级联重试）、成功后可选自动清理子 Agent。
- **推理后端可换**：Ollama（默认）或任意 OpenAI 兼容服务（LM Studio / llama.cpp server / vLLM / 远程中转，支持 API Key）。
- **知识/记忆/技能**：项目知识库、全局/项目记忆、本地技能（SKILL.md），均按项启用。
- **插件系统**：从 GitHub 克隆或本地路径安装插件，钩子手动触发，逐项启用/禁用。
- **网络守卫**：境内/境外出站管控 + 失败熔断，防无代理空转死循环。
- **上下文管理**：Token 用量指示、溢出预警、智能压缩归档留痕。

## 快速启动（开发模式）

### 1. 安装前端依赖
```bash
cd renderer
npm install
```

### 2. 安装 Python sidecar 依赖
```bash
cd ../sidecar
python3 -m venv .venv
.venv/bin/pip install fastapi uvicorn httpx pydantic pypdf python-docx openpyxl
```

### 3. 启动应用
```bash
cd ..
npm start          # 或 ./node_modules/electron/Electron.app/Contents/MacOS/Electron .
```
应用启动时会自动拉起 Python 侧车（默认 `http://127.0.0.1:8765`）。

### 4. 准备本地模型
需本机运行 **Ollama** 并拉取模型（如 `ollama pull qwen3.8`）。应用通过 `http://localhost:11434` 连接。

## 使用安装包（推荐普通用户）

下载 `VetarAI-<版本>-arm64.dmg`，挂载后拖入「应用程序」即可。首装因未签名可能提示"无法验证开发者"：右键 → 打开，或终端执行 `xattr -cr /Applications/VetarAI.app`。

## 目录结构
```
subagent/
├── main.js                  # Electron 主进程（窗口/菜单/侧车拉起/关于）
├── splash.html              # 启动加载页
├── renderer/                # React 前端 (Vite + TS)
│   └── src/
│       ├── App.tsx          # 根组件（左栏+对话+圆桌三栏布局）
│       └── panels/          # 各面板（项目/Agent/对话/圆桌/设置/推理/插件…）
├── sidecar/                 # Python 侧车 (FastAPI)
│   ├── app.py               # 路由（项目/Agent/会话/委派/圆桌/插件/技能…）
│   ├── ollama/              # Ollama + OpenAI 兼容双后端连接器
│   ├── agent_engine/        # 委派/圆桌/工具循环
│   ├── storage/store.py     # SQLite 存储（每项目独立库）
│   └── skills_mgr/          # 本地技能管理
└── build/                   # 打包脚本与产物（不随仓库公开）
```

## 数据位置
- 应用数据：`~/.subagent/`（配置/项目/技能/插件/压缩归档/日志）
- 项目库：`~/.subagent/projects/<project-id>/`（每项目独立 SQLite）
- 独立 Agent：`~/.subagent/projects/ia-<id>/`

## 常见问题

- **换电脑迁移**：复制整个 `~/.subagent/` 目录即可。
- **技能/插件升级不丢**：它们在数据目录，不在应用包内。
- **模型僵死/任务卡住**：已内置活性超时与重试上限；也可在设置中调整并发开关。

## 许可
暂未声明许可证（No license）。如需使用/转载代码，请先联系作者确认。
