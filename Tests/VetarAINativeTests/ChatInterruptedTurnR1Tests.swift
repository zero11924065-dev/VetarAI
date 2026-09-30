//
//  ChatInterruptedTurnR1Tests.swift
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

//  背景（E2E 0.7.12 A5）：生成中强退再进，最后一条 user 消息静默悬空——
//  assistant 流式气泡只存内存（done 才落库），进程死了就什么都没留下，
//  用户不知道这条还算不算数。
//
//  修法（mergeDbWithLocal 收口点）：非 live 加载结果末条是 user ⇒ 该轮
//  assistant 从未落库 ⇒ 合成「已中断执行（应用退出或崩溃，本轮未生成回复）」
//  标记气泡（local_ id 不落库、幂等重建），视图层挂「重新发送」（resendLast
//  语义复用）。本文件钉纯逻辑五态。
//

import XCTest
@testable import VetarAINative

final class ChatInterruptedTurnR1Tests: XCTestCase {

    private func user(_ content: String, id: String = UUID().uuidString) -> ChatMessage {
        ChatMessage(id: id, role: "user", content: content)
    }

    /// 核心场景：DB 只有 user 消息（assistant 从未落库）+ 无活流
    /// → 末尾合成 assistant 中断标记气泡。
    func testDanglingUserTurnGetsInterruptedMarker() {
        let merged = mergeDbWithLocal(db: [user("帮我写个总结")], local: [], live: false)
        XCTAssertEqual(merged.count, 2)
        let marker = merged[1]
        XCTAssertEqual(marker.role, "assistant")
        XCTAssertEqual(marker.content, "", "标记气泡不带正文（不编造生成内容）")
        XCTAssertEqual(marker.interruptedNote, "已中断执行（应用退出或崩溃，本轮未生成回复）")
        XCTAssertFalse(marker.isStreaming, "中断标记绝不显示生成中态")
        XCTAssertFalse(marker.manuallyStopped, "不谎称用户手动停止")
        XCTAssertTrue(marker.id.hasPrefix("local_"), "合成气泡不落库（local_ id）")
        XCTAssertNil(marker.completedDuration)
    }

    /// 活流会话（切回 stash 重放）→ 不标中断——流还在推进，标记是说谎。
    func testLiveSessionNeverGetsMarker() {
        let merged = mergeDbWithLocal(db: [user("hi")], local: [], live: true)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.last?.role, "user")
    }

    /// 正常完成轮次（assistant 已落库）→ 不标。
    func testCompletedTurnGetsNoMarker() {
        let db = [user("hi"), ChatMessage(id: "2", role: "assistant", content: "你好")]
        let merged = mergeDbWithLocal(db: db, local: [], live: false)
        XCTAssertEqual(merged.count, 2)
        XCTAssertNil(merged.last?.interruptedNote)
    }

    /// 空会话 → 不标（无可悬空）。
    func testEmptySessionGetsNoMarker() {
        XCTAssertTrue(mergeDbWithLocal(db: [], local: [], live: false).isEmpty)
    }

    /// 幂等：标记气泡随 local 再喂回合并 → 旧标记被僵尸清理丢弃、
    /// 新标记重建——任何时刻恒只有一个中断标记。
    func testMarkerIsIdempotentAcrossReloads() {
        let db = [user("hi")]
        let first = mergeDbWithLocal(db: db, local: [], live: false)
        XCTAssertEqual(first.count, 2)
        let second = mergeDbWithLocal(db: db, local: first, live: false)
        XCTAssertEqual(second.count, 2, "重载后恒只有一个中断标记（旧标记空壳被清理重建）")
        XCTAssertEqual(second.last?.interruptedNote, "已中断执行（应用退出或崩溃，本轮未生成回复）")
        XCTAssertEqual(second.last?.role, "assistant")
    }

    /// 有内容的僵尸中断气泡（半成品）恢复后末条已是 assistant → 不重复标记；
    /// 半成品「已中断」由既有 #13 路径承担。
    func testZombieHalfContentBubbleNotDoubleMarked() {
        var zombie = ChatMessage(id: "local_z1", role: "assistant", content: "写了一半的")
        zombie.isStreaming = true
        let merged = mergeDbWithLocal(db: [user("hi")], local: [zombie], live: false)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[1].interruptedNote, "已中断执行（应用断开或崩溃，内容为半成品）",
                       "半成品沿用 #13 既有文案（应用断开或崩溃）")
        XCTAssertFalse(merged[1].isStreaming)
    }
}
