# VetarAI — 本地多 Agent 编排 × 知识仓库 × 工作流
# VetarAI — Local Multi-Agent Orchestration × Knowledge Warehouse × Workflow

> **算力免费，上下文昂贵。**
> VetarAI 是一款 100% 本地运行的桌面应用：多 Agent 协作、可视化工作流、拉模式知识仓库 + 本地语义检索，全部数据留在你的磁盘上，不依赖任何云服务。
>
> **Compute is free. Context is precious.**
> VetarAI is a 100% local desktop app: multi-agent collaboration, visual workflows, a pull-mode knowledge warehouse with on-device semantic retrieval. All data stays on your disk — zero dependency on any cloud service.

**当前版本 / Current version：0.4.1**（macOS · Apple Silicon）

**Note: This project is developed by a Chinese team. English translations are provided immediately following each corresponding Chinese section. Full English language support will be included in a future update.**

---

## 📑 目录 / Table of Contents

| 🇨🇳 中文 | 🇺🇸 English |
|---|---|
| [下载 VetarAI](#-下载-vetarai--download-vetarai) | [Download VetarAI](#-下载-vetarai--download-vetarai) |
| [为什么做 VetarAI：痛点与解法](#-为什么做-vetarai痛点与解法) | [Why VetarAI: Pain Points & Solutions](#-为什么做-vetarai痛点与解法) |
| [✨ 0.4 新特性：知识仓库与语义检索](#-04-新特性知识仓库与语义检索) | [0.4 Highlights: Knowledge Warehouse & Semantic Search](#-04-新特性知识仓库与语义检索) |
| [🔀 0.2 新特性：工作流（流程中心）](#-02-新特性工作流流程中心) | [0.2 Highlights: Workflow](#-02-新特性工作流流程中心) |
| [核心能力一览](#-核心能力一览) | [Core Capabilities](#-核心能力一览) |
| [使用安装包（推荐）](#-使用安装包推荐普通用户) | [Install (Recommended)](#-使用安装包推荐普通用户) |
| [快速启动（开发模式）](#-快速启动开发模式) | [Quick Start (Dev Mode)](#-快速启动开发模式) |
| [目录结构 / 数据位置](#-目录结构) | [Structure / Data Locations](#-目录结构) |
| [常见问题](#-常见问题) | [FAQ](#-常见问题) |
| [联系 / 许可](#-联系我--反馈) | [Contact / License](#-联系我--反馈) |

---

## ⬇️ 下载 VetarAI / Download VetarAI

**[⬇️ 下载 VetarAI 0.4.1 安装包 / Download VetarAI 0.4.1 Installer](https://github.com/zero11924065-dev/VetarAI/releases/tag/v0.4.1)**

（577MB · macOS Apple Silicon · dmg 格式 · **内置 bge-m3 语义嵌入模型，安装即用，无需额外下载**）
(577MB · macOS Apple Silicon · dmg · **bge-m3 semantic embedding model is bundled — works out of the box, no extra download needed**)

---

## 💡 为什么做 VetarAI：痛点与解法

用本地大模型跑 Agent，绕不开这几个现实问题——这正是 VetarAI 每一代版本要解决的事：

| 痛点 | VetarAI 的解法 |
|------|---------------|
| **上下文膨胀**：对话越聊越长，本地模型上下文有限，越聊越蠢 | **知识仓库**：随时把对话勾选移入仓库，彻底脱离上下文；需要时再搜索取回（0.3+） |
| **上下文很贵，算力却免费**：本地重复计算不花钱，塞满上下文才是真损失 | **拉模式设计**：知识永不自动注入；由你显式搜索/勾选，或明确指令 Agent 检索 |
| 传统 RAG 自动猜测相关性、自动注入，猜错就白白浪费上下文 | **读完即忘**：Agent 检索结果只用于当轮回答，答完即弃，不写入对话历史 |
| 关键词搜索找不到"换了个说法"的内容 | **本地语义检索**：bge-m3 INT8 三合一模型，关键词 / 语义 / 混合三种模式（0.4） |
| 复杂任务单 Agent 搞不定，手动拆分太累 | **主-子委派 + 圆桌讨论**：自动拆解、协作、交卷汇报 |
| 批量任务（如几百张图转文字）手动重复劳动 | **工作流**：可视化编排，循环分批 + 并行 + 失败策略，批量稳健执行（0.2+） |
| OCR 等专用小模型被"Agent 外壳"（长提示词/工具循环）逼出乱码 | **纯推理节点**：直连模型、无系统提示词、无工具列表，根治小模型幻觉 |
| Agent 工具绑定云服务商，数据外泄风险 | **100% 本地**：模型、对话、知识库全在磁盘，除用户主动搜索外不联网 |
| 被某个插件生态绑架 | **生态无关**：GitHub 克隆或本地路径即装即用，插件/技能逐项开关 |
| 只想用 Ollama 之外的启动器（LM Studio 等） | **推理后端可切换**：Ollama 或任意 OpenAI 兼容服务 |

## 💡 Why VetarAI: Pain Points & Solutions

Running agents on local LLMs means facing a few hard realities — each generation of VetarAI exists to solve them:

| Pain Point | The VetarAI Solution |
|------|---------------|
| **Context bloat**: conversations grow long, local models have limited context, quality degrades | **Knowledge Warehouse**: check off any conversation to move it into the warehouse — fully detached from context; search it back only when needed (0.3+) |
| **Context is expensive, compute is free**: local recomputation costs nothing; a stuffed context is the real loss | **Pull-mode design**: knowledge is never auto-injected; only retrieved when you explicitly search/select, or instruct the agent to search |
| Traditional RAG guesses relevance and auto-injects — wrong guesses waste precious context | **Read-and-forget**: agent retrieval results serve only the current answer, then are discarded — never written into history |
| Keyword search can't find content that was phrased differently | **On-device semantic search**: bge-m3 INT8 tri-mode model with keyword / semantic / hybrid retrieval (0.4) |
| Complex tasks overwhelm a single agent; manual decomposition is exhausting | **Main-sub delegation + roundtable**: automatic decomposition, collaboration, structured reporting |
| Batch tasks (e.g., OCR hundreds of images) mean endless manual repetition | **Workflow**: visual orchestration with loop batching, parallelism, and failure policies (0.2+) |
| Small specialized models (e.g., OCR) hallucinate when wrapped in an "agent shell" | **Pure inference nodes**: direct model calls, no system prompt, no tool list |
| Agent tools tied to cloud providers risk data leakage | **100% local**: models, chats, knowledge all on disk; no network except user-initiated search |
| Held hostage by a plugin ecosystem | **Ecosystem-agnostic**: install via GitHub clone or local path; per-plugin enable/disable |
| Want a launcher other than Ollama (e.g., LM Studio) | **Switchable inference backends**: Ollama or any OpenAI-compatible service |

---

## ✨ 0.4 新特性：知识仓库与语义检索

> 这是 VetarAI 的旗舰模块——为"本地模型上下文有限"而生的完整解法。
> This is VetarAI's flagship module — a complete answer to the limited context of local models.

### 📚 知识仓库（拉模式）/ Knowledge Warehouse (Pull Mode)

- **移入即脱离**：在会话中勾选消息 → 移入知识仓库，消息转为独立 `.md` 文件永久保存，并从模型上下文中彻底移除
- **两个作用域**：项目知识存在项目文件夹的 `知识库/`（Finder 直接可见、随项目走）；全局知识存应用数据目录（跨项目复用）
- **永不自动注入**：与常见 RAG 相反，仓库内容只在你显式搜索/勾选，或明确指令 Agent 检索时才被读取
- **文件即本体**：每条知识就是一个 Markdown 文件，你可以随时在 Finder 里直接阅读、编辑、备份；删除文件，索引自动对账清理

- **Transfer to detach**: select messages in a chat → move them into the warehouse. They become standalone `.md` files, permanently saved and fully removed from the model's context.
- **Two scopes**: project knowledge lives in the project folder's `知识库/` (visible in Finder, travels with the project); global knowledge lives in the app data directory (reusable across projects).
- **Never auto-injected**: unlike typical RAG, warehouse content is only read when you explicitly search/select, or instruct the agent to search.
- **Files are the source of truth**: every entry is a plain Markdown file you can read, edit, or back up in Finder; delete a file and the index reconciles automatically.

### 🔍 三路检索 / Three-Way Retrieval

| 模式 / Mode | 适用 / Best for | 原理 / How |
|---|---|---|
| 关键词 / Keyword | 明确的事实（搜"地球"找到"地球是圆的"） | FTS5 全文 + jieba 中文分词 |
| 语义 / Semantic | 换述与近义（搜"这颗星球的形状"找到"地球的形状"） | bge-m3 INT8：稠密余弦 + 稀疏词权 |
| 混合 / Hybrid（默认） | 两者都要，结果最全 | 两路结果融合排序 |

### 🤖 Agent 主动检索 · 读完即忘 / Agent-Initiated Search · Read-and-Forget

你可以直接对 Agent 说"检索知识库里关于 XX 的内容"。Agent 调用检索工具取回知识、用于当轮回答——**回答完成后，检索内容不会留在对话上下文里**。上下文只为真正需要的东西付费。

Just tell the agent: "search the knowledge base for X." The agent retrieves the knowledge, answers the current turn — **and the retrieved content never stays in the conversation context**. You pay context only for what truly matters.

> 📦 **语义模型已内置**：bge-m3 ONNX INT8（544MB，MIT 协议）随安装包附带，纯本地 CPU 推理，不联网。
> 📦 **Semantic model bundled**: bge-m3 ONNX INT8 (544MB, MIT license) ships inside the installer — pure local CPU inference, no network.

---

## 🔀 0.2 新特性：工作流（流程中心）

> 把重复的多步任务变成一条可复用的流水线。
> Turn repetitive multi-step tasks into a reusable pipeline.

- **可视化编排**：节点 + 连线，支持推理、工具、条件分支、并行、循环、人工审批、文件输入/读取/输出、文本输出、变量赋值、代码执行、消息回复等节点类型
- **批量稳健**：循环节点支持分批大小（如一次 2–3 张图）、失败策略（中止/跳过）、批间等待，适合大批量推理
- **纯推理节点**：直连模型，不带系统提示词与工具列表——OCR 等专用小模型不再被"Agent 外壳"逼出乱码
- **模型自动调度**：切换模型先卸载旧模型再加载，全程不浪费内存；结束即卸载
- **人工审批节点**：流程可停在某一步等你确认，再继续执行

- **Visual orchestration**: nodes + edges, supporting inference, tools, conditions, parallelism, loops, human approval, file input/read/output, text output, variable assignment, code execution, and reply nodes.
- **Robust batching**: loop nodes support batch size (e.g., 2–3 images per batch), failure policies (abort/skip), and inter-batch waits — built for high-volume inference.
- **Pure inference nodes**: direct model calls without system prompts or tool lists — specialized small models (e.g., OCR) no longer hallucinate inside an "agent shell."
- **Automatic model scheduling**: switching models unloads the previous one first; everything unloads when the workflow ends.
- **Human approval nodes**: a workflow can pause at any step, waiting for your confirmation.

---

## 🧩 核心能力一览

### 多 Agent 协作 / Multi-Agent Collaboration

- **主-子委派**：主 Agent 自动拆分任务并委派给子 Agent；子 Agent 独立执行后按固定契约交卷；图片可直传子 Agent。失败自动追问一次，仍失败标记异常，不阻塞主流程
- **圆桌讨论**：多个 Agent 围绕议题共享讨论纪要，用户或 AI 主持，结束权始终在你手里
- **独立 Agent**：与项目平级的一等公民，删项目不影响它
- **工作组导出**：一键导出项目 + Agent + 会话 + 任务队列 + 圆桌的完整 JSON 快照

- **Main-sub delegation**: the main agent decomposes and delegates tasks; sub-agents execute independently and submit results via a fixed contract; images can be passed directly. One auto-retry on failure; persistent failures are flagged without blocking.
- **Roundtable**: multiple agents discuss a topic with shared minutes; hosted by user or AI — you always control when it ends.
- **Independent agents**: first-class citizens on par with projects.
- **Workgroup export**: one-click JSON snapshot of project + agents + sessions + task queue + roundtables.

### 上下文管理 / Context Management

- Token 用量实时估算 + 溢出预警 + 智能压缩（归档留痕）
- 多模态入流：图片直接走视觉通道（OCR / 识图）
- 知识 / 记忆 / 技能三层体系，按项目独立启用

- Real-time token estimation + overflow warnings + smart compression (archived with a trace)
- Multimodal ingestion: images flow directly through the visual channel (OCR / recognition)
- Three-tier knowledge / memory / skills, enabled independently per project

### 稳健性 / Robustness

- 委派活性超时（防模型僵死无限等待）+ 相同任务去重 + 重试上限
- 网络守卫：境内直连、境外可选代理、失败熔断，防无代理空转
- 系统目录授权制：Agent 删写系统/应用目录需单次确认

- Delegation liveness timeout + task deduplication + retry limits
- Network guard: domestic direct, optional proxy for overseas, circuit breaking to prevent idle loops
- System-directory authorization: one-time confirmation for agent writes/deletes in sensitive locations

### 可扩展 / Extensible

- **推理后端自由切换**：Ollama（默认）或任意 OpenAI 兼容服务（LM Studio / llama.cpp / vLLM / 远程中转，支持 API Key）
- **插件系统**：GitHub 克隆或本地路径安装，钩子手动触发，逐项启用/禁用，支持备注
- **本地技能**：SKILL.md 技能包，按需读取

- **Switchable inference backends**: Ollama (default) or any OpenAI-compatible service (LM Studio / llama.cpp / vLLM / remote relay, API Key supported)
- **Plugin system**: install via GitHub clone or local path; manual hook triggers; per-plugin enable/disable; notes supported
- **Local skills**: SKILL.md skill packs, loaded on demand

---

## 🚀 使用安装包（推荐普通用户）

1. 下载 `VetarAI-0.4.1-arm64.dmg`，双击挂载
2. 把 **VetarAI** 拖入 **Applications** 文件夹
3. 从启动台打开

> 首装因未签名可能提示"无法验证开发者"：右键 → 打开；或在终端执行 `xattr -cr /Applications/VetarAI.app`

**准备本地模型**：需本机运行 **Ollama** 并拉取模型（如 `ollama pull qwen3.8`）。想用 LM Studio 等其他启动器？设置 → 推理后端 → 选"OpenAI 兼容"，填入启动器地址即可。

## 🚀 Install (Recommended)

1. Download `VetarAI-0.4.1-arm64.dmg` and double-click to mount
2. Drag **VetarAI** into **Applications**
3. Open from Launchpad

> First launch may show an "unidentified developer" warning (the app is unsigned): right-click → Open, or run `xattr -cr /Applications/VetarAI.app` in Terminal.

**Prepare local models**: run **Ollama** locally and pull a model (e.g., `ollama pull qwen3.8`). Prefer LM Studio or another launcher? Settings → Inference Backend → choose "OpenAI Compatible" and enter the launcher's address.

---

## 🛠 快速启动（开发模式）

### 1. 安装前端依赖 / Install frontend dependencies
```bash
cd renderer
npm install
```

### 2. 安装 Python 侧车依赖 / Install Python sidecar dependencies
```bash
cd ../sidecar
python3 -m venv .venv
.venv/bin/pip install fastapi uvicorn httpx pydantic pypdf python-docx openpyxl jieba onnxruntime tokenizers
```

### 3. 启动应用 / Start the app
```bash
cd ..
npm start
```
应用启动时会自动拉起 Python 侧车（默认 `http://127.0.0.1:8765`）。
The app auto-launches the Python sidecar (default `http://127.0.0.1:8765`).

### 4. 准备本地模型 / Prepare local models
需本机运行 **Ollama** 并拉取模型。应用默认通过 `http://localhost:11434` 连接，可在 设置 → 推理后端 修改。
Run **Ollama** locally and pull models. The app connects to `http://localhost:11434` by default — change it in Settings → Inference Backend.

---

## 🗂 目录结构

```
subagent/
├── main.js                  # Electron 主进程（窗口/菜单/侧车拉起）
├── splash.html              # 启动加载页
├── renderer/                # React 前端 (Vite + TS)
│   └── src/
│       ├── App.tsx          # 根组件（一级导航 + 左栏 + 对话/圆桌/工作流）
│       └── panels/          # 各面板（对话/知识仓库/工作流/设置/推理/插件…）
├── sidecar/                 # Python 侧车 (FastAPI)
│   ├── app.py               # 路由（项目/Agent/会话/委派/圆桌/知识仓库/工作流…）
│   ├── ollama/              # Ollama + OpenAI 兼容双后端连接器
│   ├── agent_engine/        # 委派/圆桌/工具循环（含知识检索工具）
│   ├── knowledge/           # 知识仓库：存储/索引/嵌入/混合检索
│   ├── workflow/            # 工作流引擎（节点执行/事件流）
│   ├── storage/store.py     # SQLite 存储（每项目独立库）
│   └── skills_mgr/          # 本地技能管理
└── build/                   # 打包脚本与产物（不随仓库公开）
```

## 🗂 Directory Structure

```
subagent/
├── main.js                  # Electron main process (window/menu/sidecar launch)
├── splash.html              # Splash screen
├── renderer/                # React frontend (Vite + TS)
│   └── src/
│       ├── App.tsx          # Root component (nav + sidebar + chat/roundtable/workflow)
│       └── panels/          # Panels (chat/warehouse/workflow/settings/inference/plugins…)
├── sidecar/                 # Python sidecar (FastAPI)
│   ├── app.py               # Routes (projects/agents/sessions/delegation/roundtable/warehouse/workflow…)
│   ├── ollama/              # Dual-backend connector: Ollama + OpenAI-compatible
│   ├── agent_engine/        # Delegation/roundtable/tool loop (incl. knowledge search tool)
│   ├── knowledge/           # Knowledge warehouse: storage/index/embedding/hybrid retrieval
│   ├── workflow/            # Workflow engine (node execution/event stream)
│   ├── storage/store.py     # SQLite storage (one database per project)
│   └── skills_mgr/          # Local skills manager
└── build/                   # Build scripts and artifacts (not included in the public repo)
```

---

## 📍 数据位置

- **应用数据**：`~/.subagent/`（配置 / 项目 / 技能 / 插件 / 知识索引 / 语义模型缓存 / 日志）
- **项目库**：`~/.subagent/projects/<project-id>/`（每项目独立 SQLite）
- **项目知识**：`<项目工作目录>/知识库/`（.md 文件，Finder 可见）
- **全局知识**：`~/.subagent/knowledge/global/`

## 📍 Data Locations

- **App data**: `~/.subagent/` (config / projects / skills / plugins / knowledge index / semantic model cache / logs)
- **Project databases**: `~/.subagent/projects/<project-id>/` (independent SQLite per project)
- **Project knowledge**: `<project working dir>/知识库/` (.md files, visible in Finder)
- **Global knowledge**: `~/.subagent/knowledge/global/`

---

## ❓ 常见问题

- **换电脑迁移**：复制整个 `~/.subagent/` 目录 + 各项目文件夹即可（项目知识随项目文件夹走）。
- **语义检索要多大开销**：嵌入模型 544MB 已内置；首次编码约 0.5 秒加载，单句编码毫秒级，纯 CPU。
- **知识仓库和"设置里的知识库"是一回事吗**：不是。知识仓库是拉模式（手动转移、显式检索、永不自动注入）；设置内的知识/记忆是推模式（按项目自动注入系统提示词）。
- **模型僵死/任务卡住**：已内置活性超时与重试上限；并发开关可在设置中调整。
- **技能/插件升级不丢**：它们在数据目录，不在应用包内。

## ❓ FAQ

- **Migrating to a new computer**: copy the entire `~/.subagent/` directory plus your project folders (project knowledge travels with each project folder).
- **Semantic search overhead**: the 544MB embedding model is bundled; first encode loads in ~0.5s, per-sentence encoding is milliseconds, pure CPU.
- **Is the knowledge warehouse the same as "Knowledge" in Settings?** No. The warehouse is pull-mode (manual transfer, explicit retrieval, never auto-injected); the knowledge/memory in Settings is push-mode (auto-injected into system prompts per project).
- **Model hangs / stuck tasks**: liveness timeouts and retry limits are built in; concurrency can be tuned in Settings.
- **Skills/plugins survive upgrades**: they live in the data directory, not the app bundle.

---

## 📮 联系我 / 反馈

如果你在使用中遇到任何问题，或者有更好的建议，欢迎随时联系我！
If you encounter any issues or have suggestions, feel free to reach out!

- **微信 / WeChat**：ISEEVetar
- **邮箱 / Email**：zero11924065@foxmail.com
- **抖音 / Douyin**：VidjeliSteVetar

---

## 📄 许可

暂未声明许可证（No license）。如需使用/转载代码，请先联系作者确认。

## 📄 License

No license declared. Please contact the author for permission before using or redistributing the code.
