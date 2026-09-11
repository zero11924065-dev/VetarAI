/*
 * VetarAI - Local-first multi-agent orchestration application
 * Copyright (C) 2026 zero11924065-dev
 *
 * This file is part of VetarAI.
 *
 * VetarAI is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * VetarAI is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with VetarAI. If not, see <https://www.gnu.org/licenses/>.
 */
/**
 * TS-120（0.3.0）：知识仓库资产管理器（设置页"知识仓库"标签）。
 *
 * 与 WarehousePanel（会话框右侧检索/注入面板）区分：本组件是资产总览——
 * 列出全局知识组 + 各项目知识组（各含条数、存储目录），可"打开文件夹"
 * 在 Finder 直接查看/管理 .md 文件。条目本体永久保存为 .md，删除前一直在。
 *
 * 与 KnowledgeTab（M4 推模式知识，自动注入）严格区分：本模块是拉模式仓库，
 * 内容永不自动注入模型上下文。
 */
import { useEffect, useState, useCallback } from 'react';
import { getApiBase } from '../apiBase';
import { colors, radius, cardL, btnSecondary, calloutStyle } from '../theme';
import { Icon, Spinner } from '../Icon';
import { choiceDialog } from '../Dialog';

const API = getApiBase();

interface KnowledgeGroup {
  scope: string; project_id: string | null; project_name: string;
  count: number; dir: string;
}

export function WarehouseManager() {
  const [groups, setGroups] = useState<KnowledgeGroup[]>([]);
  const [loading, setLoading] = useState(false);
  const [opening, setOpening] = useState<string | null>(null);
  const [importing, setImporting] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [info, setInfo] = useState<string | null>(null);
  // TS-120 阶段二：嵌入模型状态（可用性 + 向量覆盖率）
  const [embedStatus, setEmbedStatus] = useState<{ available: boolean; entries_total: number; entries_embedded: number } | null>(null);

  const refresh = useCallback(async () => {
    setLoading(true); setError(null);
    try {
      const res = await fetch(`${API}/knowledge/groups`);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const d = await res.json();
      setGroups(Array.isArray(d) ? d : []);
    } catch (e) {
      setError('加载知识仓库失败: ' + (e as Error).message);
    } finally {
      setLoading(false);
    }
    // 嵌入状态独立拉取，失败不影响主面板
    try {
      const r2 = await fetch(`${API}/knowledge/embedding-status`);
      if (r2.ok) setEmbedStatus(await r2.json());
    } catch { /* 静默 */ }
  }, []);
  useEffect(() => { refresh(); }, [refresh]);

  // 问题3修复：用户从 Finder 删除 .md 后回到应用，计数要自动刷新——
  // 不能依赖切页重挂载。窗口重获焦点 + 页面重新可见两个时机都刷新（后端读取前对账）。
  useEffect(() => {
    const onRefresh = () => { refresh(); };
    window.addEventListener('focus', onRefresh);
    document.addEventListener('visibilitychange', onRefresh);
    return () => {
      window.removeEventListener('focus', onRefresh);
      document.removeEventListener('visibilitychange', onRefresh);
    };
  }, [refresh]);

  const openDir = async (g: KnowledgeGroup) => {
    setOpening(g.dir);
    try {
      const res = await fetch(`${API}/knowledge/open-dir`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ scope: g.scope, project_id: g.project_id }),
      });
      const d = await res.json();
      if (!res.ok) throw new Error(d.detail || `HTTP ${res.status}`);
    } catch (e) {
      setError('打开文件夹失败: ' + (e as Error).message);
    } finally {
      setOpening(null);
    }
  };

  const rebuild = async () => {
    setLoading(true); setError(null);
    try {
      const res = await fetch(`${API}/knowledge/rebuild-index`, { method: 'POST' });
      const d = await res.json();
      if (!res.ok) throw new Error(d.detail || `HTTP ${res.status}`);
      await refresh();
    } catch (e) {
      setError('重建索引失败: ' + (e as Error).message);
    } finally {
      setLoading(false);
    }
  };

  // A11（0.4.22）：导入用户选中的文件到本知识组（复制+解析+索引）。
  // ⛔ 拉模式铁律：只导入索引供检索，不自动注入上下文。
  // ⛔ 非递归：chooseInputFile({multiple}) 返回文件路径数组（用户主动选），不遍历目录。
  // ⛔ bridge 不存在（浏览器调试态）时静默返回，不报错。
  // ⛔ 同名冲突**弹窗问用户**（用户 2026-09-12 拍板，不自动改名也不静默覆盖）：
  //    第一趟用 on_conflict='ask' —— 不冲突的正常导入，冲突的原样留着并列在 conflicts 里；
  //    有冲突才弹窗，用户选完**只重传冲突的那几个文件**（不重复导入已成功的）。
  const importFiles = async (g: KnowledgeGroup) => {
    const bridge = (window as any).subagent;
    if (!bridge?.chooseInputFile) { setError('当前环境不支持文件选择'); return; }
    setImporting(g.dir); setError(null); setInfo(null);
    try {
      const paths = await bridge.chooseInputFile({ multiple: true, title: '选择要导入知识仓库的文件' });
      if (!paths || (Array.isArray(paths) && paths.length === 0)) return; // 用户取消
      const list: string[] = Array.isArray(paths) ? paths : [paths];
      const baseName = (p: string) => p.split(/[\\/]/).pop() || p;

      const post = async (sendPaths: string[], strategy: string) => {
        const res = await fetch(`${API}/knowledge/import-files`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ scope: g.scope, project_id: g.project_id,
                                 paths: sendPaths, on_conflict: strategy }),
        });
        const d = await res.json();
        if (!res.ok) throw new Error(d.detail || `HTTP ${res.status}`);
        return d;
      };

      // 第一趟：ask —— 只导入不冲突的，冲突的报回来
      let d = await post(list, 'ask');
      const conflicts: string[] = Array.isArray(d.conflicts) ? d.conflicts : [];

      if (conflicts.length > 0) {
        const choice = await choiceDialog({
          title: '知识目录已有同名文件',
          message: `${conflicts.length} 个文件在知识目录里已有同名：\n${conflicts.slice(0, 8).join('\n')}`
            + (conflicts.length > 8 ? `\n…等共 ${conflicts.length} 个` : '')
            + '\n\n要如何处理？（你的本机原始文件不会被改动）',
          options: [
            { value: 'overwrite', label: '覆盖同名文件', danger: true },
            { value: 'rename', label: '改名并存' },
            { value: 'skip', label: '跳过这些' },
          ],
          cancelText: '不处理（保留原文件）',
        });
        if (choice) {
          // ⛔ 只重传冲突的那几个（第一趟已把不冲突的成功导入，不能重复）
          const conflictSet = new Set(conflicts);
          const retryPaths = list.filter(p => conflictSet.has(baseName(p)));
          const d2 = await post(retryPaths, choice);
          // ⛔ 两趟结果直接相加即可，无需特判 choice：
          //   第一趟（ask）的 skipped 只含"不支持/解析失败"的文件，**不含**冲突项；
          //   第二趟的 skipped 只在选"跳过"时才含冲突项 → 二者天然不重叠，相加不重复计数。
          d = {
            imported: (d.imported || 0) + (d2.imported || 0),
            failed: (d.failed || 0) + (d2.failed || 0),
            skipped: (d.skipped || 0) + (d2.skipped || 0),
            conflicts: d2.conflicts || [],
            details: [...(d.details || []), ...(d2.details || [])],
          };
        } else {
          // 用户选择不处理：冲突文件如实计入 skipped，并说明是"按你的选择保留原文件"
          d.skipped = (d.skipped || 0) + conflicts.length;
        }
      }

      const parts: string[] = [];
      if (d.imported) parts.push(`导入 ${d.imported} 个`);
      if (d.skipped) parts.push(`跳过 ${d.skipped} 个`);
      if (d.failed) parts.push(`失败 ${d.failed} 个`);
      if (conflicts.length) parts.push(`同名 ${conflicts.length} 个`);
      setInfo(parts.length ? parts.join('，') : '未导入任何文件');
      await refresh();
    } catch (e) {
      setError('导入文件失败: ' + (e as Error).message);
    } finally {
      setImporting(null);
    }
  };

  return (
    <div style={{ ...cardL, padding: '16px 20px' }}>
      <div style={{ fontSize: 12, color: colors.textTertiary, marginBottom: 12, lineHeight: 1.6 }}>
        知识仓库（拉模式）：从会话转移进来的对话/知识，保存为 .md 文件永久存储；只有你在会话框右侧面板显式搜索/勾选时才读取，
        永不自动注入模型上下文。与「知识库」（自动注入）是不同的东西。项目知识存于项目文件夹的"知识库"目录，全局知识存于应用数据目录。在 Finder 删除 .md 文件后，索引会在下次读取时自动对账清除。
      </div>
      {/* TS-120 阶段二：语义嵌入状态 */}
      {embedStatus && (
        <div style={{
          display: 'flex', alignItems: 'center', gap: 8, padding: '8px 12px', marginBottom: 12,
          background: embedStatus.available ? colors.okBg : colors.bgCard,
          border: `1px solid ${embedStatus.available ? colors.okBorder : colors.borderDefault}`,
          borderRadius: radius.s, fontSize: 12, color: embedStatus.available ? colors.okText : colors.textSecondary,
        }}>
          <Icon name={embedStatus.available ? 'check' : 'alert-triangle'} size={14} style={{ flexShrink: 0 }} />
          <span>
            语义嵌入（bge-m3 本地）：{embedStatus.available ? '可用' : '不可用（缺少模型文件，检索自动降级为关键词）'}
            {embedStatus.available && ` · 已向量化 ${embedStatus.entries_embedded}/${embedStatus.entries_total} 条`}
          </span>
        </div>
      )}
      {error && (
        <div style={{ ...calloutStyle('error'), marginBottom: 12 }}>
          <Icon name="alert-triangle" size={16} style={{ flexShrink: 0 }} />
          <span>{error}</span>
        </div>
      )}
      {info && (
        <div style={{ ...calloutStyle('success'), marginBottom: 12 }}>
          <Icon name="check" size={16} style={{ flexShrink: 0 }} />
          <span>{info}</span>
        </div>
      )}
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 12 }}>
        <span style={{ fontSize: 13, fontWeight: 500, color: colors.textPrimary }}>知识分组</span>
        <button className="ui-btn ui-btn-secondary" style={{ ...btnSecondary, height: 26, fontSize: 12 }}
          onClick={rebuild} disabled={loading} data-tip="扫描知识目录内全部文档（md / docx / pdf / xlsx / pptx / doc / txt 等）重建索引（索引损坏时容灾）">
          {loading ? <Spinner size={12} /> : null} 重建索引
        </button>
      </div>
      {groups.length === 0 && !loading && (
        <div style={{ textAlign: 'center', color: colors.textTertiary, fontSize: 12, padding: '20px 0' }}>
          暂无知识分组
        </div>
      )}
      {groups.map(g => {
        const key = g.scope + (g.project_id || '');
        return (
          <div key={key}
            style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: `1px solid ${colors.borderSubtle}` }}>
            <Icon name={g.scope === 'global' ? 'globe' : 'folder'} size={16} style={{ color: colors.accentText, flexShrink: 0 }} />
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ fontSize: 13, fontWeight: 500, color: colors.textPrimary }}>
                {g.project_name}
                <span style={{ fontSize: 11, color: colors.textTertiary, marginLeft: 8 }}>{g.count} 条</span>
              </div>
              <div style={{ fontSize: 11, color: colors.textTertiary, marginTop: 2, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                {g.dir || '（目录不可用）'}
              </div>
            </div>
            <button className="ui-btn ui-btn-secondary" style={{ ...btnSecondary, height: 26, fontSize: 12, flexShrink: 0 }}
              onClick={() => importFiles(g)} disabled={importing === g.dir || !g.dir}
              data-tip="选择本机文件（pdf / docx / xlsx / pptx / txt / md 等）导入本知识组，复制进知识目录并解析索引，可在会话右侧检索">
              {importing === g.dir ? <Spinner size={12} /> : null} 导入文件
            </button>
            <button className="ui-btn ui-btn-secondary" style={{ ...btnSecondary, height: 26, fontSize: 12, flexShrink: 0 }}
              onClick={() => openDir(g)} disabled={opening === g.dir || !g.dir}>
              {opening === g.dir ? <Spinner size={12} /> : null} 打开文件夹
            </button>
          </div>
        );
      })}
    </div>
  );
}
