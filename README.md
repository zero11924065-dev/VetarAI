# VetarAI — Ollama 驱动的本地多 Agent 编排桌面应用

> 一款零生态依赖的 Agent 工具 | An ecosystem-agnostic Agent tool.
>VetarAI 是一款运行在本地的桌面应用，让你在同一台 Mac 上自由创建多个隔离项目，每个项目内动态编排主 Agent 与子 Agent。支持任务委派、多 Agent 圆桌讨论、多模态识图，全部数据保存在本地，不依赖任何云端服务。
<br>VetarAI is a local desktop application that lets you freely create multiple isolated projects on the same Mac, dynamically orchestrating main and sub-agents within each project. It supports task delegation, multi-agent roundtable discussions, and multimodal image recognition. All data is stored locally with zero dependency on any cloud services.
<br>当前版本：0.4.0（macOS · Apple Silicon）

**Note: This project is developed by a Chinese team. English translations will be provided immediately following each corresponding Chinese section. Full English language support is not yet available and will be included in a future update.**

## 📑 目录 / Table of Contents

🇨🇳 **中文目录**
- [下载 VetarAI](#下载vetaraidownload-vetarai)
- [为什么选择 VetarAI？](#为什么选择-vetarai)
- [核心能力一览](#核心能力一览)
- [快速启动（开发模式）](#快速启动开发模式)
- [使用安装包（推荐普通用户）](#使用安装包推荐普通用户)
- [目录结构](#目录结构)
- [数据位置](#数据位置)
- [常见问题](#常见问题)
- [联系我 / 反馈](#联系我--反馈)
- [许可](#许可)
---
🇺🇸 **English Contents**
- [Download VetarAI](#下载vetaraidownload-vetarai)
- [Why Choose VetarAI?](#why-choose-vetarai)
- [Core Capabilities Overview](#core-capabilities-overview)
- [Quick Start (Development Mode)](#quick-start-development-mode)
- [Using the Installer (Recommended)](#using-the-installer-recommended)
- [Directory Structure](#directory-structure)
- [Data Locations](#data-locations)
- [FAQ](#faq)
- [Contact / Feedback](#contact--feedback)
- [License](#license)

## 下载VetarAI/Download VetarAI
**⬇️ [下载 VetarAI 0.4.0 安装包](https://github.com/zero11924065-dev/VetarAI/releases/tag/v0.4.0)** **⬇️ [Download VetarAI 0.4.0 Installer](https://github.com/zero11924065-dev/VetarAI/releases/tag/v0.4.0)**
<br>（577MB · macOS Apple Silicon · dmg 格式，内置语义模型）

</div>

**如何安装**：下载 `VetarAI-0.4.0-arm64.dmg` → 双击挂载 → 把 VetarAI 拖入「应用程序」文件夹 → 从启动台打开。
> 首装因未签名可能提示"无法验证开发者"：右键 → 打开，或终端执行 `xattr -cr /Applications/VetarAI.app`。
<br>How to Install: Download VetarAI-0.4.0-arm64.dmg → Double-click to mount → Drag VetarAI into the "Applications" folder → Open from Launchpad.
> For first-time installations, you may see an "Unable to verify developer" warning because the app is unsigned. To bypass this, right-click the app and select "Open," or run the following command in Terminal: xattr -cr /Applications/VetarAI.app.

VetarAI 是一个运行在本地的桌面应用，让你在应用内自由创建/管理多个**项目**，每个项目内动态创建**主 Agent** 与**子 Agent**。各 Agent 独立运行、独立上下文，通过 Ollama 调用本地大模型对话，并支持把大任务**委派**给子 Agent、让多个 Agent **圆桌讨论**。全部数据保存在本地，不依赖任何云端服务。
<br>VetarAI is a local desktop application that allows you to freely create and manage multiple projects within the app, dynamically generating main agents and sub-agents within each project. Each agent operates independently with its own isolated context. By leveraging Ollama to invoke local large language models (LLMs) for conversations, it supports delegating complex tasks to sub-agents and facilitating roundtable discussions among multiple agents. All data is stored entirely locally, with zero dependency on any cloud services.

## 为什么选择 VetarAI？
| 痛点 | VetarAI 的解法 |
|------|---------------|
| Agent 工具绑定特定云服务商，数据外泄风险 |  100% 本地运行，模型/对话/知识库全在磁盘上 |
| 切换不同项目时上下文混乱 |  多项目完全隔离，独立目录、数据库、会话 |
| 复杂任务单 Agent 搞不定，手动拆分太累 |  主-子委派 + 圆桌讨论，自动拆解、协作、汇报 |
| 模型僵死/无限重试/无代理空转 |  三重防护：活性超时 + 去重重试 + 网络熔断 |
| 被某个插件生态绑架 |  生态无关设计，GitHub 克隆或本地路径即装即用 |

## Why Choose VetarAI?
| Pain Point | The VetarAI Solution |
|------|---------------|
| Agent tools tied to specific cloud providers pose data leakage risks | 100% local execution; models, conversations, and knowledge bases all reside on your disk |
| Context gets mixed up when switching between different projects | Complete isolation across multiple projects, featuring independent directories, databases, and sessions |
| Single agents struggle with complex tasks, and manual breakdown is exhausting | Main-sub delegation + roundtable discussions for automatic task decomposition, collaboration, and reporting |
| Models freeze, enter infinite retry loops, or idle without proxy | Triple protection: liveness timeout, deduplicated retries, and network circuit breaking |
| Held hostage by a specific plugin ecosystem | Ecosystem-agnostic design; ready to use instantly via GitHub clone or local path |

## 核心能力一览
### 多 Agent 协作
主-子委派：主 Agent 自动拆分任务并委派给子 Agent，子 Agent 独立执行后按固定契约"交卷"；失败自动追问一次，仍失败则标记异常，不阻塞主流程。
圆桌讨论：多个 Agent 围绕议题共享讨论纪要，支持用户/AI 主持，用户随时掌握结束权或手动停止。
独立 Agent：与项目平级的一等公民，可单独创建/删除，删除项目不影响它。
### 智能上下文管理
Token 用量实时指示 + 溢出预警 + 智能压缩归档留痕
多模态入流：图片直接走视觉通道，多模态模型可读图（OCR / 识别）
知识/记忆/技能三层体系：项目知识库、全局/项目记忆、本地技能（SKILL.md），均按项目独立启用
### 大批量任务稳健性
委派活性超时（防模型僵死无限等待）
相同任务自动去重 + 失败重试上限（防级联重试风暴）
成功后可选自动清理子 Agent，保持工作区整洁
### 核心系统目录授权制
agent删写系统目录和应用目录时需要单次授权
防止agent自行操作损坏系统环境
### 可扩展 & 可替换
推理后端自由切换：默认 Ollama，兼容任意 OpenAI API 服务（LM Studio / llama.cpp / vLLM / 远程中转，支持 API Key）
插件系统：从 GitHub 克隆或本地路径安装，钩子手动触发，逐项启用/禁用
网络守卫：境内/境外出站管控 + 失败熔断，防止无代理空转死循环

## Core Capabilities Overview
### Multi-Agent Collaboration
Main-Sub Delegation: The main agent automatically breaks down tasks and delegates them to sub-agents, which execute independently and "submit" results according to a fixed contract. If a task fails, it is automatically retried once; if it still fails, it is flagged as an exception without blocking the main workflow.
Roundtable Discussions: Multiple agents share discussion minutes on a specific topic. Discussions can be hosted by the user or AI, with the user retaining the right to end or manually stop the session at any time.
Independent Agents: First-class citizens on par with projects. They can be created or deleted individually, and deleting a project does not affect them.
### Smart Context Management
Real-time Token Indicators + Overflow Warnings + Smart Compression: Archives are kept with a complete trace.
Multimodal Ingestion: Images are processed directly through a visual channel, allowing multimodal models to read them (OCR/Recognition).
Three-Tier System (Knowledge/Memory/Skills): Project knowledge bases, global/project memory, and local skills (SKILL.md) can be enabled independently for each project.
### Robustness for High-Volume Tasks
Delegation Liveness Timeout: Prevents infinite waiting caused by frozen models.
Auto-Deduplication & Retry Limits: Identical tasks are automatically deduplicated with a maximum retry limit to prevent cascading retry storms.
Auto-Cleanup: After successful completion, sub-agents can be optionally cleaned up automatically to keep the workspace tidy.
### Core System Directory Authorization
Single-Use Authorization: Agents require one-time authorization when deleting or writing to system and application directories.
System Protection: Prevents agents from independently modifying and potentially damaging the system environment.
### Extensible & Replaceable
Flexible Inference Backends: Defaults to Ollama, but is compatible with any OpenAI API service (LM Studio / llama.cpp / vLLM / Remote Relay, with API Key support).
Plugin System: Install via GitHub clone or local path. Hooks are manually triggered, and plugins can be enabled or disabled individually.
Network Guard: Controls domestic/international outbound traffic and triggers circuit breaking upon failure to prevent infinite loops of unproxied idling.


## 快速启动（开发模式）
## Quick Start (Development Mode)

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

## Quick Start (Development Mode)
**Install Frontend Dependencies**
```bash
cd renderer
npm install
```
**Install Python Sidecar Dependencies**
```bash
cd ../sidecar
python3 -m venv .venv
.venv/bin/pip install fastapi uvicorn httpx pydantic pypdf python-docx openpyxl
```
**Start the Application**
```bash
cd ..
npm start          # 或 ./node_modules/electron/Electron.app/Contents/MacOS/Electron .
```
Upon application startup, the Python sidecar is automatically launched (defaulting to http://127.0.0.1:8765).
**Prepare Local Models**
Ollama must be running locally with the model pulled (e.g., ollama pull qwen3.8). The application connects via http://localhost:11434.

## 使用安装包（推荐普通用户）


下载 `VetarAI-<版本>-arm64.dmg`，挂载后拖入「应用程序」即可。首装因未签名可能提示"无法验证开发者"：右键 → 打开，或终端执行 `xattr -cr /Applications/VetarAI.app`。

## Installer (Recommended)
Download VetarAI-<version>-arm64.dmg, mount it, and drag the app into the "Applications" folder. On first launch, since the app is unsigned, you may see an "unidentified developer" warning: right-click the app → Open, or run xattr -cr /Applications/VetarAI.app in Terminal.

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
## Directory Structure
```
subagent/
├── main.js                  # Electron main process (window/menu/sidecar launch/about)
├── splash.html              # Splash screen
├── renderer/                # React frontend (Vite + TS)
│   └── src/
│       ├── App.tsx          # Root component (three-column layout: sidebar + chat + roundtable)
│       └── panels/          # Panels (projects/agents/chat/roundtable/settings/reasoning/plugins…)
├── sidecar/                 # Python sidecar (FastAPI)
│   ├── app.py               # Routes (projects/agents/sessions/delegation/roundtable/plugins/skills…)
│   ├── ollama/              # Dual backend connector for Ollama + OpenAI-compatible APIs
│   ├── agent_engine/        # Delegation/roundtable/tool-use loop
│   ├── storage/store.py     # SQLite storage (one database per project)
│   └── skills_mgr/          # Local skills manager
└── build/                   # Build scripts and artifacts (not included in the public repository)
```

## 数据位置
- 应用数据：`~/.subagent/`（配置/项目/技能/插件/压缩归档/日志）
- 项目库：`~/.subagent/projects/<project-id>/`（每项目独立 SQLite）
- 独立 Agent：`~/.subagent/projects/ia-<id>/`
## Data Locations
- Application Data: ~/.subagent/ (configuration/projects/skills/plugins/archives/logs)
- Project Databases: ~/.subagent/projects/<project-id>/ (independent SQLite database per project)
- Standalone Agents: ~/.subagent/projects/ia-<id>/

## 常见问题
- **换电脑迁移**：复制整个 `~/.subagent/` 目录即可。
- **技能/插件升级不丢**：它们在数据目录，不在应用包内。
- **模型僵死/任务卡住**：已内置活性超时与重试上限；也可在设置中调整并发开关。
## FAQ
- **Migrating to a new computer**: Simply copy the entire ~/.subagent/ directory.
- **Skills/plugins persist after upgrades**: They are stored in the data directory, not within the application bundle.
- **Model hangs/stuck tasks**: Built-in activity timeouts and retry limits are included; concurrency settings can also be adjusted in Settings.

## 联系我 / 反馈
如果你在使用中遇到任何问题，或者有更好的建议，欢迎随时联系我！
- **微信**：ISEEVetar
- **邮箱**：zero11924065@foxmail.com
- **抖音**：VidjeliSteVetar
## Contact / Feedback
If you encounter any issues while using this project, or if you have any suggestions, feel free to reach out to me!
- **WeChat**: ISEEVetar
- **Email**: zero11924065@foxmail.com
- **TikTok**：VidjeliSteVetar （TikTok's Chinese counterpart）

## 许可
暂未声明许可证（No license）。如需使用/转载代码，请先联系作者确认。
## License
No license declared. Please contact the author for permission before using or redistributing the code.
