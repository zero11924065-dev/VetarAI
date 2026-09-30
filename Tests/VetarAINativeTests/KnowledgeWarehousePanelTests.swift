//
//  KnowledgeWarehousePanelTests.swift
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

//  KnowledgePanel（知识库/记忆/技能三标签）+ WarehousePanel（检索/注入）
//  + WarehouseManager（资产管理器）单测：
//    · 契约模型宽容解码（WarehouseEntry 全可选/score Int-Double 混合、EmbeddingStatus、
//      KnowledgeGroup、KnowledgeImportResult、open-dir 200 但 ok:false 形态）
//    · KnowledgeFormat.normalizeNewFileName（.md 后缀归一与非法输入）
//    · KnowledgeTabViewModel：CRUD 调用链 / toggle HTTP 错误呈现 detail 仍重拉 /
//      删除确认门 / 资源变更事件过滤（editing 守卫、非 knowledge 忽略、gap 重拉）
//    · MemoryTabViewModel：双 scope 载入 / 保存 flash 消隐 / 失败文案与 msgIsError
//    · SkillsTabViewModel：表单读写路径（新建 POST / 编辑 PUT）/ 空名门禁 /
//      安装空地址门禁 / 删除确认门
//    · WarehousePanelViewModel：挂载列全量 / 过期响应丢弃 / 空查询走 entries 非空走 search /
//      无项目禁用 project 作用域 / 勾选注入链 / scoreText 与 emptyHint 三分支
//    · WarehouseManagerViewModel：分组+嵌入状态独立拉取 / 重建索引 / open-dir ok:false 呈现 /
//      导入两趟冲突链（ask→overwrite 合并、ask→取消计 skipped）/ baseName /
//      importSummary / conflictMessage 逐字
//

import XCTest
@testable import VetarAINative

// MARK: - W3 Mock 客户端（三协议方法均可注入/记录）

final class W3MockClient: KnowledgePanelClient, WarehousePanelClient, WarehouseManagerClient {
    let baseURL = URL(string: "http://127.0.0.1:1/api")!

    // ── 注入结果 ──
    var knowledgeItems: [KnowledgeFileItem] = []
    var knowledgeContent = KnowledgeFileContent(name: "", content: "")
    var knowledgeError: Error?
    var readKnowledgeError: Error?
    var writeKnowledgeError: Error?
    var deleteKnowledgeError: Error?
    var toggleKnowledgeError: Error?

    var memoryContent = MemoryContent(scope: "global", content: "")
    var writeMemoryError: Error?

    var skillItems: [SkillItem] = []
    var skillDetail = SkillDetail(name: "", dir_name: "")
    var skillsError: Error?
    var saveSkillError: Error?
    var toggleSkillError: Error?
    var deleteSkillError: Error?
    var installSkillError: Error?

    var warehouseEntries: [WarehouseEntry] = []
    var warehouseSearchResults: [WarehouseEntry] = []
    var warehouseListError: Error?
    var warehouseSearchError: Error?
    var injectError: Error?
    var injectText = "【知识：t】\nbody"
    /// 列全量人为延迟（过期响应测试用）
    var listDelayNanos: UInt64 = 0

    var groups: [KnowledgeGroup] = []
    var groupsError: Error?
    var embedStatus = EmbeddingStatus(available: true, entries_total: 3, entries_embedded: 2)
    var embedStatusError: Error?
    var rebuildError: Error?
    var openDirResult = KnowledgeOpenDirResult(ok: true, dir: "/tmp/k")
    var openDirError: Error?
    var importResults: [KnowledgeImportResult] = []   // 逐趟出队
    var importError: Error?

    // ── 调用记录 ──
    private(set) var writeKnowledgeCalls: [(projectId: String, name: String, content: String)] = []
    private(set) var deleteKnowledgeCalls: [String] = []
    private(set) var toggleKnowledgeCalls: [String] = []
    private(set) var readKnowledgeCalls: [String] = []
    private(set) var writeMemoryCalls: [(scope: String, projectId: String?, content: String)] = []
    private(set) var createSkillCalls: [(name: String, description: String, body: String)] = []
    private(set) var updateSkillCalls: [(dirName: String, description: String, body: String)] = []
    private(set) var toggleSkillCalls: [String] = []
    private(set) var deleteSkillCalls: [String] = []
    private(set) var installSkillCalls: [String] = []
    private(set) var searchCalls: [(query: String, scope: String, mode: String, limit: Int)] = []
    private(set) var listEntriesCalls: [(scope: String, projectId: String?)] = []
    private(set) var injectCalls: [[String]] = []
    private(set) var rebuildCalls = 0
    private(set) var openDirCalls: [(scope: String, projectId: String?)] = []
    private(set) var importCalls: [(paths: [String], onConflict: String)] = []

    // 资源变更流控制
    private var streamContinuation: AsyncThrowingStream<SSEEvent, Error>.Continuation?
    func pushStreamEvent(_ ev: SSEEvent) { streamContinuation?.yield(ev) }

    // MARK: SidecarClientProtocol 基础桩

    func probeReady() async throws -> Bool { true }
    func listModels() async throws -> [OllamaModel] { [] }
    func listProjects() async throws -> [SidecarProject] { [] }
    func createProject(name: String, workingDir: String) async throws -> String { "p1" }
    func listAgents(projectId: String) async throws -> [SidecarAgent] { [] }
    func createAgent(projectId: String, name: String, type: String, modelName: String?) async throws -> String { "a1" }
    func listSessions(projectId: String, agentId: String) async throws -> [ChatSession] { [] }
    func createSession(projectId: String, agentId: String, title: String) async throws -> String { "s1" }
    func loadMessages(projectId: String, sessionId: String) async throws -> [ChatMessage] { [] }
    func stopChat(sessionId: String) async throws {}
    func respondAuth(_ body: AuthRespondRequest) async throws {}
    func chatStream(_ body: ChatStreamRequest) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    // MARK: KnowledgePanelClient

    func listKnowledge(projectId: String) async throws -> [KnowledgeFileItem] {
        if let knowledgeError { throw knowledgeError }
        return knowledgeItems
    }
    func readKnowledge(projectId: String, name: String) async throws -> KnowledgeFileContent {
        readKnowledgeCalls.append(name)
        if let readKnowledgeError { throw readKnowledgeError }
        return knowledgeContent
    }
    func writeKnowledge(projectId: String, name: String, content: String) async throws {
        writeKnowledgeCalls.append((projectId, name, content))
        if let writeKnowledgeError { throw writeKnowledgeError }
    }
    func deleteKnowledge(projectId: String, name: String) async throws {
        deleteKnowledgeCalls.append(name)
        if let deleteKnowledgeError { throw deleteKnowledgeError }
    }
    func toggleKnowledge(projectId: String, name: String) async throws -> String {
        toggleKnowledgeCalls.append(name)
        if let toggleKnowledgeError { throw toggleKnowledgeError }
        return name.hasPrefix("_") ? String(name.dropFirst()) : "_" + name
    }
    func readMemory(scope: String, projectId: String?) async throws -> MemoryContent {
        MemoryContent(scope: scope, content: memoryContent.content)
    }
    func writeMemory(scope: String, projectId: String?, content: String) async throws {
        writeMemoryCalls.append((scope, projectId, content))
        if let writeMemoryError { throw writeMemoryError }
    }
    func listSkills() async throws -> [SkillItem] {
        if let skillsError { throw skillsError }
        return skillItems
    }
    func readSkill(dirName: String) async throws -> SkillDetail { skillDetail }
    func createSkill(name: String, description: String, body: String, enabled: Bool) async throws {
        createSkillCalls.append((name, description, body))
        if let saveSkillError { throw saveSkillError }
    }
    func updateSkill(dirName: String, description: String, body: String, enabled: Bool) async throws {
        updateSkillCalls.append((dirName, description, body))
        if let saveSkillError { throw saveSkillError }
    }
    func deleteSkill(dirName: String) async throws {
        deleteSkillCalls.append(dirName)
        if let deleteSkillError { throw deleteSkillError }
    }
    func toggleSkill(dirName: String) async throws -> Bool {
        toggleSkillCalls.append(dirName)
        if let toggleSkillError { throw toggleSkillError }
        return true
    }
    func installSkill(url: String) async throws {
        installSkillCalls.append(url)
        if let installSkillError { throw installSkillError }
    }
    func appEventsStream(since: Int) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { cont in self.streamContinuation = cont }
    }

    // MARK: WarehousePanelClient

    func listWarehouseEntries(scope: String, projectId: String?) async throws -> [WarehouseEntry] {
        listEntriesCalls.append((scope, projectId))
        if listDelayNanos > 0 { try? await Task.sleep(nanoseconds: listDelayNanos) }
        if let warehouseListError { throw warehouseListError }
        return warehouseEntries
    }
    func searchWarehouse(query: String, scope: String, projectId: String?,
                         mode: String, limit: Int) async throws -> [WarehouseEntry] {
        searchCalls.append((query, scope, mode, limit))
        if let warehouseSearchError { throw warehouseSearchError }
        return warehouseSearchResults
    }
    func injectWarehouseEntries(entryIds: [String]) async throws -> String {
        injectCalls.append(entryIds)
        if let injectError { throw injectError }
        return injectText
    }

    // MARK: WarehouseManagerClient

    func listKnowledgeGroups() async throws -> [KnowledgeGroup] {
        if let groupsError { throw groupsError }
        return groups
    }
    func fetchEmbeddingStatus() async throws -> EmbeddingStatus {
        if let embedStatusError { throw embedStatusError }
        return embedStatus
    }
    func rebuildKnowledgeIndex() async throws -> KnowledgeRebuildResult {
        rebuildCalls += 1
        if let rebuildError { throw rebuildError }
        return KnowledgeRebuildResult(ok: true, entries: 7)
    }
    func openKnowledgeDir(scope: String, projectId: String?) async throws -> KnowledgeOpenDirResult {
        openDirCalls.append((scope, projectId))
        if let openDirError { throw openDirError }
        return openDirResult
    }
    func importKnowledgeFiles(scope: String, projectId: String?, paths: [String],
                              onConflict: String) async throws -> KnowledgeImportResult {
        importCalls.append((paths, onConflict))
        if let importError { throw importError }
        if !importResults.isEmpty { return importResults.removeFirst() }
        return KnowledgeImportResult()
    }
}

// MARK: - 测试工具

@MainActor
private func makeW3AppState(client: W3MockClient) -> AppState {
    TestRuntimeSupport.makeAppState(client: client)
}

@MainActor
private func w3WaitFor(_ timeoutMs: UInt64 = 2000,
                       _ cond: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
    while Date() < deadline {
        if cond() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return cond()
}

private func w3Sse(_ event: String, _ data: [String: Any] = [:]) -> SSEEvent {
    SSEEvent(event: event, data: data, rawData: "")
}

// MARK: - 契约模型解码

final class W3ContractDecodeTests: XCTestCase {

    func testKnowledgeFileItemDecode() throws {
        let json = #"[{"name":"a.md","size":128,"enabled":true},{"name":"_b.md","size":0,"enabled":false}]"#
        let items = try JSONDecoder().decode([KnowledgeFileItem].self, from: Data(json.utf8))
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0], KnowledgeFileItem(name: "a.md", size: 128, enabled: true))
        XCTAssertEqual(items[1].name, "_b.md")
        XCTAssertFalse(items[1].enabled)
    }

    func testSkillItemDecode() throws {
        let json = #"[{"name":"调研","dir_name":"research","description":"查资料","enabled":true,"path":"/x/SKILL.md"}]"#
        let items = try JSONDecoder().decode([SkillItem].self, from: Data(json.utf8))
        XCTAssertEqual(items[0].dir_name, "research")
        XCTAssertEqual(items[0].path, "/x/SKILL.md")
    }

    func testSkillDetailDecode() throws {
        let json = #"{"name":"调研","dir_name":"research","description":"d","enabled":false,"content":"正文"}"#
        let d = try JSONDecoder().decode(SkillDetail.self, from: Data(json.utf8))
        XCTAssertEqual(d.content, "正文")
        XCTAssertFalse(d.enabled)
    }

    func testWarehouseEntryFullDecode() throws {
        let json = #"{"id":"e1","title":"标题","scope":"project","project_id":"p1","category":"笔记","keywords":["a","b"],"source":"chat","file_path":"/k/e1.md","created_at":"2026-09-12 10:00","body":"正文","score":0.42}"#
        let e = try JSONDecoder().decode(WarehouseEntry.self, from: Data(json.utf8))
        XCTAssertEqual(e.id, "e1")
        XCTAssertEqual(e.project_id, "p1")
        XCTAssertEqual(e.keywords, ["a", "b"])
        XCTAssertEqual(e.score, 0.42)
        XCTAssertEqual(e.body, "正文")
    }

    func testWarehouseEntryToleratesMissingAndIntScore() throws {
        // 列表形态：无 body/score/keywords；score 以 Int 到达也宽容
        let listJson = #"{"id":"e2","title":"t","scope":"global"}"#
        let e = try JSONDecoder().decode(WarehouseEntry.self, from: Data(listJson.utf8))
        XCTAssertEqual(e.id, "e2")
        XCTAssertNil(e.score)
        XCTAssertNil(e.body)

        let intScore = #"{"id":"e3","title":"t","scope":"global","score":1}"#
        let e2 = try JSONDecoder().decode(WarehouseEntry.self, from: Data(intScore.utf8))
        XCTAssertEqual(e2.score, 1.0)
    }

    func testEmbeddingStatusDecode() throws {
        let json = #"{"available":false,"model":"bge-m3-onnx-int8","model_dir":"/m","entries_total":10,"entries_embedded":4}"#
        let s = try JSONDecoder().decode(EmbeddingStatus.self, from: Data(json.utf8))
        XCTAssertFalse(s.available)
        XCTAssertEqual(s.entries_total, 10)
        XCTAssertEqual(s.entries_embedded, 4)
    }

    func testKnowledgeGroupDecodeNullableProjectId() throws {
        let json = #"[{"scope":"global","project_id":null,"project_name":"全局","count":2,"dir":"/g"},{"scope":"project","project_id":"p1","project_name":"项目A","count":0,"dir":""}]"#
        let groups = try JSONDecoder().decode([KnowledgeGroup].self, from: Data(json.utf8))
        XCTAssertEqual(groups.count, 2)
        XCTAssertNil(groups[0].project_id)
        XCTAssertEqual(groups[0].id, "global")
        XCTAssertEqual(groups[1].id, "projectp1")
    }

    func testImportResultDecode() throws {
        let json = #"{"imported":2,"failed":1,"skipped":1,"conflicts":["a.pdf"],"details":[{"name":"a.pdf","status":"conflict","reason":"知识目录已有同名文件（等你决定怎么处理）"},{"name":"b.md","status":"imported","conflict_resolved":"rename"}]}"#
        let r = try JSONDecoder().decode(KnowledgeImportResult.self, from: Data(json.utf8))
        XCTAssertEqual(r.imported, 2)
        XCTAssertEqual(r.conflicts, ["a.pdf"])
        XCTAssertEqual(r.details.count, 2)
        XCTAssertEqual(r.details[1].conflict_resolved, "rename")
    }

    func testOpenDirResultOkFalseWithDetail() throws {
        // 200 但 ok:false（非 macOS/超时）形态
        let json = #"{"ok":false,"dir":"/k","detail":"打开超时"}"#
        let r = try JSONDecoder().decode(KnowledgeOpenDirResult.self, from: Data(json.utf8))
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.detail, "打开超时")
    }

    func testMemoryAndInjectDecode() throws {
        let mem = try JSONDecoder().decode(MemoryContent.self, from: Data(#"{"scope":"global","content":"红线"}"#.utf8))
        XCTAssertEqual(mem.content, "红线")
        let inj = try JSONDecoder().decode(KnowledgeInjectResponse.self, from: Data(#"{"ok":true,"text":"【知识：t】\n\nb"}"#.utf8))
        XCTAssertEqual(inj.text, "【知识：t】\n\nb")
    }
}

// MARK: - 纯函数

final class W3FormatTests: XCTestCase {

    func testNormalizeNewFileName() {
        XCTAssertEqual(KnowledgeFormat.normalizeNewFileName("笔记"), "笔记.md")
        XCTAssertEqual(KnowledgeFormat.normalizeNewFileName("笔记.md"), "笔记.md")
        XCTAssertEqual(KnowledgeFormat.normalizeNewFileName("  a.md  "), "a.md")
        // 对齐 TSX：endsWith('.md') 大小写敏感，"X.MD" 会再补一遍
        XCTAssertEqual(KnowledgeFormat.normalizeNewFileName("X.MD"), "X.MD.md")
        XCTAssertNil(KnowledgeFormat.normalizeNewFileName(""))
        XCTAssertNil(KnowledgeFormat.normalizeNewFileName("   "))
        XCTAssertNil(KnowledgeFormat.normalizeNewFileName(".md"))
    }

    func testScoreText() {
        XCTAssertEqual(WarehousePanelViewModel.scoreText(0.5), "50%")
        XCTAssertEqual(WarehousePanelViewModel.scoreText(0.01), "1%")
        XCTAssertEqual(WarehousePanelViewModel.scoreText(0.005), "0.005")
        XCTAssertEqual(WarehousePanelViewModel.scoreText(0.999), "100%")
    }

    func testBaseName() {
        XCTAssertEqual(WarehouseManagerViewModel.baseName("/a/b/c.md"), "c.md")
        XCTAssertEqual(WarehouseManagerViewModel.baseName("C:\\docs\\c.pdf"), "c.pdf")
        XCTAssertEqual(WarehouseManagerViewModel.baseName("solo.txt"), "solo.txt")
    }

    func testImportSummary() {
        XCTAssertEqual(WarehouseManagerViewModel.importSummary(
            imported: 2, skipped: 1, failed: 1, conflictCount: 3), "导入 2 个，跳过 1 个，失败 1 个，同名 3 个")
        XCTAssertEqual(WarehouseManagerViewModel.importSummary(
            imported: 0, skipped: 0, failed: 0, conflictCount: 0), "未导入任何文件")
        XCTAssertEqual(WarehouseManagerViewModel.importSummary(
            imported: 1, skipped: 0, failed: 0, conflictCount: 0), "导入 1 个")
    }

    func testConflictMessage() {
        let few = WarehouseManagerViewModel.conflictMessage(["a.md", "b.md"])
        XCTAssertEqual(few, "2 个文件在知识目录里已有同名：\na.md\nb.md\n\n要如何处理？（你的本机原始文件不会被改动）")
        let many = WarehouseManagerViewModel.conflictMessage((1...10).map { "f\($0).md" })
        XCTAssertTrue(many.contains("f8.md"))
        XCTAssertFalse(many.contains("f9.md"))
        XCTAssertTrue(many.contains("\n…等共 10 个"))
    }
}

// MARK: - KnowledgeTabViewModel

@MainActor
final class KnowledgeTabViewModelTests: XCTestCase {

    private func makeVM(client: W3MockClient, projectId: String? = "p1") -> (KnowledgeTabViewModel, AppState) {
        let appState = makeW3AppState(client: client)
        appState.currentProjectId = projectId
        let vm = KnowledgeTabViewModel(appState: appState, clientOverride: client)
        return (vm, appState)
    }

    func testRefreshPopulatesItems() async {
        let client = W3MockClient()
        client.knowledgeItems = [KnowledgeFileItem(name: "a.md", size: 1, enabled: true),
                                 KnowledgeFileItem(name: "_b.md", size: 2, enabled: false)]
        let (vm, _) = makeVM(client: client)
        await vm.refresh()
        XCTAssertEqual(vm.items.map(\.name), ["a.md", "_b.md"])
        XCTAssertTrue(vm.loaded)
    }

    func testRefreshWithoutProjectClearsItems() async {
        let client = W3MockClient()
        client.knowledgeItems = [KnowledgeFileItem(name: "a.md")]
        let (vm, _) = makeVM(client: client, projectId: nil)
        await vm.refresh()
        XCTAssertTrue(vm.items.isEmpty)
    }

    func testOpenEditLoadsContent() async {
        let client = W3MockClient()
        client.knowledgeContent = KnowledgeFileContent(name: "a.md", content: "你好")
        let (vm, _) = makeVM(client: client)
        vm.openEdit("a.md")
        let __w3ok1 = await w3WaitFor { vm.editing == "a.md" }
        XCTAssertTrue(__w3ok1)
        XCTAssertEqual(vm.editContent, "你好")
        XCTAssertNil(vm.error)
    }

    func testCreateNewWritesEmptyAndClearsDraft() async {
        let client = W3MockClient()
        let (vm, _) = makeVM(client: client)
        vm.newName = " 新文件 "
        vm.createNew()
        let __w3ok2 = await w3WaitFor { !client.writeKnowledgeCalls.isEmpty }
        XCTAssertTrue(__w3ok2)
        XCTAssertEqual(client.writeKnowledgeCalls.first?.name, "新文件.md")
        XCTAssertEqual(client.writeKnowledgeCalls.first?.content, "")
        XCTAssertEqual(vm.newName, "")
    }

    func testCreateNewRejectsEmptyName() async {
        let client = W3MockClient()
        let (vm, _) = makeVM(client: client)
        vm.newName = "   "
        vm.createNew()
        XCTAssertEqual(vm.error, "请输入文件名")
        XCTAssertTrue(client.writeKnowledgeCalls.isEmpty)
    }

    func testSaveEditWritesThenClearsEditing() async {
        let client = W3MockClient()
        let (vm, _) = makeVM(client: client)
        vm.openEdit("a.md")
        _ = await w3WaitFor { vm.editing == "a.md" }
        vm.editContent = "改后"
        vm.saveEdit("a.md")
        let __w3ok3 = await w3WaitFor { !client.writeKnowledgeCalls.isEmpty }
        XCTAssertTrue(__w3ok3)
        XCTAssertEqual(client.writeKnowledgeCalls.first?.content, "改后")
        let __w3ok4 = await w3WaitFor { vm.editing == nil }
        XCTAssertTrue(__w3ok4)
    }

    func testToggleHttpErrorShowsDetailAndRefreshes() async {
        let client = W3MockClient()
        client.toggleKnowledgeError = SidecarError.httpError(status: 400, detail: "切换失败（文件不存在或同名冲突）")
        let (vm, _) = makeVM(client: client)
        vm.toggle("a.md")
        let __w3ok5 = await w3WaitFor { vm.error != nil }
        XCTAssertTrue(__w3ok5)
        XCTAssertEqual(vm.error, "切换失败（文件不存在或同名冲突）")
        let __w3okT1 = await w3WaitFor { vm.loaded }   // HTTP 错误也重拉（对齐 TSX）
        XCTAssertTrue(__w3okT1)
    }

    func testRemoveRequiresConfirm() async {
        let client = W3MockClient()
        let (vm, _) = makeVM(client: client)
        vm.confirmHandler = { _, _ in false }
        vm.remove("a.md")
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(client.deleteKnowledgeCalls.isEmpty)

        vm.confirmHandler = { title, message in
            XCTAssertEqual(title, "删除知识文件")
            XCTAssertEqual(message, "删除知识文件 a.md？")
            return true
        }
        vm.remove("a.md")
        let __w3ok6 = await w3WaitFor { !client.deleteKnowledgeCalls.isEmpty }
        XCTAssertTrue(__w3ok6)
        XCTAssertEqual(client.deleteKnowledgeCalls, ["a.md"])
    }

    // A13 事件流：knowledge 资源变更 → 重拉；editing 中跳过；其他资源忽略；gap 重拉
    func testResourceEventFiltering() async {
        let client = W3MockClient()
        client.knowledgeItems = [KnowledgeFileItem(name: "a.md")]
        let (vm, _) = makeVM(client: client)

        // 非 knowledge 资源：忽略
        vm.apply(event: w3Sse("resource_changed", ["resource": "model_pack", "action": "update"]))
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(vm.loaded)

        // knowledge 资源：重拉
        vm.apply(event: w3Sse("resource_changed", ["resource": "knowledge", "action": "update"]))
        let __w3ok7 = await w3WaitFor { !vm.items.isEmpty }
        XCTAssertTrue(__w3ok7)
    }

    func testEditingGuardSkipsRefresh() async {
        let client = W3MockClient()
        client.knowledgeContent = KnowledgeFileContent(name: "a.md", content: "原文")
        let (vm, _) = makeVM(client: client)
        vm.openEdit("a.md")
        _ = await w3WaitFor { vm.editing == "a.md" }
        // editing 中收到 knowledge 事件 → 不重拉
        vm.apply(event: w3Sse("resource_changed", ["resource": "knowledge", "action": "update"]))
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(vm.items.isEmpty)   // refresh 未发生
        // gap 同样被守卫
        vm.apply(event: w3Sse("gap"))
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(vm.items.isEmpty)
    }
}

// MARK: - MemoryTabViewModel

@MainActor
final class MemoryTabViewModelTests: XCTestCase {

    func testLoadPopulatesBothScopes() async {
        let client = W3MockClient()
        client.memoryContent = MemoryContent(scope: "global", content: "全局内容")
        let appState = makeW3AppState(client: client)
        appState.currentProjectId = "p1"
        let vm = MemoryTabViewModel(appState: appState, clientOverride: client)
        vm.load()
        let __w3ok8 = await w3WaitFor { vm.loaded }
        XCTAssertTrue(__w3ok8)
        XCTAssertEqual(vm.globalMem, "全局内容")
        XCTAssertEqual(vm.projectMem, "全局内容")   // mock 两份同内容，验证两路都拉到
    }

    func testSaveGlobalFlashesThenClears() async {
        let client = W3MockClient()
        let appState = makeW3AppState(client: client)
        let vm = MemoryTabViewModel(appState: appState, clientOverride: client,
                                    flashInterval: 0.2)
        vm.globalMem = "禁止撒谎"
        vm.save(scope: "global")
        let __w3ok9 = await w3WaitFor { vm.msg == "已保存 ✓" }
        XCTAssertTrue(__w3ok9)
        XCTAssertFalse(vm.msgIsError)
        XCTAssertEqual(client.writeMemoryCalls.first?.scope, "global")
        XCTAssertEqual(client.writeMemoryCalls.first?.content, "禁止撒谎")
        let __w3okM1 = await w3WaitFor { vm.msg == nil }   // 2500ms（测试 200ms）消隐
        XCTAssertTrue(__w3okM1)
    }

    func testSaveFailureMessage() async {
        let client = W3MockClient()
        client.writeMemoryError = SidecarError.httpError(status: 400, detail: "保存失败（项目记忆需要有效的项目工作目录）")
        let appState = makeW3AppState(client: client)
        let vm = MemoryTabViewModel(appState: appState, clientOverride: client,
                                    flashInterval: 10)
        vm.save(scope: "project")
        let __w3ok10 = await w3WaitFor { vm.msg != nil }
        XCTAssertTrue(__w3ok10)
        XCTAssertTrue(vm.msgIsError)
        XCTAssertTrue(vm.msg?.hasPrefix("保存失败") == true)
    }
}

// MARK: - SkillsTabViewModel

@MainActor
final class SkillsTabViewModelTests: XCTestCase {

    private func makeVM(client: W3MockClient) -> SkillsTabViewModel {
        SkillsTabViewModel(appState: makeW3AppState(client: client), clientOverride: client)
    }

    func testRefreshPopulates() async {
        let client = W3MockClient()
        client.skillItems = [SkillItem(name: "调研", dir_name: "research", description: "d")]
        let vm = makeVM(client: client)
        vm.refresh()
        let __w3ok11 = await w3WaitFor { vm.loaded }
        XCTAssertTrue(__w3ok11)
        XCTAssertEqual(vm.skills.map(\.dir_name), ["research"])
    }

    func testOpenEditFillsForm() async {
        let client = W3MockClient()
        client.skillDetail = SkillDetail(name: "调研", dir_name: "research",
                                         description: "查资料", enabled: true, content: "正文")
        let vm = makeVM(client: client)
        vm.openEdit("research")
        let __w3ok12 = await w3WaitFor { vm.editing == "research" }
        XCTAssertTrue(__w3ok12)
        XCTAssertEqual(vm.form.name, "调研")
        XCTAssertEqual(vm.form.description, "查资料")
        XCTAssertEqual(vm.form.body, "正文")
        XCTAssertTrue(vm.formVisible)
        XCTAssertFalse(vm.savingIsNew)
    }

    func testSaveNewPostsCreate() async {
        let client = W3MockClient()
        let vm = makeVM(client: client)
        vm.toggleCreating()
        vm.form.name = " 新技能 "
        vm.form.description = "d"
        vm.form.body = "b"
        vm.save()
        let __w3ok13 = await w3WaitFor { !client.createSkillCalls.isEmpty }
        XCTAssertTrue(__w3ok13)
        XCTAssertEqual(client.createSkillCalls.first?.name, "新技能")   // 去首尾空白
        let __w3ok14 = await w3WaitFor { !vm.formVisible && vm.form.name.isEmpty }
        XCTAssertTrue(__w3ok14)
    }

    func testSaveEditPutsUpdate() async {
        let client = W3MockClient()
        client.skillDetail = SkillDetail(name: "调研", dir_name: "research", content: "旧")
        let vm = makeVM(client: client)
        vm.openEdit("research")
        _ = await w3WaitFor { vm.editing == "research" }
        vm.form.body = "新正文"
        vm.save()
        let __w3ok15 = await w3WaitFor { !client.updateSkillCalls.isEmpty }
        XCTAssertTrue(__w3ok15)
        XCTAssertEqual(client.updateSkillCalls.first?.dirName, "research")
        XCTAssertEqual(client.updateSkillCalls.first?.body, "新正文")
        XCTAssertTrue(client.createSkillCalls.isEmpty)
    }

    func testSaveRejectsEmptyName() async {
        let client = W3MockClient()
        let vm = makeVM(client: client)
        vm.toggleCreating()
        vm.form.name = "   "
        vm.save()
        XCTAssertEqual(vm.error, "请输入技能名")
        XCTAssertTrue(client.createSkillCalls.isEmpty)
    }

    func testToggleHttpErrorShowsDetailAndRefreshes() async {
        let client = W3MockClient()
        client.toggleSkillError = SidecarError.httpError(status: 400, detail: "切换失败（技能不存在）")
        let vm = makeVM(client: client)
        vm.toggle("research")
        let __w3ok16 = await w3WaitFor { vm.error == "切换失败（技能不存在）" }
        XCTAssertTrue(__w3ok16)
        let __w3okS1 = await w3WaitFor { vm.loaded }   // HTTP 错误也重拉
        XCTAssertTrue(__w3okS1)
    }

    func testRemoveRequiresConfirm() async {
        let client = W3MockClient()
        let vm = makeVM(client: client)
        vm.confirmHandler = { _, _ in false }
        vm.remove("research")
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(client.deleteSkillCalls.isEmpty)

        vm.confirmHandler = { _, _ in true }
        vm.remove("research")
        let __w3ok17 = await w3WaitFor { client.deleteSkillCalls == ["research"] }
        XCTAssertTrue(__w3ok17)
    }

    func testInstallGuardsAndSuccess() async {
        let client = W3MockClient()
        let vm = makeVM(client: client)
        vm.installUrl = "   "
        vm.install()
        XCTAssertEqual(vm.error, "请输入仓库地址或本地路径")
        XCTAssertTrue(client.installSkillCalls.isEmpty)

        vm.installUrl = " https://example.com/skill.git "
        vm.install()
        let __w3ok18 = await w3WaitFor { !client.installSkillCalls.isEmpty }
        XCTAssertTrue(__w3ok18)
        XCTAssertEqual(client.installSkillCalls.first, "https://example.com/skill.git")
        let __w3ok19 = await w3WaitFor { vm.installUrl.isEmpty }
        XCTAssertTrue(__w3ok19)
    }
}

// MARK: - WarehousePanelViewModel

@MainActor
final class WarehousePanelViewModelTests: XCTestCase {

    private func makeVM(client: W3MockClient, projectId: String? = "p1",
                        initialScope: WarehouseScope? = nil)
        -> (WarehousePanelViewModel, AppState) {
        let appState = makeW3AppState(client: client)
        appState.currentProjectId = projectId
        let vm = WarehousePanelViewModel(appState: appState, clientOverride: client,
                                         initialScope: initialScope)
        return (vm, appState)
    }

    func testInitialScopeFollowsTransferTarget() async {
        let client = W3MockClient()
        let (vm, _) = makeVM(client: client, initialScope: .global)
        XCTAssertEqual(vm.scope, .global)
    }

    func testNoProjectForcesGlobalScope() async {
        let client = W3MockClient()
        let (vm, _) = makeVM(client: client, projectId: nil, initialScope: .project)
        XCTAssertEqual(vm.scope, .global)
        vm.setScope(.project)   // 无项目禁用本项目
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(vm.scope, .global)
        XCTAssertTrue(client.listEntriesCalls.isEmpty)
    }

    func testLoadEntriesPopulatesAndClearsChecked() async {
        let client = W3MockClient()
        client.warehouseEntries = [WarehouseEntry(id: "e1", title: "t1", scope: "project")]
        let (vm, _) = makeVM(client: client)
        vm.toggleCheck("e1")
        await vm.loadEntries()
        XCTAssertEqual(vm.results.map(\.id), ["e1"])
        XCTAssertTrue(vm.checked.isEmpty)
        XCTAssertEqual(client.listEntriesCalls.first?.scope, "project")
        XCTAssertEqual(client.listEntriesCalls.first?.projectId, "p1")
    }

    func testScopeSwitchReloads() async {
        let client = W3MockClient()
        client.warehouseEntries = [WarehouseEntry(id: "g1", title: "g", scope: "global")]
        let (vm, _) = makeVM(client: client)
        vm.setScope(.global)
        let __w3ok20 = await w3WaitFor { !vm.results.isEmpty }
        XCTAssertTrue(__w3ok20)
        XCTAssertEqual(client.listEntriesCalls.last?.scope, "global")
        XCTAssertNil(client.listEntriesCalls.last?.projectId)
    }

    /// 过期响应丢弃（对齐 TSX cancelled 守卫）：慢的第一趟不得覆盖快的第二趟。
    func testStaleLoadResponseDropped() async {
        let client = W3MockClient()
        let (vm, _) = makeVM(client: client)
        client.listDelayNanos = 300_000_000
        client.warehouseEntries = [WarehouseEntry(id: "old", title: "旧", scope: "project")]
        async let first: () = vm.loadEntries()
        try? await Task.sleep(nanoseconds: 50_000_000)
        client.listDelayNanos = 0
        client.warehouseEntries = [WarehouseEntry(id: "new", title: "新", scope: "project")]
        async let second: () = vm.loadEntries()
        _ = await (first, second)
        XCTAssertEqual(vm.results.map(\.id), ["new"])
    }

    func testSearchRoutingByQuery() async {
        let client = W3MockClient()
        client.warehouseSearchResults = [WarehouseEntry(id: "s1", title: "命中", scope: "project", score: 0.5)]
        let (vm, _) = makeVM(client: client)
        // 空查询 → entries 端点
        vm.query = "   "
        vm.doSearch()
        let __w3ok21 = await w3WaitFor { !client.listEntriesCalls.isEmpty }
        XCTAssertTrue(__w3ok21)
        XCTAssertTrue(client.searchCalls.isEmpty)
        // 非空 → search 端点带 mode
        vm.query = " 部署流程 "
        vm.searchMode = .semantic
        vm.doSearch()
        let __w3ok22 = await w3WaitFor { !client.searchCalls.isEmpty }
        XCTAssertTrue(__w3ok22)
        XCTAssertEqual(client.searchCalls.first?.query, "部署流程")   // trim 后发出
        XCTAssertEqual(client.searchCalls.first?.mode, "semantic")
        XCTAssertEqual(vm.results.map(\.id), ["s1"])
    }

    func testSearchFailureClearsResults() async {
        let client = W3MockClient()
        client.warehouseEntries = [WarehouseEntry(id: "e1", title: "t", scope: "project")]
        let (vm, _) = makeVM(client: client)
        await vm.loadEntries()
        XCTAssertEqual(vm.results.count, 1)
        client.warehouseSearchError = SidecarError.offline("down")
        vm.query = "x"
        vm.doSearch()
        let __w3ok23 = await w3WaitFor { vm.results.isEmpty && !vm.searching }
        XCTAssertTrue(__w3ok23)
    }

    func testInjectChain() async {
        let client = W3MockClient()
        let (vm, _) = makeVM(client: client)
        var injected: String?
        vm.onInject = { injected = $0 }
        // 0 条不动
        vm.inject()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(client.injectCalls.isEmpty)
        // 勾选后注入
        vm.toggleCheck("e1")
        vm.toggleCheck("e2")
        vm.toggleCheck("e1")   // 再点取消
        vm.inject()
        let __w3ok24 = await w3WaitFor { injected != nil }
        XCTAssertTrue(__w3ok24)
        XCTAssertEqual(client.injectCalls.first, ["e2"])
        XCTAssertEqual(injected, "【知识：t】\nbody")
        XCTAssertTrue(vm.checked.isEmpty)
    }

    func testEmptyHintBranches() async {
        let client = W3MockClient()
        let (vm, _) = makeVM(client: client)
        XCTAssertEqual(vm.emptyHint, "暂无知识条目")
        vm.query = "abc"
        XCTAssertEqual(vm.emptyHint, "无匹配结果")
    }
}

// MARK: - WarehouseManagerViewModel

@MainActor
final class WarehouseManagerViewModelTests: XCTestCase {

    private func makeVM(client: W3MockClient) -> WarehouseManagerViewModel {
        WarehouseManagerViewModel(appState: makeW3AppState(client: client), clientOverride: client)
    }

    private func sampleGroups() -> [KnowledgeGroup] {
        [KnowledgeGroup(scope: "global", project_name: "全局", count: 2, dir: "/g"),
         KnowledgeGroup(scope: "project", project_id: "p1", project_name: "项目A", count: 0, dir: "")]
    }

    func testRefreshPopulatesGroupsAndEmbedStatus() async {
        let client = W3MockClient()
        client.groups = sampleGroups()
        let vm = makeVM(client: client)
        await vm.refresh()
        XCTAssertEqual(vm.groups.count, 2)
        XCTAssertEqual(vm.embedStatus?.entries_embedded, 2)
        XCTAssertNil(vm.error)
        XCTAssertFalse(vm.loading)
    }

    func testGroupsErrorButEmbedStatusIndependent() async {
        let client = W3MockClient()
        client.groupsError = SidecarError.offline("down")
        let vm = makeVM(client: client)
        await vm.refresh()
        XCTAssertTrue(vm.error?.hasPrefix("加载知识仓库失败") == true)
        XCTAssertNotNil(vm.embedStatus)   // 嵌入状态独立拉取不受主列表失败影响
    }

    func testEmbedStatusFailureSilent() async {
        let client = W3MockClient()
        client.embedStatusError = SidecarError.offline("down")
        let vm = makeVM(client: client)
        await vm.refresh()
        XCTAssertNil(vm.error)
        XCTAssertNil(vm.embedStatus)
    }

    func testRebuildCallsAndRefreshes() async {
        let client = W3MockClient()
        client.groups = sampleGroups()
        let vm = makeVM(client: client)
        vm.rebuild()
        let __w3ok25 = await w3WaitFor { client.rebuildCalls == 1 }
        XCTAssertTrue(__w3ok25)
        let __w3ok26 = await w3WaitFor { !vm.groups.isEmpty }
        XCTAssertTrue(__w3ok26)
    }

    func testRebuildError() async {
        let client = W3MockClient()
        client.rebuildError = SidecarError.httpError(status: 500, detail: "boom")
        let vm = makeVM(client: client)
        vm.rebuild()
        let __w3ok27 = await w3WaitFor { vm.error != nil }
        XCTAssertTrue(__w3ok27)
        XCTAssertTrue(vm.error?.hasPrefix("重建索引失败") == true)
    }

    func testOpenDirOkFalseSurfacesDetail() async {
        let client = W3MockClient()
        client.openDirResult = KnowledgeOpenDirResult(ok: false, dir: "/g", detail: "打开超时")
        let vm = makeVM(client: client)
        vm.openDir(sampleGroups()[0])
        let __w3ok28 = await w3WaitFor { vm.error == "打开文件夹失败: 打开超时" }
        XCTAssertTrue(__w3ok28)
        XCTAssertNil(vm.opening)
    }

    func testImportWithoutConflictsSinglePass() async {
        let client = W3MockClient()
        client.groups = sampleGroups()
        client.importResults = [KnowledgeImportResult(imported: 2)]
        let vm = makeVM(client: client)
        vm.importFiles(sampleGroups()[0], paths: ["/u/a.md", "/u/b.md"])
        let __w3ok29 = await w3WaitFor { vm.info != nil }
        XCTAssertTrue(__w3ok29)
        XCTAssertEqual(client.importCalls.count, 1)
        XCTAssertEqual(client.importCalls.first?.onConflict, "ask")
        XCTAssertEqual(vm.info, "导入 2 个")
        XCTAssertNil(vm.importing)
    }

    /// 冲突链：ask → 用户选 overwrite → 只重传冲突路径，两趟结果相加。
    func testImportConflictOverwriteMerges() async {
        let client = W3MockClient()
        client.groups = sampleGroups()
        client.importResults = [
            KnowledgeImportResult(imported: 1, conflicts: ["b.md"],
                                  details: [KnowledgeImportDetail(name: "a.md", status: "imported"),
                                            KnowledgeImportDetail(name: "b.md", status: "conflict")]),
            KnowledgeImportResult(imported: 1,
                                  details: [KnowledgeImportDetail(name: "b.md", status: "imported",
                                                                  conflict_resolved: "overwrite")]),
        ]
        let vm = makeVM(client: client)
        vm.choiceHandler = { title, message in
            XCTAssertEqual(title, "知识目录已有同名文件")
            XCTAssertTrue(message.contains("b.md"))
            return "overwrite"
        }
        vm.importFiles(sampleGroups()[0], paths: ["/u/a.md", "/u/b.md"])
        let __w3ok30 = await w3WaitFor { vm.info != nil }
        XCTAssertTrue(__w3ok30)
        XCTAssertEqual(client.importCalls.count, 2)
        // 第二趟只重传冲突文件（basename 匹配）
        XCTAssertEqual(client.importCalls[1].paths, ["/u/b.md"])
        XCTAssertEqual(client.importCalls[1].onConflict, "overwrite")
        XCTAssertEqual(vm.info, "导入 2 个，同名 1 个")
    }

    /// 冲突链：用户选「不处理」→ 不重传，冲突计入 skipped。
    func testImportConflictCancelCountsSkipped() async {
        let client = W3MockClient()
        client.groups = sampleGroups()
        client.importResults = [
            KnowledgeImportResult(imported: 1, conflicts: ["b.md"]),
        ]
        let vm = makeVM(client: client)
        vm.choiceHandler = { _, _ in nil }
        vm.importFiles(sampleGroups()[0], paths: ["/u/a.md", "/u/b.md"])
        let __w3ok31 = await w3WaitFor { vm.info != nil }
        XCTAssertTrue(__w3ok31)
        XCTAssertEqual(client.importCalls.count, 1)
        XCTAssertEqual(vm.info, "导入 1 个，跳过 1 个，同名 1 个")
    }

    func testImportEmptyPathsNoop() async {
        let client = W3MockClient()
        let vm = makeVM(client: client)
        vm.importFiles(sampleGroups()[0], paths: [])
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(client.importCalls.isEmpty)
        XCTAssertNil(vm.info)
    }

    func testImportError() async {
        let client = W3MockClient()
        client.importError = SidecarError.httpError(status: 400, detail: "无效的 on_conflict")
        let vm = makeVM(client: client)
        vm.importFiles(sampleGroups()[0], paths: ["/u/a.md"])
        let __w3ok32 = await w3WaitFor { vm.error != nil }
        XCTAssertTrue(__w3ok32)
        XCTAssertTrue(vm.error?.hasPrefix("导入文件失败") == true)
        XCTAssertNil(vm.importing)
    }
}
