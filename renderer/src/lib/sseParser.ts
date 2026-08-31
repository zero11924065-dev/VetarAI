/**
 * M1-4 SSE 解析器（纯函数，可单测，不依赖 React/DOM）。
 *
 * 事件契约（后端 /api/ollama/chat/stream）：
 *   event: token|tool_call|tool_result|state|done|error
 *   data:  <json>
 *   : ping 注释行 / 空行分隔
 *
 * 健壮性（DoD：坏 JSON / 缺 event 行 / 空 data 都要安全处理，不抛）：
 *   - 按 \n\n 分块；块内 event: 取类型，data: 多行拼接（工具 args 可能含换行）
 *   - : 开头为注释（心跳），直接忽略
 *   - data JSON 解析失败 → data:{raw} 而非抛异常
 *   - 缺 event 行 → 默认 'message'；空 data → data:{}
 */
export interface SSEEvent {
  event: string;
  data: Record<string, any>;
}

export function parseSSEChunk(chunk: string): SSEEvent[] {
  const events: SSEEvent[] = [];
  const blocks = chunk.split(/\r?\n\r?\n/);
  for (const block of blocks) {
    if (!block.trim()) continue;
    const lines = block.split(/\r?\n/);
    let type = '';
    const dataLines: string[] = [];
    for (const line of lines) {
      if (line.startsWith(':')) continue;            // 注释/心跳
      if (line.startsWith('event:')) type = line.slice(6).trim();
      else if (line.startsWith('data:')) dataLines.push(line.slice(5).replace(/^ +/, '')); // TS-102 B16：剥离 data: 后任意数量空格
    }
    if (!type && dataLines.length === 0) continue;
    type = type || 'message';
    const raw = dataLines.join('\n');
    let data: Record<string, any> = {};
    if (raw) {
      try {
        const parsed = JSON.parse(raw);
        data = (parsed && typeof parsed === 'object') ? parsed : { value: parsed };
      } catch {
        data = { raw };
      }
    }
    events.push({ event: type, data });
  }
  return events;
}

/**
 * 增量 SSE 读取器：喂 reader 每次 read() 的 text 分片，内部维护跨分片行缓冲，
 * 按完整事件块产出。解决"data: 内 JSON 含换行 + 分片边界切断"两类边界。
 */
export class SSEStreamParser {
  private buf = '';
  push(text: string): SSEEvent[] {
    this.buf += text;
    // TS-102 B08：同时识别 \n\n 与 \r\n\r\n 事件分隔（跨平台/代理改写场景），
    // 取靠后者消费；分隔符未到则留存尾部（跨分片行缓冲，避免半截事件误解析）
    const lf = this.buf.lastIndexOf('\n\n');
    const crlf = this.buf.lastIndexOf('\r\n\r\n');
    if (lf === -1 && crlf === -1) return [];
    const cut = (crlf !== -1 && crlf + 4 > lf + 2) ? crlf + 4 : lf + 2;
    const consumable = this.buf.slice(0, cut);
    this.buf = this.buf.slice(cut);
    return parseSSEChunk(consumable);
  }
  flush(): SSEEvent[] {
    if (!this.buf.trim()) return [];
    const rest = this.buf;
    this.buf = '';
    return parseSSEChunk(rest);
  }
}
