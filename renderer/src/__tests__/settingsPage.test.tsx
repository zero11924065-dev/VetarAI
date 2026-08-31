import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, act } from '@testing-library/react';
import React from 'react';
import { SettingsPage } from '../panels/SettingsPage';

// checkpoint-045：整页设置视图测试（导航 + 各分区渲染 + 未选项目提示）
describe('SettingsPage 整页设置', () => {
  beforeEach(() => { vi.restoreAllMocks(); });

  it('左侧导航渲染 4 个分类 + 返回按钮', () => {
    render(<SettingsPage projectId={null} onExit={() => {}} onOpenLogs={() => {}} />);
    expect(screen.getByText('返回应用')).toBeTruthy();
    expect(screen.getByText('基础设置')).toBeTruthy();
    expect(screen.getByText('知识记忆')).toBeTruthy();
    expect(screen.getByText('推理后端')).toBeTruthy();
    expect(screen.getByText('插件管理')).toBeTruthy();
  });

  it('基础设置含"打开日志文件夹"按钮', () => {
    render(<SettingsPage projectId={null} onExit={() => {}} onOpenLogs={() => {}} />);
    expect(screen.getByText('打开日志文件夹')).toBeTruthy();
  });

  it('点击返回触发 onExit', () => {
    const onExit = vi.fn();
    render(<SettingsPage projectId={null} onExit={onExit} onOpenLogs={() => {}} />);
    act(() => { screen.getByText('返回应用').click(); });
    expect(onExit).toHaveBeenCalledTimes(1);
  });

  it('未选项目时知识记忆分区优雅降级（提示先选项目，而非空白）', async () => {
    render(<SettingsPage projectId={null} onExit={() => {}} onOpenLogs={() => {}} />);
    await act(async () => { screen.getByText('知识记忆').click(); });
    expect(screen.getByText(/当前未选择项目/)).toBeTruthy();
  });

  it('关于信息已移至原生菜单栏，设置页不再含关于分区', () => {
    render(<SettingsPage projectId={null} onExit={() => {}} onOpenLogs={() => {}} />);
    expect(screen.queryByText('关于VetarAI')).toBeNull();
  });

  it('点击打开日志文件夹触发 onOpenLogs', () => {
    const onOpenLogs = vi.fn();
    render(<SettingsPage projectId={null} onExit={() => {}} onOpenLogs={onOpenLogs} />);
    act(() => { screen.getByText('打开日志文件夹').click(); });
    expect(onOpenLogs).toHaveBeenCalledTimes(1);
  });
});
