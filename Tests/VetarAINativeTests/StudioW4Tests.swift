//
//  StudioW4Tests.swift
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

//  覆盖（studio/spec §2/§3/§4/§7 可测口径）：
//    L1–L4  旋转角：范围/确定性/异 id 分布/拖动幅度常量
//    L5–L8  坐标分配：拓扑分层列 / 已有坐标不覆盖 / error 跟随 / 散布区换行
//    V1–V3  虚拟化：可见性判定 / 外扩 margin / 子集保持原序
//    Z1–Z3  缩放：钳制 25~200 / 档位吸附 / 适应变换
//    F1–F2  筛选：六类计数 / 命中判定
//    T1     顶条六态映射（§4 表逐态断言）
//    N1     StudioNote 坐标字段 Codable 向后兼容（旧库无键 decode 得 nil）
//

import XCTest
import CoreGraphics
@testable import VetarAINative

final class StudioCanvasLayoutTests: XCTestCase {

    // MARK: - L 旋转角

    func testL1_baseRotation_inRange() {
        for i in 0..<200 {
            let r = StudioCanvasLayout.baseRotation(id: "note-\(i)")
            XCTAssertGreaterThanOrEqual(abs(r), 0.4, "幅度下限 0.4°")
            XCTAssertLessThanOrEqual(abs(r), 1.8, "幅度上限 1.8°")
        }
    }

    func testL2_baseRotation_deterministic() {
        let a = StudioCanvasLayout.baseRotation(id: "abc-123")
        let b = StudioCanvasLayout.baseRotation(id: "abc-123")
        XCTAssertEqual(a, b, "同 id 恒同角（避免跳动）")
    }

    func testL3_baseRotation_hasBothSigns() {
        let angles = (0..<50).map { StudioCanvasLayout.baseRotation(id: "n\($0)") }
        XCTAssertTrue(angles.contains { $0 > 0 })
        XCTAssertTrue(angles.contains { $0 < 0 })
    }

    func testL4_dragRotation_specValue() {
        XCTAssertEqual(StudioCanvasLayout.dragRotation, 3.5)
        XCTAssertEqual(StudioCanvasLayout.noteSize, CGSize(width: 236, height: 118))
        XCTAssertEqual(StudioCanvasLayout.minGap, 24)
        XCTAssertEqual(StudioCanvasLayout.dotSpacing, 26)
        XCTAssertEqual(StudioCanvasLayout.dotRadius, 1.2)
    }

    // MARK: - L 坐标分配

    private func taskNote(_ id: String, node: String) -> StudioNote {
        StudioNote(id: id, kind: .task, title: id, body: "", taskNodeId: node,
                   taskStatus: .pending)
    }

    private func twoLayerGraph() -> StudioTaskGraph {
        StudioTaskGraph(concurrency: 2, nodes: [
            StudioTaskNode(id: "t1", title: "a", brief: ""),
            StudioTaskNode(id: "t2", title: "b", brief: ""),
            StudioTaskNode(id: "t3", title: "c", brief: "", dependsOn: ["t1", "t2"]),
        ])
    }

    func testL5_assignPositions_topoLayersInColumns() {
        let notes = [taskNote("n1", node: "t1"), taskNote("n2", node: "t2"),
                     taskNote("n3", node: "t3")]
        let pos = StudioCanvasLayout.assignPositions(notes: notes, graph: twoLayerGraph())
        XCTAssertEqual(pos.count, 3)
        // t1/t2 同层同列（x 相近），t3 次层右移一列
        let dx12 = abs(pos["n1"]!.x - pos["n2"]!.x)
        XCTAssertLessThan(dx12, 40, "同层便签同列（仅抖动偏移）")
        XCTAssertGreaterThan(pos["n3"]!.x - pos["n1"]!.x, 200, "次层右移一列")
        XCTAssertGreaterThan(abs(pos["n1"]!.y - pos["n2"]!.y), 100, "同层纵排分行")
    }

    func testL6_assignPositions_keepsExisting() {
        var n1 = taskNote("n1", node: "t1")
        n1.x = 999; n1.y = 888   // 业主拖过的位置
        let pos = StudioCanvasLayout.assignPositions(notes: [n1, taskNote("n2", node: "t2")],
                                                     graph: twoLayerGraph())
        XCTAssertNil(pos["n1"], "已有坐标不覆盖（拖动结果保留）")
        XCTAssertNotNil(pos["n2"])
    }

    /// L6b：占位分配（冒烟修复批根因守护）——增量分配时已有坐标便签必须占住
    /// 层内行位，否则新便签从行 0 起排与旧签同层撞行（逐条回写时代镜像反复
    /// 触发分配的真实场景：t1 已落位，t2 新进场）。
    func testL6b_assignPositions_existingNoteOccupiesRow() {
        var n1 = taskNote("n1", node: "t1")
        n1.x = 60; n1.y = 60     // 层 0 行 0 已落位
        let pos = StudioCanvasLayout.assignPositions(notes: [n1, taskNote("n2", node: "t2")],
                                                     graph: twoLayerGraph())
        XCTAssertNil(pos["n1"])
        let p2 = pos["n2"]!
        // n2 必须放行 1（y ≈ 60 + rowStride），不得落回行 0 与 n1 相撞
        XCTAssertGreaterThan(abs(p2.y - 60), 100, "新便签不得与已有坐标便签撞行")
    }

    /// L6c：散布区占位——已有坐标的 user 便签占住散布序，新进 user 便签排空位。
    func testL6c_assignPositions_scatterOccupancy() {
        var u0 = StudioNote(id: "u0", kind: .user, title: "u0", body: "")
        u0.x = 60; u0.y = 1000   // 散布区已落位
        let u1 = StudioNote(id: "u1", kind: .user, title: "u1", body: "")
        let pos = StudioCanvasLayout.assignPositions(notes: [u0, u1], graph: nil)
        XCTAssertNil(pos["u0"])
        let p1 = pos["u1"]!
        XCTAssertGreaterThan(abs(p1.x - 60), 100, "新散布便签不得叠在已有便签同格")
    }

    func testL7_assignPositions_errorFollowsTask() {
        var notes = [taskNote("n1", node: "t1")]
        notes.append(StudioNote(id: "e1", kind: .error, title: "失败", body: "",
                                taskNodeId: "t1"))
        let pos = StudioCanvasLayout.assignPositions(notes: notes, graph: twoLayerGraph())
        XCTAssertNotNil(pos["n1"]); XCTAssertNotNil(pos["e1"])
        XCTAssertGreaterThan(pos["e1"]!.x, pos["n1"]!.x, "error 在关联任务便签右侧")
    }

    func testL8_assignPositions_scatterWraps() {
        // 6 张用户便签 → 散布区 4 张/行换行
        let notes = (0..<6).map { StudioNote(id: "u\($0)", kind: .user, title: "u\($0)", body: "") }
        let pos = StudioCanvasLayout.assignPositions(notes: notes, graph: nil)
        XCTAssertEqual(pos.count, 6)
        // 第 0 与第 4 张同列不同行（换行）
        let dx = abs(pos["u0"]!.x - pos["u4"]!.x)
        XCTAssertLessThan(dx, 40)
        XCTAssertGreaterThan(pos["u4"]!.y - pos["u0"]!.y, 100)
    }

    // MARK: - V 视口虚拟化

    func testV1_isVisible_intersects() {
        let vp = CGRect(x: 0, y: 0, width: 800, height: 600)
        XCTAssertTrue(StudioCanvasLayout.isVisible(noteOrigin: CGPoint(x: 100, y: 100), viewport: vp))
        XCTAssertFalse(StudioCanvasLayout.isVisible(noteOrigin: CGPoint(x: 2000, y: 100), viewport: vp))
        // 边缘：便签右缘刚好进入 margin 内
        XCTAssertTrue(StudioCanvasLayout.isVisible(noteOrigin: CGPoint(x: 830, y: 100), viewport: vp))
    }

    func testV2_isVisible_marginPreventsFlicker() {
        let vp = CGRect(x: 0, y: 0, width: 800, height: 600)
        // 便签完全在屏外但在 margin 内 → 可见（预渲染）
        XCTAssertTrue(StudioCanvasLayout.isVisible(noteOrigin: CGPoint(x: -270, y: 100),
                                                   viewport: vp, margin: 48))
        XCTAssertFalse(StudioCanvasLayout.isVisible(noteOrigin: CGPoint(x: -400, y: 100),
                                                    viewport: vp, margin: 48))
    }

    func testV3_visibleNotes_keepsOrderAndSkipsUnpositioned() {
        var a = StudioNote(id: "a", kind: .task, title: "a", body: ""); a.x = 10; a.y = 10
        let b = StudioNote(id: "b", kind: .task, title: "b", body: "")               // 无坐标
        var c = StudioNote(id: "c", kind: .task, title: "c", body: ""); c.x = 5000; c.y = 5000
        var d = StudioNote(id: "d", kind: .task, title: "d", body: ""); d.x = 50; d.y = 50
        let vis = StudioCanvasLayout.visibleNotes([a, b, c, d],
                                                  viewport: CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertEqual(vis.map { $0.id }, ["a", "d"], "屏外剔除 + 无坐标跳过 + 保序")
    }

    // MARK: - Z 缩放

    func testZ1_clampZoom() {
        XCTAssertEqual(StudioCanvasLayout.clampZoom(0.1), 0.25)
        XCTAssertEqual(StudioCanvasLayout.clampZoom(3), 2.0)
        XCTAssertEqual(StudioCanvasLayout.clampZoom(1.2), 1.2)
    }

    func testZ2_snapZoom() {
        XCTAssertEqual(StudioCanvasLayout.snapZoom(0.98), 1.0)
        XCTAssertEqual(StudioCanvasLayout.snapZoom(0.62), 0.6)
        XCTAssertEqual(StudioCanvasLayout.snapZoom(1.11), 1.11, "非档位保持")
        XCTAssertEqual(StudioCanvasLayout.snapZoom(0.05), 0.25, "越界先吸附/钳制")
    }

    func testZ3_fitTransform() {
        let positions = [CGPoint(x: 0, y: 0), CGPoint(x: 500, y: 300)]
        let (z, off) = StudioCanvasLayout.fitTransform(positions: positions,
                                                       viewport: CGSize(width: 1200, height: 800))
        XCTAssertGreaterThan(z, 0); XCTAssertLessThanOrEqual(z, 2.0)
        // 内容中心应大致落在视口中心
        let cx = (0 + 500 + 236) / 2 * z + off.x
        let cy = (0 + 300 + 118) / 2 * z + off.y
        XCTAssertEqual(cx, 600, accuracy: 60)
        XCTAssertEqual(cy, 400, accuracy: 60)
        // 空集合安全
        let e = StudioCanvasLayout.fitTransform(positions: [], viewport: CGSize(width: 800, height: 600))
        XCTAssertEqual(e.zoom, 1.0)
    }

    // MARK: - F 筛选

    func testF1_filterCounts() {
        let notes = [
            StudioNote(kind: .task, title: "t", body: ""),
            StudioNote(kind: .task, title: "t2", body: ""),
            StudioNote(kind: .think, title: "k", body: ""),
            StudioNote(kind: .user, title: "u", body: ""),
        ]
        let counts = StudioCanvasLayout.filterCounts(notes)
        XCTAssertEqual(counts[nil], 4)
        XCTAssertEqual(counts[.task], 2)
        XCTAssertEqual(counts[.think], 1)
        XCTAssertEqual(counts[.user], 1)
        XCTAssertEqual(counts[.error], 0)
        XCTAssertEqual(counts[.summary], 0)
    }

    func testF2_matches() {
        let n = StudioNote(kind: .task, title: "t", body: "")
        XCTAssertTrue(StudioCanvasLayout.matches(n, filter: nil))
        XCTAssertTrue(StudioCanvasLayout.matches(n, filter: .task))
        XCTAssertFalse(StudioCanvasLayout.matches(n, filter: .error))
    }

    // MARK: - T 顶条六态映射（spec §4 表）

    func testT1_topBarSpec_sixPhases() {
        let empty = StudioTopBarSpec.forPhase(.empty)
        XCTAssertEqual(empty.badgeColor, "neutral"); XCTAssertEqual(empty.badgeText, "未开始")
        XCTAssertFalse(empty.showsProgress); XCTAssertFalse(empty.showsPause)
        XCTAssertTrue(empty.showsConcurrencyChip)
        XCTAssertTrue(empty.showsStart, "空态顶条「开始」钮（稿 02 口径）")
        XCTAssertFalse(StudioTopBarSpec.forPhase(.running).showsStart)

        let review = StudioTopBarSpec.forPhase(.review)
        XCTAssertEqual(review.badgeColor, "warn"); XCTAssertEqual(review.badgeText, "待复审")
        XCTAssertFalse(review.showsPause); XCTAssertFalse(review.showsFinishGhost)

        let running = StudioTopBarSpec.forPhase(.running)
        XCTAssertEqual(running.badgeColor, "accent"); XCTAssertEqual(running.badgeText, "进行中")
        XCTAssertTrue(running.showsProgress); XCTAssertTrue(running.showsPause)
        XCTAssertTrue(running.showsFinishGhost); XCTAssertFalse(running.showsResume)

        let paused = StudioTopBarSpec.forPhase(.paused)
        XCTAssertEqual(paused.badgeColor, "warn"); XCTAssertEqual(paused.badgeText, "已暂停")
        XCTAssertTrue(paused.showsResume); XCTAssertTrue(paused.showsFinishSummarize)
        XCTAssertFalse(paused.showsPause)

        let done = StudioTopBarSpec.forPhase(.done)
        XCTAssertEqual(done.badgeColor, "ok"); XCTAssertEqual(done.badgeText, "已完成")
        XCTAssertTrue(done.showsReset); XCTAssertTrue(done.showsFinishGhost)
        XCTAssertFalse(done.showsConcurrencyChip)

        let failed = StudioTopBarSpec.forPhase(.failed)
        XCTAssertEqual(failed.badgeColor, "danger"); XCTAssertEqual(failed.badgeText, "待人工干预")
        XCTAssertTrue(failed.showsPause); XCTAssertTrue(failed.showsFinishGhost)
    }

    // MARK: - N StudioNote 坐标字段

    func testN1_noteCoords_codableBackwardCompatible() throws {
        // 旧库 JSON（无 x/y 键）→ decode 得 nil
        let legacy = """
        {"id":"n1","kind":"task","title":"t","body":"b","createdAt":"2026-09-22T00:00:00.000Z"}
        """
        let n = try JSONDecoder().decode(StudioNote.self, from: Data(legacy.utf8))
        XCTAssertNil(n.x); XCTAssertNil(n.y)
        // 带坐标往返
        var m = StudioNote(kind: .user, title: "u", body: "")
        m.x = 123.5; m.y = -45.25
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(StudioNote.self, from: data)
        XCTAssertEqual(back.x, 123.5); XCTAssertEqual(back.y, -45.25)
    }

    // MARK: - 缩略图包围盒

    func testM1_contentBounds() {
        XCTAssertNil(StudioCanvasLayout.contentBounds(positions: []))
        let r = StudioCanvasLayout.contentBounds(positions: [CGPoint(x: 10, y: 20),
                                                             CGPoint(x: 300, y: 200)])
        XCTAssertEqual(r?.minX, 10); XCTAssertEqual(r?.minY, 20)
        XCTAssertEqual(r?.maxX, 300 + 236); XCTAssertEqual(r?.maxY, 200 + 118)
    }
}
