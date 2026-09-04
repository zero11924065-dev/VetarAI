/** 0.4.4：全局忙碌状态上报（任务执行中关闭应用弹确认窗口）。
 *
 * 各活动面板（会话发送 / 工作流运行 / 圆桌运行）调用 reportBusy(源, 忙?)
 * 登记自己的忙碌状态；汇总结果经 IPC 上报主进程，主进程在关闭窗口时
 * 若处于忙碌态则弹确认框，防止误触中断任务。 */
const busySources = new Map<string, boolean>();

let lastAggregated = false;

function push() {
  const agg = Array.from(busySources.values()).some(Boolean);
  if (agg !== lastAggregated) {
    lastAggregated = agg;
    try {
      (window as any).subagent?.reportBusy?.(agg);
    } catch { /* 桥不可用（开发态）忽略 */ }
  }
}

export function reportBusy(source: string, busy: boolean) {
  busySources.set(source, busy);
  push();
}
