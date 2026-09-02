"""0.2.1（TS-119）：工作流模块（一级模块"流程中心"）。

工作流 = JSON DAG（nodes + edges），节点类型：
  start / inference / tool / condition / parallel / approval / end

核心设计（用户 2026-09-02 拍板）：
- 推理节点（inference）走纯调用（不走 tool loop、无系统提示词/工具列表）——
  根治 OCR 专用小模型被"Agent 外壳"逼出乱码/复读任务书的问题。
- 模型释放：节点完成即判断下一节点模型——不同则立即卸载当前模型
  （keep_alive:0）再加载新模型；相同则不卸载（支持同一模型连续多步）。
- 条件分支支持静态匹配与动态裁判节点（模型判定走哪条边）。
- 人工审批节点挂起运行（awaiting_approval），前端批准后恢复。
"""
from sidecar.workflow.engine import (
    WorkflowEngine,
    WorkflowCancel,
    NodeResult,
    NODE_TYPES,
)
from sidecar.workflow.schema import (
    validate_definition,
    default_start_definition,
)

__all__ = [
    "WorkflowEngine",
    "WorkflowCancel",
    "NodeResult",
    "NODE_TYPES",
    "validate_definition",
    "default_start_definition",
]
