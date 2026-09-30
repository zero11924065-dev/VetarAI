//
//  AppVersion.swift
//  VetarAI — Local-first multi-agent orchestration application
//  Copyright (C) 2026 zero11924065-dev
//
//  This file is part of VetarAI.
//
//  VetarAI is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  VetarAI is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with VetarAI. If not, see <https://www.gnu.org/licenses/>.
//

//  版本号唯一来源。原生线从 0.1.0 起（区别于 Electron 现状线的 0.4.x）；
//  0.5.0 跳号理由：接管 0.4.x 生产数据根（~/.subagent）后版本不得低于
//  Electron 线末版 0.4.34，避免同机共存时版本反降。
//  0.7.1：0.6.x 注册授权 + 0.7.x 超级工作室（均仅内部版本，ADR-0047）
//  联动批合并收尾的内部版；历史版本口径记录于 docs/CHANGELOG.md 与
//  docs/records/release-notes/versions.md（本文件只保留当前值）。
//  0.7.2：契约 v1.4 接入内部版——协议签署（首启门+付费弹窗+全站通用提示）、
//  检查更新（日级静默自动查+SHA256 校验下载）、用户反馈（multipart+我的反馈）、
//  SSL Pinning（锁 CA SPKI 仅 api.vetarai.com）。
//  0.7.3：VetarModel × VetarAI 接头联调内部版——三档样例（4bit/8bit/bf16）
//  全链联调通过、.vmodel MLX 推理正式化（摘「推理开发中」占位、正式可分派）、
//  mlx-swift-lm 回切 git revision 锁（3.31.4=bd4b7434）。
//  0.7.4：技术债清偿+小修批（W1~W14 十四包，明细见 versions.md 0.7.4 条目）——
//  画布库错误链/下载分块化+速率上屏/重复动作熔断/REQ-WF-016 判缺陷修/CU 命中率/
//  事件总线核销/fetchCatalog TCC 引导/reportBusy 忙守/工具组动画/装填可视化+预估/
//  委派缺口闭环/小清理五件/联调冒烟/文档债清零；收口前两条业主实测修复：
//  登录页卖点文案更正（「现有功能全部免费」→「注册即享免费功能，付费模块可 7 天试用」）、
//  工作室门控去锁标徽章改纯置灰（业主红线：不遮挡、可辨认、点击弹引导）。
//  同步点：scripts/package_app.sh 的 CFBundleShortVersionString、README、关于页。
//  0.7.5：核心模块增强批（13 包）——Wave A（全局模型平级/魔塔链接安装/CU 引导式
//  权限/关末窗即退/Cmd+Q 忙守/知识注入 on_demand/委派 busy 窗补发/登录页文案/
//  防逆向轻加固）+ 工作室阶段二形态（观测埋点/亲和调度/十项拍板）+ 阶段三开会
//  增强+KV 前缀复用 + 收口审查 1 高 3 中修复（引擎单槽淘汰/KV 世代防脏/CU 权限
//  单源/ModelScope 路径消毒）；明细见 versions.md 0.7.5 条目。
//  0.7.6：VetarModel 三方联调批（仅内部版）——W14 SDK 0.2.0（v2 容器密钥全链：
//  安装时领取进 Keychain/六类错误中文上屏/v1 行为不变）+ W1 主会话 vmodel 接
//  MLX agent-loop+REQ-INFER-011 token 真值/W3 modelsMP 并集/W5 取消传播/W6 开会
//  降级 B+弹窗/W7 开会中徽标/W8 settle 门闩/W9 KV 归因/W10 登录单发/W11 魔塔
//  编码/W12 半成品清退/W13 L1 探针做实/W2 三链核实 + 业主实测三 UI 修复（竖条
//  门控间距 DBG-175/流程手风琴动态高/切 agent 选中即随）；明细见 versions.md
//  0.7.6 条目。
//  0.7.7 实测修复批（build 14，同版本重产，2026-09-28 业主实测反馈 7 bug+1 疑问）：
//  ①委派场景切走再切回消息消失（后台流 stash 按会话分键+DB/本地合并加载，旧线
//  DBG-089 同症原生复发）②token 指示器无会话归属+恢复估算优先级颠倒 ③委派
//  sandbox_root 前端硬编码 pilot-sandbox → 交端点解析项目工作目录 ④委派子会话
//  装配漏传 authorizer 致敏感路径「无授权通道」⑤账号页本机行解绑按钮被
//  `285d20b` 翻成 !current 不渲染 ⑥CU「请求授权」静默无反应（TCC 未登记+缺
//  NSInputMonitoringUsageDescription，探测 tap 登记+打包键补齐）⑦下载瞬时
//  错误（-1005 等）判死前同源原地重试（业主日志铁证首次 3.1s 断、重试满速成）
//  ⑧账号页「激活服务器」联调区块默认隐藏（defaults 键 license.showServerConfig
//  唤出）。每 bug 均带回归钉桩（+19），明细见 versions.md 0.7.7 条目。
//  0.7.7 联调跟进批（build 15，同版本重产，2026-09-28 VetarModel 回执确认跟进）：
//  ⑨空 think 块渲染滤除（ChatTextFilter 纯函数只剥完整闭合空块，渲染前接入）
//  ⑩vmodel 加载后 1-token 静默预热（MLX 懒加载成本消化在加载阶段，消除首问
//  39s 空响应；GGUF 链 eager load 无同类问题不动）⑪清三处 0.7.3 占位已摘后的
//  陈旧注释；回归 +20，明细见 versions.md 0.7.7 条目。
//  0.7.7 生产收尾批（build 16，2026-09-28 后端任务书+契约 v1.8）：默认后端地址
//  切生产 https://api.vetarai.com/api（联调 override 通道保留）；GET /api/config
//  链接下发（AppConfigCenter：links 五键+agreementVersion、TTL 300s、静态兜底）；
//  登录页协议行/协议弹窗查看全文接真实链接；激活页「购买 / 升级」接 store
//  （null→「敬请期待」禁跳空链）；测试污染钥匙串根治（bundle 末清扫零新增）。
//  0.7.7 验收实测修复（build 17，同版本重产，2026-09-28）：生产首跑账号页
//  status 401 时错误条上屏英文 NSError 泛化串（AccountPanelView 三处
//  localizedDescription 对 struct 错误退化）——LicenseAPIError
//  .userFacingMessage 收口服务端中文 message 直展；回归 +4。
//  0.7.7 登出态 UI 簇（build 18，同版本重产，2026-09-28 业主实测三连）：
//  ①账号页未登录只给「登录账号」入口（isAuthenticated 判据+登出清陈旧
//  statusResult）②付费门 certLocked 主 CTA 改「登录账号」（激活/试用无
//  token 不可用）③AuthScaffold 可滚——激活页出口钮不再被窗高裁掉；
//  配套 showAuth 登录呈现通道+AuthFlowView 可关闭模式；回归 +2。
//  0.7.7 bge 预估失真修正（build 19，同版本重产，2026-09-28 DBG-188 结案）：
//  排查双证（curl 首段/中段 20~26 MB/s + live 探针真实下载器 25.3s 下完
//  1.13GB）——下载器无瓶颈，根因=魔塔 CDN 边缘冷缓存（业主首下已焐热）；
//  fmtRemaining 动态剩余时间替代静态「约 3 分钟」+弹窗文案诚实化；回归 +1
//  （另新增 VETAR_BGE_LIVE 门控探针 1 例默认 skip）。
//  0.7.8（build 20，2026-09-28 业主拍板）：为自动更新全链实测进位版本号——
//  更新检测只比 x.y.z 版本号不比 build（UpdateCenter.compareVersions > 0 才
//  算有更新），同版本重产（build 18→19）永不可被检测为更新；内容=0.7.7 全
//  部成果（生产切换验收+登出态 UI 簇+bge 预估修正）原样进位，无新增改动。
//  0.7.9（build 21，2026-09-29 后端合并任务书+契约 v1.10）：
//  ①购买入口双按钮（契约 v1.9）——AppConfigLinks/ResolvedLinks 增
//  storeYearly/storeLifetime 可空直达键，PurchaseEntryLogic.entry 裁决
//  （双直达可用→「买年卡」「买永久」并排；直达缺失该钮单独回退 store；
//  两直达均缺整体回退旧单按钮；三键全空「敬请期待」），激活页双模式渲染；
//  ②应用内自动更新换 Sparkle 2.x（契约 v1.10 §2.15，exact 2.10.0 与
//  VetarModel M27 同版）——SUFeedURL=updates/vetar-agent/appcast.xml +
//  SUPublicEDKey（EdDSA 私钥 account=VetarAI 只存打包机钥匙串+业主加密
//  备份）+ SUEnableAutomaticChecks=false（节奏全由 UpdateController 日级
//  门控）；CFBundleVersion 起与版本号同值（Sparkle 比较口径）；旧自研链
//  （UpdateCenter/UpdateDialogView/§2.10 端点调用）整体删除，slug 常量升
//  AppIdentity（反馈沿用）；打包链 package_app 进框架+补 rpath、sign_app
//  嵌套从内到外签、sign_update.sh 出后台三件套。
//  0.7.10（build 22，2026-09-29 契约 v1.11 真强制更新）：
//  ①全业务请求统一携带 X-App-Id: vetar-agent + X-App-Version 版本头
//  （LicenseAPIClient applyAppHeaders 一处收敛）；②最低可用版本启动阻断
//  闸门 MandatoryUpdateGate——本地缓存（UserDefaults+文件双写）纯本地判定
//  断网也阻断，全屏阻断页仅「立即更新/退出应用」，解除靠版本比较自然失效；
//  联网即刷新缓存（latest?current= 响应 null 则清缓存自愈），阻断页 60s
//  静默重试防后台误标永久锁死；③426/UPGRADE_REQUIRED 全局拦截——写缓存+
//  静态钩子接管已登录会话立即进阻断；④「立即更新」直通 Sparkle
//  （appcast 强制版本自带 criticalUpdate，Sparkle 侧零改动）。
//  服务端牙齿=426 拦截业务接口，客户端闸门防君子不防狼（契约口径）。
//  0.7.11（build 23，2026-09-29 业主实测反馈修复）：
//  默认模型/报错分析模型显示「当前不可用」假阳性根治——ollama 惯例
//  不带 tag 等价 :latest，但设置双 Picker/模型特长 isStale/聊天
//  bootstrap 四处仍是精确字符串匹配：存 qwen3.8 遇列表 qwen3.8:latest
//  即误标不可用，且 ChatViewModel bootstrap 会把 selectedModel 静默
//  换成列表第一个（功能性 bug）。新建 ModelIdentity 归一化纯函数
//  （tag 仅认最后一个 / 之后的 :，魔塔路径不误判）四处接入；归一化
//  命中保留用户原值不改写配置。NativeDelegation:1073 宽松口径
//  （同 base 任意 tag 命中）与严格口径有意不同未收编，互加交叉注释。
//  真不可用时 Picker 下给出三分支中文指引（后端断连/已移除可重装/
//  默认值保留恢复自动生效）。
//  0.7.12（build 24，2026-09-29 业主实测反馈+拍板需求）：
//  ①我的反馈按应用隔离——VetarModel 提交的反馈在 VetarAI 可见
//  （反向同病）：根因=GET /feedback/mine 契约无过滤参数、客户端
//  原样全显；修法=feedbackMine 加 ?app=<slug> query（契约只增不删
//  前向兼容，旧服务端忽略）+ 拉取后按 app_slug 本地过滤双保险，
//  后端契约 v1.12 落地即无缝切换服务端过滤。②提交反馈一键附日志
//  （业主拍板五点）：开关默认开启+文案告知「自动收集最近 3 天运行
//  日志用于定位问题，已脱敏」；LogAttachmentBuilder 收集 AppLogger
//  近 3 天 + llama-server 尾段 + environment.txt，zip 前正则脱敏
//  （邮箱/Bearer/长 token/用户路径——隐私审计全仓 grep 零直写，
//  构建器重扫兜底）；单个 deflate zip（复用 VetarOOXML.ZipWriter，
//  禁 Process）只占 1 附件槽（开启时用户附件上限 5→4 有提示）；
//  9MB 闸门新优先丢旧、单文件截头留尾附 TRUNCATED.txt；「日志已
//  附加（KB）」chip 可移除、提交失败保态成功重置。
//  0.7.13（build 25，2026-09-30 E2E 实测修复批·六修三需求+千分位）：
//  ①⋯更多菜单偶发无响应——顶栏右组 ZStack+fixedSize 整组零压缩，
//  窄窗右溢出画到命中测试界外，结构加固；②Cmd+Q 忙守失效——chat
//  流式从未登记 busy 源，已接入（studio 运行/委派流遗留登记下批）；
//  ③工作室输入框不换行无限延伸——NSTextView frame 漂移视口水平
//  切片（VPinnedScrollView 回钉）；④输入框点击无光标+系统提示音——
//  占位 label 吞击+textView 未铺满留死区（穿透类+铺满）；⑤「预计
//  还需 Xs」预估不显——原挂 ≥8s 横幅后，本地模型首 token 2–5s 永远
//  够不着，改挂「进行中 Ns」chip 单样本第 1 秒即显；⑥模型下拉选中
//  置顶重排→顺序稳定仅勾选（不再跳动）；⑦强退/崩溃后悬空 user 轮
//  合成「已中断执行」标记气泡+「重新发送」（不落库幂等）；⑧新建
//  项目默认名=所选文件夹名（重名自动加序号）；⑨我的反馈可展开
//  只读详情（契约 mine 不返 description，本机按 feedbackId 缓存
//  补齐）；⑩token 指示器千分位统一——displayText/tooltip 全数字
//  过 grouping(.automatic)，已用数与上限同格式（a73493f）。
//  回归 +35（六修三需求钉桩），全量 2336 绿/7 skip/0 fail；
//  明细见 versions.md 0.7.13 条目。
//  0.7.14（build 26，2026-09-30 ⋯菜单 razor-thin 根治）：
//  业主实测 0.7.13 复发「⋯更多菜单完全点不开」——0.7.13 F1 修的是
//  窄窗溢出假设，非业主场景（真机 1179pt 宽窗）。运行中应用 AX 命中
//  取证：⋯ 命中区仅 12×2.5pt（兄弟钮 ✓13×13/⛁11×14），vGhost 等
//  自定义 ButtonStyle 的 padding/frame 只进布局、不进命中区，命中区
//  =label 本体框架；ellipsis 字形 razor-thin，±3pt 瞄准误差即落空
//  （命中底层纯容器 AXGroup）。业主「点兄弟钮后正常/打字后复发」=
//  光标与行中心对齐效应。根治：label 内扩 22×22+contentShape
//  （vIconHitTarget，命中区=22×22；22≤vGhost 布局高 28 行高不变，
//  宽 +10/钮由左组吸收）；ChatTopBarLayout 宽估 28→42 同步；源码
//  扫描钉桩三钮必挂命中目标（AXIdentifierAuditTests 同款手法）。
//  0.7.15（build 27，2026-09-30 上线前排查 S1~S4 收口批）：
//  S1 付费墙绕过根治——门控原只挂模块竖条按钮，内容层/执行层零校验
//  （解绑后关门即白用工作室）；内容层补 paywallGated 置灰拦截 +
//  StudioEngine 注入 studioGateCheck 硬校验卡五个开工类入口。
//  S2 授权簇四修——①模型密钥链路补 pinning+X-App 头
//  （PinningDelegate.makeSession 工厂注入）②登录等值场景账号页卡死
//  （authRevision 事件计数破 Equatable 等值门）③恢复本机授权零反应
//  （probe→Bool+先清后置破陈旧等值+三路分流兜底）④解绑后付费门
//  文案误导（lastKnownPaid 缓存+「本机尚未恢复授权」第三路+恢复 CTA）。
//  S3 二修——测试宿主日志改向 tmp（三路冗余判定，生产日志止血）+
//  必备模型清单缺失一次性明示（独立键不污染首装流程）。
//  S4 四修——协议 Markdown # 加载层剥离/设备时间 formatChatTime 本地
//  化/Sparkle 本地高于线上定制措辞（SPUStandardUserDriver 子类双闸
//  拦截，比较器移植 SUStandard 口径）/工作流「输出占位」黑话改用户
//  语言；协议门加固两小项（sync 失败落日志+门开收 showAuth）。
//  回归 +30（StudioGateS1×8/LicenseS2Fix×11/S3S4Fix×11），全量 2374
//  绿/7 skip/0 fail；明细见 versions.md 0.7.15 条目。
//

import Foundation

public enum AppVersion {
    public static let current = "0.7.15"
    public static let build = "27"
    public static let phaseName = "上线前排查S1~S4收口"
    public static let appName = "VetarAI"
    /// 版权行（0.7.1 Bug 7：菜单栏标准关于弹窗 credits 唯一来源；不发版不改）
    public static let copyright = "Copyright © 2025–2026 VetarAI"
    /// 中英文介绍行（关于弹窗 credits 上两行；文案逐字沿用 Electron 线 main.js
    /// APP_TAGLINE_CN/EN——0.7.6 实测修复批业主拍板恢复原格式：
    /// 版本号 + 中文介绍 + 英文介绍 + 版权行，版本行去 phaseName 额外说明）
    public static let taglineCN = "一款零生态基础的Agent工具"
    public static let taglineEN = "An ecosystem-agnostic Agent tool."
}
