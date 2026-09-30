<p align="center">
  🌐 <a href="https://vetarai.com"><b>官网 VetarAI.com</b></a>
  ｜ <a href="https://github.com/zero11924065-dev/VetarAI/releases">下载 Download</a>
  ｜ <a href="#-常见问题">常见问题 FAQ</a>
  ｜ <a href="#-联系我--反馈">联系 Contact</a>
</p>

# VetarAI — 本地多 Agent 编排 × 知识仓库 × 工作流 × 超级工作室
# VetarAI — Local Multi-Agent Orchestration × Knowledge Warehouse × Workflow × Studio

> **算力免费，上下文昂贵。**
> VetarAI 是一款运行在本地的桌面应用：多 Agent 协作、可视化工作流、拉模式知识仓库 + 本地语义检索、多模型协作工作室。对话、知识库与项目数据全部留在你的磁盘上。
>
> **Compute is free. Context is precious.**
> VetarAI is an on-device desktop app: multi-agent collaboration, visual workflows, a pull-mode knowledge warehouse with on-device semantic retrieval, and a multi-model studio. Your chats, knowledge and project data stay on your disk.

**当前版本 / Current version：v0.7.15**（macOS · Apple Silicon · dmg · 已签名 + Apple 公证）

- 0.7.15：全原生 Swift 架构重写完成；超级工作室、应用内模型包、魔塔链接安装、CU 电脑操作等功能新增；若干问题修复。
- 0.7.15: fully rewritten in native Swift; new — Studio, in-app model packs, ModelScope link install, Computer Use; plus various fixes.

**Note: This project is developed by a Chinese team. English translations are provided immediately following each corresponding Chinese section. Full English language support will be included in a future update.**

---

## 📑 目录 / Table of Contents

| 🇨🇳 中文 | 🇺🇸 English |
|---|---|
| [下载 VetarAI](#-下载-vetarai--download-vetarai) | [Download VetarAI](#-下载-vetarai--download-vetarai) |
| [为什么做 VetarAI：痛点与解法](#-为什么做-vetarai痛点与解法) | [Why VetarAI: Pain Points & Solutions](#-为什么做-vetarai痛点与解法) |
| [✨ 0.7 新特性：超级工作室](#-07-新特性超级工作室) | [0.7 Highlights: Studio](#-07-新特性超级工作室) |
| [📦 模型包与魔塔链接安装](#-模型包与魔塔链接安装) | [Model Packs & ModelScope Install](#-模型包与魔塔链接安装) |
| [✨ 0.4 新特性：知识仓库与语义检索](#-04-新特性知识仓库与语义检索) | [0.4 Highlights: Knowledge Warehouse & Semantic Search](#-04-新特性知识仓库与语义检索) |
| [🔀 0.2 新特性：工作流（流程中心）](#-02-新特性工作流流程中心) | [0.2 Highlights: Workflow](#-02-新特性工作流流程中心) |
| [🖥 CU 电脑操作](#-cu-电脑操作) | [Computer Use](#-cu-电脑操作) |
| [核心能力一览](#-核心能力一览) | [Core Capabilities](#-核心能力一览) |
| [使用安装包（推荐）](#-使用安装包推荐普通用户) | [Install (Recommended)](#-使用安装包推荐普通用户) |
| [源码说明](#-源码说明) | [Source Notes](#-源码说明) |
| [目录结构 / 数据位置](#-目录结构) | [Structure / Data Locations](#-目录结构) |
| [常见问题](#-常见问题) | [FAQ](#-常见问题) |
| [联系 / 许可](#-联系我--反馈) | [Contact / License](#-联系我--反馈) |

---

## ⬇️ 下载 VetarAI / Download VetarAI

**[⬇️ 下载 VetarAI 0.7.15 安装包 / Download VetarAI 0.7.15 Installer](https://github.com/zero11924065-dev/VetarAI/releases/tag/v0.7.15)**

（约 31MB · macOS Apple Silicon · dmg 格式 · **已签名 + Apple 公证，首装无需额外放行** · 语义模型首次启动按需下载，安装包轻巧）
(~31MB · macOS Apple Silicon · dmg · **signed + Apple-notarized, no extra bypass needed on first launch** · the semantic model downloads on first launch, keeping the installer lean)

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
| 一个任务要多个模型各展所长 | **超级工作室**：任务拆解、多模型并行、画布便签墙，你随时插话参与（0.7） |
| 批量任务（如几百张图转文字）手动重复劳动 | **工作流**：可视化编排，循环分批 + 并行 + 失败策略，批量稳健执行（0.2+） |
| OCR 等专用小模型被"Agent 外壳"（长提示词/工具循环）逼出乱码 | **纯推理节点**：直连模型、无系统提示词、无工具列表，根治小模型幻觉 |
| 重复性的电脑操作不想自己动手 | **CU 电脑操作**：录制成宏一键回放，元素级定位（0.7） |
| 对话与知识数据不想出本机 | **本地优先**：模型、对话、知识库全在磁盘，检索与推理不经过第三方 |
| 被某个插件生态绑架 | **生态无关**：GitHub 克隆或本地路径即装即用，插件/技能逐项开关 |
| 只想用 Ollama 之外的启动器（LM Studio 等） | **推理后端可切换**：Ollama、任意 OpenAI 兼容服务，或应用内模型包 |

## 💡 Why VetarAI: Pain Points & Solutions

Running agents on local LLMs means facing a few hard realities — each generation of VetarAI exists to solve them:

| Pain Point | The VetarAI Solution |
|------|---------------|
| **Context bloat**: conversations grow long, local models have limited context, quality degrades | **Knowledge Warehouse**: check off any conversation to move it into the warehouse — fully detached from context; search it back only when needed (0.3+) |
| **Context is expensive, compute is free**: local recomputation costs nothing; a stuffed context is the real loss | **Pull-mode design**: knowledge is never auto-injected; only retrieved when you explicitly search/select, or instruct the agent to search |
| Traditional RAG guesses relevance and auto-injects — wrong guesses waste precious context | **Read-and-forget**: agent retrieval results serve only the current answer, then are discarded — never written into history |
| Keyword search can't find content that was phrased differently | **On-device semantic search**: bge-m3 INT8 tri-mode model with keyword / semantic / hybrid retrieval (0.4) |
| Complex tasks overwhelm a single agent; manual decomposition is exhausting | **Main-sub delegation + roundtable**: automatic decomposition, collaboration, structured reporting |
| One task deserves several models' strengths | **Studio**: task decomposition, multi-model parallelism, a canvas of sticky notes — jump in anytime (0.7) |
| Batch tasks (e.g., OCR hundreds of images) mean endless manual repetition | **Workflow**: visual orchestration with loop batching, parallelism, and failure policies (0.2+) |
| Small specialized models (e.g., OCR) hallucinate when wrapped in an "agent shell" | **Pure inference nodes**: direct model calls, no system prompt, no tool list |
| Repetitive computer operations you'd rather not do by hand | **Computer Use**: record once as a macro, replay with one click, element-level targeting (0.7) |
| Don't want chats and knowledge leaving your machine | **Local-first**: models, chats and knowledge all live on disk; retrieval and inference never pass through third parties |
| Held hostage by a plugin ecosystem | **Ecosystem-agnostic**: install via GitHub clone or local path; per-plugin enable/disable |
| Want a launcher other than Ollama (e.g., LM Studio) | **Switchable inference backends**: Ollama, any OpenAI-compatible service, or in-app model packs |

---

## ✨ 0.7 新特性：超级工作室

> 把一个大任务交给一组模型：拆解、并行、汇总，全程看得见、插得上话。
> Hand one big task to a team of models: decomposed, executed in parallel, summarized — visible and interruptible throughout.

- **任务拆解**：一句话需求自动拆成任务图，按依赖编排执行顺序
- **多模型并行**：不同子任务分给不同模型同时跑，各展所长
- **画布便签墙**：每个子任务的产出实时落在画布便签上，进展一目了然
- **插话参与**：运行中随时发言，你的意见会作为便签进入后续讨论
- **暂停 / 恢复 / 中断留痕**：随时暂停继续；异常中断也有标记，可从中断处再来

- **Task decomposition**: a one-line request becomes a task graph, scheduled by dependencies.
- **Multi-model parallelism**: different subtasks run on different models simultaneously.
- **Canvas sticky notes**: every subtask's output lands on the canvas in real time.
- **Jump in anytime**: speak mid-run — your words become a note that joins the discussion.
- **Pause / resume / interruption trace**: pause and resume at will; interruptions are marked, never silently lost.

## ✨ 0.7 Highlights: Studio

（English text above each Chinese paragraph / 见上段双语对照。）

---

## 📦 模型包与魔塔链接安装

- **应用内模型包**：即装即用的本地对话 / 语音模型，与 Ollama 并存、无需切换后端；切换模型自动释放上一个模型占用的内存。见 [模型包安装指南](模型包安装指南.md)
- **魔塔社区链接安装**：复制魔塔（ModelScope）社区里的模型链接粘贴进来，自动解析、下载、校验、装载；GGUF 与 MLX 两种格式都支持
- **必备模型按需下载**：语义嵌入模型（bge-m3）首次启动时按需下载，带 SHA256 校验与断点续传，安装包因此保持轻巧

- **In-app model packs**: ready-to-use local chat / speech models that coexist with Ollama — no backend switch needed; switching models frees the previous one's memory. See [模型包安装指南](模型包安装指南.md)（中文）.
- **Install via ModelScope link**: paste a model link from the ModelScope community — automatic resolve, download, checksum and load; both GGUF and MLX formats supported.
- **On-demand required models**: the semantic embedding model (bge-m3) downloads on first launch with SHA256 verification and resumable downloads, keeping the installer lean.

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
| 关键词 / Keyword | 明确的事实（搜"地球"找到"地球是圆的"） | FTS5 全文 + 中文分词 |
| 语义 / Semantic | 换述与近义（搜"这颗星球的形状"找到"地球的形状"） | bge-m3 INT8：稠密余弦 + 稀疏词权 |
| 混合 / Hybrid（默认） | 两者都要，结果最全 | 两路结果融合排序 |

### 🤖 Agent 主动检索 · 读完即忘 / Agent-Initiated Search · Read-and-Forget

你可以直接对 Agent 说"检索知识库里关于 XX 的内容"。Agent 调用检索工具取回知识、用于当轮回答——**回答完成后，检索内容不会留在对话上下文里**。上下文只在真正需要时才被占用。

Just tell the agent: "search the knowledge base for X." The agent retrieves the knowledge, answers the current turn — **and the retrieved content never stays in the conversation context**. Context is spent only where it truly matters.

> 📦 **语义模型按需下载**：bge-m3 ONNX INT8（约 544MB，MIT 协议）首次启动时下载，纯本地 CPU 推理，不联网。
> 📦 **Semantic model on demand**: bge-m3 ONNX INT8 (~544MB, MIT license) downloads on first launch — pure local CPU inference, no network.

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

## 🖥 CU 电脑操作

- **宏录制 / 回放**：把你的键鼠操作录成宏，一键回放；适合重复的界面操作
- **元素级定位**：优先按界面元素命中，命中不了再退回坐标，命中率可在面板查看
- **权限引导**：辅助功能 / 屏幕录制 / 输入监控三权限带中文分步引导

- **Macro record & replay**: record your keyboard/mouse actions as a macro and replay with one click.
- **Element-level targeting**: hits UI elements first, falls back to coordinates; hit-rate stats visible in the panel.
- **Permission guidance**: step-by-step Chinese guidance for Accessibility / Screen Recording / Input Monitoring permissions.

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

- Token 用量实时显示（千分位格式化）+ 溢出预警 + 智能压缩（归档留痕）
- 多模态入流：图片直接走视觉通道（OCR / 识图）
- 知识 / 记忆 / 技能三层体系，按项目独立启用

- Real-time token usage display (with thousand separators) + overflow warnings + smart compression (archived with a trace)
- Multimodal ingestion: images flow directly through the visual channel (OCR / recognition)
- Three-tier knowledge / memory / skills, enabled independently per project

### 稳健性 / Robustness

- 委派活性超时（防模型僵死无限等待）+ 相同任务去重 + 重试上限
- 网络守卫：境内直连、境外可选代理、失败熔断，防无代理空转
- 系统目录授权制：Agent 删写系统/应用目录需单次确认
- 下载链自愈：瞬时断线自动同源重试，断点续传 + SHA256 校验

- Delegation liveness timeout + task deduplication + retry limits
- Network guard: domestic direct, optional proxy for overseas, circuit breaking to prevent idle loops
- System-directory authorization: one-time confirmation for agent writes/deletes in sensitive locations
- Self-healing downloads: automatic same-source retry on transient drops, resumable downloads + SHA256 verification

### 可扩展 / Extensible

- **推理后端自由切换**：Ollama（默认）、任意 OpenAI 兼容服务（LM Studio / llama.cpp / vLLM / 远程中转，支持 API Key）、或应用内模型包
- **插件系统**：GitHub 克隆或本地路径安装，钩子手动触发，逐项启用/禁用，支持备注
- **本地技能**：SKILL.md 技能包，按需读取

- **Switchable inference backends**: Ollama (default), any OpenAI-compatible service (LM Studio / llama.cpp / vLLM / remote relay, API Key supported), or in-app model packs
- **Plugin system**: install via GitHub clone or local path; manual hook triggers; per-plugin enable/disable; notes supported
- **Local skills**: SKILL.md skill packs, loaded on demand

### 体验细节 / Quality of Life

- 账户体系：邮箱验证码登录，设置与状态随账号走
- 自动更新：应用内检查更新，下载安装重启一条线
- 深色模式、窗口自适应布局、窄窗自动折叠侧栏
- 意见反馈：应用内提交，可附截图与日志

- Accounts: email code sign-in; settings and state follow your account
- Auto-update: check, download, install and relaunch in one flow
- Dark mode, adaptive layout, auto-collapsing sidebars on narrow windows
- Feedback: submit in-app, with screenshots and logs attached

---

## 🚀 使用安装包（推荐普通用户）

1. 下载 `VetarAI-0.7.15.dmg`，双击挂载
2. 把 **VetarAI** 拖入 **Applications** 文件夹
3. 从启动台打开（已签名 + Apple 公证，无需额外放行）

**准备本地模型**：需本机运行 **Ollama** 并拉取模型（如 `ollama pull qwen3.8`）；或直接使用应用内模型包（设置 → 模型包，即装即用）。想用 LM Studio 等其他启动器？设置 → 推理后端 → 选"OpenAI 兼容"，填入启动器地址即可。

## 🚀 Install (Recommended)

1. Download `VetarAI-0.7.15.dmg` and double-click to mount
2. Drag **VetarAI** into **Applications**
3. Open from Launchpad (signed + Apple-notarized, no extra bypass needed)

**Prepare local models**: run **Ollama** locally and pull a model (e.g., `ollama pull qwen3.8`); or just use in-app model packs (Settings → Model Packs, ready to use). Prefer LM Studio or another launcher? Settings → Inference Backend → choose "OpenAI Compatible" and enter the launcher's address.

---

## 📖 源码说明

本仓库为 VetarAI 的**开源子集快照**（GPL-3.0），覆盖多 Agent 编排、知识仓库、工作流、CU 电脑操作、模型管理等主体功能源码；部分模块与打包发布链未随仓库公开，因此源码不可独立构建为完整应用。完整应用请使用[安装包](https://github.com/zero11924065-dev/VetarAI/releases)。

## 📖 Source Notes

This repository is an **open-source subset snapshot** of VetarAI (GPL-3.0), covering the main functional sources — multi-agent orchestration, knowledge warehouse, workflows, Computer Use, model management, and more. Some modules and the packaging/release pipeline are not published with this repo, so the sources cannot build the complete app standalone. For the full app, use the [installer](https://github.com/zero11924065-dev/VetarAI/releases).

---

## 🗂 目录结构

```
VetarAI/
├── Package.swift              # SwiftPM 清单
├── Sources/VetarAINative/
│   ├── App/                   # 应用入口 / 装配 / 日志 / 版本
│   ├── Core/
│   │   ├── Auth/              # 账户登录
│   │   ├── NativeCore/        # 原生内核：Agent 引擎 / 委派 / 圆桌 / 工作流 / 知识库 /
│   │   │                      #   CU 电脑操作 / 模型下载与装载 / 文档生成 / SQLite 存储
│   │   ├── Network/           # 网络层
│   │   └── SSE/               # 流式事件解析
│   ├── Panels/                # 各功能面板（会话 / 工作流 / 知识 / 模型包 / 插件 / 圆桌 / CU 宏…）
│   └── UI/                    # 导航 / 组件 / 主题
├── Packages/VetarOOXML/       # 自研 OOXML 文档生成（docx / pptx / xlsx）
├── Resources/                 # 协议文案 / 必备模型清单
├── Tests/                     # XCTest（开源子集配套）
└── assets/                    # 应用图标
```

## 🗂 Directory Structure

```
VetarAI/
├── Package.swift              # SwiftPM manifest
├── Sources/VetarAINative/
│   ├── App/                   # App entry / assembly / logging / version
│   ├── Core/
│   │   ├── Auth/              # Account sign-in
│   │   ├── NativeCore/        # Native kernel: agent engine / delegation / roundtable /
│   │   │                      #   workflow / knowledge / Computer Use / model download
│   │   │                      #   & loading / document generation / SQLite storage
│   │   ├── Network/           # Networking layer
│   │   └── SSE/               # Server-sent events parsing
│   ├── Panels/                # Feature panels (chat / workflow / knowledge / model packs /
│   │                          #   plugins / roundtable / CU macros…)
│   └── UI/                    # Navigation / components / theme
├── Packages/VetarOOXML/       # In-house OOXML document generation (docx / pptx / xlsx)
├── Resources/                 # Agreement texts / required-models manifest
├── Tests/                     # XCTest (for the open-source subset)
└── assets/                    # App icon
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
- **语义检索要多大开销**：嵌入模型约 544MB，首次启动按需下载；首次编码约 0.5 秒加载，单句编码毫秒级，纯 CPU。
- **知识仓库和"设置里的知识库"是一回事吗**：不是。知识仓库是拉模式（手动转移、显式检索、永不自动注入）；设置内的知识/记忆是推模式（按项目自动注入系统提示词）。
- **模型僵死/任务卡住**：已内置活性超时与重试上限；并发开关可在设置中调整。
- **技能/插件升级不丢**：它们在数据目录，不在应用包内。
- **下载模型中断了怎么办**：断点续传 + 瞬时断线自动重试 + SHA256 校验，网络恢复后续传即可。

## ❓ FAQ

- **Migrating to a new computer**: copy the entire `~/.subagent/` directory plus your project folders (project knowledge travels with each project folder).
- **Semantic search overhead**: the ~544MB embedding model downloads on first launch; first encode loads in ~0.5s, per-sentence encoding is milliseconds, pure CPU.
- **Is the knowledge warehouse the same as "Knowledge" in Settings?** No. The warehouse is pull-mode (manual transfer, explicit retrieval, never auto-injected); the knowledge/memory in Settings is push-mode (auto-injected into system prompts per project).
- **Model hangs / stuck tasks**: liveness timeouts and retry limits are built in; concurrency can be tuned in Settings.
- **Skills/plugins survive upgrades**: they live in the data directory, not the app bundle.
- **Interrupted model download**: resumable downloads + automatic retry on transient drops + SHA256 verification — just continue when the network is back.

---

## 📮 联系我 / 反馈

如果你在使用中遇到任何问题，或者有更好的建议，欢迎随时联系我！
If you encounter any issues or have suggestions, feel free to reach out!

- **官网 / Website**：[VetarAI.com](https://vetarai.com)
- **微信 / WeChat**：ISEEVetar
- **邮箱 / Email**：zero11924065@foxmail.com
- **抖音 / Douyin**：VidjeliSteVetar

---

## 📄 许可

本项目采用 **[GNU GPL v3.0](https://www.gnu.org/licenses/gpl-3.0.html)** 开源协议。
你可以自由使用、学习、修改和分发本软件，但**分发修改后的版本时必须同样以 GPL v3.0 开源，并保留版权声明与许可文件**。完整条款见仓库根目录的 `LICENSE` 文件，每个源代码文件头部也附有许可声明。

## 📄 License

This project is licensed under the **[GNU GPL v3.0](https://www.gnu.org/licenses/gpl-3.0.html)**.
You are free to use, study, modify and distribute this software, but **any distributed modified version must likewise be released under GPL v3.0 with copyright notices and license preserved**. See the `LICENSE` file at the repository root for full terms; each source file also carries a license header.

> 注 / Note：按需下载的语义模型 bge-m3 ONNX INT8 为 MIT 协议，其许可条款独立于本项目。
> The semantic model downloaded on demand (bge-m3 ONNX INT8) is MIT-licensed; its terms apply independently of this project.
