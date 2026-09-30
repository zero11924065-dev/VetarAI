//
//  CUPermissionGuideView.swift
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

//  挂载：设置-CU 页 ComputerUseSection（启用 CU 后展示）。
//  结构：
//    · 三权限状态行（✓ 已授予 / ✗ 未授予 / ？ 无法探测）——全设置页唯一一套
//      权限状态行（M3 修复：权限结论单一真源 CUPermissionStatusStore，
//      既有探测区不再渲染权限行，杜绝同屏双口径矛盾）；
//    · 缺失权限的分步引导卡（说明 + 未授权后果 + 编号步骤 +
//      「打开系统设置」直达 + 「请求系统授权」+ 须重启徽标）
//    · 「复核刷新」——授权后回页一键重查（TCC 只读状态位，无副作用）
//    · 全部就绪 → 单行成功态
//  纯逻辑（状态解析/引导文案/深链）在 CUPermissionGuide.swift，XCTest 覆盖；
//  本视图只做呈现与系统交互调用。
//

import SwiftUI

struct CUPermissionGuideView: View {

    /// 权限状态单一真源（M3：与设置页其余区块共享同一实例，刷新同刻生效）
    @ObservedObject var store: CUPermissionStatusStore

    private var statuses: [CUPermission: CUPermissionState] { store.statuses }

    private var missingItems: [CUPermissionGuideItem] {
        CUPermissionGuide.missing(statuses).map {
            CUPermissionGuide.guideItem(for: $0, state: statuses[$0] ?? .unknown)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("权限状态与授权引导")
                    .font(VTheme.Typo.caption)
                    .foregroundStyle(VTheme.textSecondary)
                Spacer(minLength: 0)
                Button("复核刷新") { refresh() }
                    .buttonStyle(.vSecondary)
                    .controlSize(.small)
                    .accessibilityIdentifier("settings.cuGuideRefreshButton")
            }

            // 三权限状态行（声明序固定）
            ForEach(CUPermission.allCases, id: \.self) { p in
                statusLine(p)
            }

            if missingItems.isEmpty {
                Text("✓ 三项权限均已授予，Computer Use 可正常使用。")
                    .font(VTheme.Typo.caption)
                    .foregroundStyle(VTheme.okText)
                    .accessibilityIdentifier("settings.cuGuideAllGranted")
            } else {
                ForEach(missingItems, id: \.permission) { item in
                    guideCard(item)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VTheme.bgSidebar, in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
        .onAppear { refresh() }
    }

    private func refresh() {
        store.refresh()   // M3：单真源重探，页内所有权限行同刻更新
    }

    private func statusLine(_ p: CUPermission) -> some View {
        let state = statuses[p] ?? .unknown
        let suffix: String
        let color: Color
        switch state {
        case .granted: suffix = "✓ 已授予"; color = VTheme.okText
        case .denied: suffix = "✗ 未授予"; color = VTheme.dangerText
        case .unknown: suffix = "？ 无法探测"; color = VTheme.textTertiary
        }
        return (Text(CUPermissionGuide.title(for: p) + "：").foregroundStyle(VTheme.textTertiary)
                + Text(suffix).foregroundStyle(color))
            .font(.system(size: 12, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("settings.cuGuideStatus.\(p.rawValue)")
    }

    private func guideCard(_ item: CUPermissionGuideItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("需授权：\(item.title)")
                    .font(VTheme.Typo.caption)
                    .foregroundStyle(VTheme.dangerText)
                if item.needsRestart {
                    Text("授权后须重启本应用生效")
                        .font(VTheme.Typo.micro)
                        .foregroundStyle(VTheme.textTertiary)
                }
            }
            Text("用途：\(item.purpose)")
                .font(VTheme.Typo.micro)
                .foregroundStyle(VTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(item.consequence)
                .font(VTheme.Typo.micro)
                .foregroundStyle(VTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(item.steps.enumerated()), id: \.offset) { idx, step in
                Text("\(idx + 1). \(step)")
                    .font(VTheme.Typo.micro)
                    .foregroundStyle(VTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Button("打开系统设置") {
                    CUPermissionRequest.openSystemSettings(for: item.permission)
                }
                .buttonStyle(.vSecondary)
                .controlSize(.small)
                .accessibilityIdentifier("settings.cuGuideOpenSettings.\(item.permission.rawValue)")
                if item.canRequestInApp {
                    Button("请求系统授权") {
                        CUPermissionRequest.requestSystemPrompt(for: item.permission)
                        refresh()
                    }
                    .buttonStyle(.vSecondary)
                    .controlSize(.small)
                    .accessibilityIdentifier("settings.cuGuideRequest.\(item.permission.rawValue)")
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.s)
            .stroke(VTheme.dangerText.opacity(0.35)))
        .accessibilityIdentifier("settings.cuGuideCard.\(item.permission.rawValue)")
    }
}
