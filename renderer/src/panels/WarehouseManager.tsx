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

const API = getApiBase();

interface KnowledgeGroup {
  scope: string; project_id: string | null; project_name: string;
  count: number; dir: string;
}

export function WarehouseManager() {
  const [groups, setGroups] = useState<KnowledgeGroup[]>([]);
  const [loading, setLoading] = useState(false);
  const [opening, setOpening] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

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

  return (
    <div style={{ ...cardL, padding: '16px 20px' }}>
      <div style={{ fontSize: 12, color: colors.textTertiary, marginBottom: 12, lineHeight: 1.6 }}>
        知识仓库（拉模式）：从会话转移进来的对话/知识，保存为 .md 文件永久存储；只有你在会话框右侧面板显式搜索/勾选时才读取，
        永不自动注入模型上下文。与「知识库」（自动注入）是不同的东西。项目知识存于项目文件夹的"知识库"目录，全局知识存于应用数据目录。在 Finder 删除 .md 文件后，索引会在下次读取时自动对账清除。
      </div>
      {error && (
        <div style={{ ...calloutStyle('error'), marginBottom: 12 }}>
          <Icon name="alert-triangle" size={16} style={{ flexShrink: 0 }} />
          <span>{error}</span>
        </div>
      )}
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 12 }}>
        <span style={{ fontSize: 13, fontWeight: 500, color: colors.textPrimary }}>知识分组</span>
        <button className="ui-btn ui-btn-secondary" style={{ ...btnSecondary, height: 26, fontSize: 12 }}
          onClick={rebuild} disabled={loading} title="扫描全部 .md 重建索引（索引损坏时容灾）">
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
              onClick={() => openDir(g)} disabled={opening === g.dir || !g.dir}>
              {opening === g.dir ? <Spinner size={12} /> : null} 打开文件夹
            </button>
          </div>
        );
      })}
    </div>
  );
}
