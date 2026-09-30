//
//  VPlaceholderTextEditor.swift
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

//  业主原话（2026-09-22）：「这是重复错误，之前就提到过。背景文字应当在我输入开始的
//  那一刻就消失，一起修复。」——业主实测：工作室空态需求框已开始输入（IME 候选栏
//  都出来了），占位文字仍残留与输入内容重叠。
//
//  复发根因（debug-history 已记 DBG 条目）：
//  智能中心会话输入框 2026-09-19 修过同病（ComposerTextView 问题3）——正解是
//  NSTextView 封装 + `placeholderHidden(viewString:hasMarkedText:)`（组字即算输入中）。
//  但修法没推广、组件没复用：W3-W5 工作室/工作流编辑器新输入框又用了 SwiftUI
//  TextEditor + `if text.isEmpty` 自绘占位——TextEditor 拿不到 IME 组字态，
//  组字期间绑定仍为空，占位文字压在拼音上。
//
//  本组件 = 治法推广：NSTextView 封装 + 复用 ComposerSyncPolicy 两条纯策略
//  （占位显隐 / 绑定回写守门），占位显隐永远挂「内容」（含 marked text），不挂焦点。
//  适用：一切需要占位文字的多行输入框（单行框请用原生 TextField，AppKit 占位
//  自带 IME 安全，无需本组件）。
//
//  0.7.12 实测修复 F3+F4（业主 E2E：工作室输入框 3 行中间行被裁剪滚不出 /
//  点击无光标按键 beep）：
//  F3 根因（运行中应用 AX 实证）：NSTextView frame 漂移到 1024 宽、x=-480
//    且永不回钉——1008 宽容器→不换行横向延伸（业主原始形态）；视口水平切片
//    →只渲染 1、3 行、中间行唤不出（E2E 形态）。修复 = VPinnedScrollView
//    每次 layout 把 tv 原点 x=0、宽=contentSize 宽回钉 + clip 横向原点归零
//    + 横向弹性关闭。
//  F4 根因（两处死区）：①占位 label 用普通 NSTextField 无 hitTest 穿透
//    （0.7.6 composer 修过同病没推广——复用 ComposerPassthroughLabel）；
//    ②tv 高随内容收缩（空文 ~24pt），96pt 框内下方是 NSClipView 死区，
//    点击不聚焦、按键 beep。修复 = tv minSize.height 钉到可视高，铺满剪贴区。
//

import SwiftUI
import AppKit

/// F3 根治：钉死 documentView 几何的 NSScrollView 子类——
/// 每次 layout 回钉「tv 原点 x=0 / tv 宽=可视宽 / clip 横向原点=0 / tv 至少铺满可视高」，
/// 四处不等式守门（值不同才写，不触发布局循环）。
final class VPinnedScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let tv = documentView as? NSTextView else { return }
        let visible = contentSize
        guard visible.width > 0 else { return }   // 首次布局前 0 宽不回钉（防压塌初始 frame）

        // F3①：宽度/原点回钉（实测漂移 1024 宽、x=-480 的形态一次归零）
        if tv.frame.origin.x != 0 || tv.frame.size.width != visible.width {
            tv.frame = NSRect(x: 0, y: tv.frame.origin.y,
                              width: visible.width, height: tv.frame.size.height)
        }
        // F4②：高度铺满可视区——空文点击框内下半区也落在 tv 上（聚焦有光标不 beep）
        let minH = max(24, visible.height)
        if tv.minSize.height != minH {
            tv.minSize = NSSize(width: tv.minSize.width, height: minH)
        }
        // F3②：横向绝不滚动——clip 原点 x 漂移一次归零（视口水平切片=中间行丢失之根）
        if contentView.bounds.origin.x != 0 {
            contentView.bounds = NSRect(x: 0, y: contentView.bounds.origin.y,
                                        width: contentView.bounds.width,
                                        height: contentView.bounds.height)
        }
    }
}

public struct VPlaceholderTextEditor: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var fontSize: CGFloat = 13
    var mono: Bool = false
    var placeholderColor: Color = VTheme.textTertiary
    /// 文本内边距（对齐各既有框的 .padding 口径）
    var contentInset: CGSize = CGSize(width: 8, height: 8)
    /// 可选 Cmd+Enter 提交钩子（返回 true = 已处理，不再插入换行）
    var onCommandEnter: (() -> Bool)? = nil
    /// 可选 Enter 提交钩子（0.7.6 插话条换行改造）：返回 true = 已处理不插换行；
    /// Shift+Enter 恒换行（与智能中心 ComposerTextView 同口径）
    var onSubmitEnter: (() -> Bool)? = nil

    public init(text: Binding<String>, placeholder: String,
                fontSize: CGFloat = 13, mono: Bool = false,
                placeholderColor: Color = VTheme.textTertiary,
                contentInset: CGSize = CGSize(width: 8, height: 8),
                onCommandEnter: (() -> Bool)? = nil,
                onSubmitEnter: (() -> Bool)? = nil) {
        self._text = text
        self.placeholder = placeholder
        self.fontSize = fontSize
        self.mono = mono
        self.placeholderColor = placeholderColor
        self.contentInset = contentInset
        self.onCommandEnter = onCommandEnter
        self.onSubmitEnter = onSubmitEnter
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public func makeNSView(context: Context) -> NSScrollView {
        let scroll = VPinnedScrollView()   // F3：layout 回钉几何（见类注释）
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.horizontalScrollElasticity = .none   // F3：横向弹性关闭（防触控板横滑漂移）

        // programmatic 创建的 NSTextView 必须显式给非零初始 frame（ComposerTextView 同坑）
        let tv = PlaceholderNSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 80))
        tv.autoresizingMask = [.width]
        tv.minSize = NSSize(width: 0, height: 24)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
        tv.delegate = context.coordinator
        tv.drawsBackground = false
        tv.isRichText = false
        tv.font = mono
            ? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            : NSFont.systemFont(ofSize: fontSize)
        tv.textColor = NSColor(VTheme.textPrimary)
        tv.textContainerInset = contentInset
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.onCommandEnter = onCommandEnter
        tv.onSubmitEnter = onSubmitEnter
        tv.sync = context.coordinator

        scroll.documentView = tv
        context.coordinator.textView = tv
        return scroll
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? PlaceholderNSTextView else { return }
        tv.onCommandEnter = onCommandEnter
        tv.onSubmitEnter = onSubmitEnter
        // 复用 ComposerSyncPolicy 回写守门：用户输入/IME 组字产生的内容不回写，
        // 仅外部变更（绑定偏离上次同步值）才回写——15fps 级重渲也拿不到可误伤的旧绑定。
        if ComposerSyncPolicy.shouldPushBindingToView(
            binding: text, lastSynced: context.coordinator.lastSyncedText,
            hasMarkedText: tv.hasMarkedText()), tv.string != text {
            tv.string = text
            context.coordinator.lastSyncedText = text
        }
        context.coordinator.placeholder = placeholder
        context.coordinator.placeholderColor = placeholderColor
        context.coordinator.updatePlaceholder(tv)
        context.coordinator.parent = self
    }

    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: VPlaceholderTextEditor
        weak var textView: PlaceholderNSTextView?
        var placeholder: String = ""
        var placeholderColor: Color = VTheme.textTertiary
        /// 绑定值上次同步快照（ComposerTextView 同口径三处维护）
        var lastSyncedText = ""
        private var placeholderLabel: NSTextField?

        init(_ parent: VPlaceholderTextEditor) { self.parent = parent }

        public func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? PlaceholderNSTextView else { return }
            parent.text = tv.string
            lastSyncedText = tv.string
            updatePlaceholder(tv)
        }

        /// IME 组字钩子（setMarkedText/unmarkText 时调用）——组字变化不一定走
        /// textDidChange，这里显式同步绑定 + 刷新占位，中文首字母按下即消占位。
        func markedTextChanged(_ tv: PlaceholderNSTextView) {
            parent.text = tv.string
            lastSyncedText = tv.string
            updatePlaceholder(tv)
        }

        func updatePlaceholder(_ tv: PlaceholderNSTextView) {
            if placeholderLabel == nil {
                // F4（0.7.12 实测修复）：占位 label 换命中穿透类——普通 NSTextField
                // 会把点击吞在 label 上（空文占位必盖首行，点中即「无光标+beep」；
                // 0.7.6 composer 修过同病没推广，这里直接复用 ComposerPassthroughLabel）
                let label = ComposerPassthroughLabel(labelWithString: placeholder)
                label.font = tv.font
                label.translatesAutoresizingMaskIntoConstraints = false
                label.lineBreakMode = .byTruncatingTail
                tv.addSubview(label)
                // 与正文首字对齐：左 = 内边距 + 行碎片 padding（默认 5），上 = 内边距
                let inset = tv.textContainerInset
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: tv.leadingAnchor,
                                                   constant: inset.width + 5),
                    label.topAnchor.constraint(equalTo: tv.topAnchor,
                                               constant: inset.height),
                    label.trailingAnchor.constraint(lessThanOrEqualTo: tv.trailingAnchor),
                ])
                placeholderLabel = label
            }
            placeholderLabel?.stringValue = placeholder
            placeholderLabel?.textColor = NSColor(placeholderColor)
            // 根治口径：占位显隐挂内容——text 非空即消；IME 组字中（hasMarkedText，
            // string 仍为空）也算「输入中」，输入开始那一刻即消
            placeholderLabel?.isHidden = ComposerSyncPolicy.placeholderHidden(
                viewString: tv.string, hasMarkedText: tv.hasMarkedText())
        }
    }
}

/// 占位编辑器专用 NSTextView：IME 组字钩子 + Cmd+Enter 提交（组字期放行选词）
/// + Enter 提交/Shift+Enter 换行（0.7.6 插话条口径，与智能中心 ComposerTextView 一致）。
public final class PlaceholderNSTextView: NSTextView {
    var onCommandEnter: (() -> Bool)?
    var onSubmitEnter: (() -> Bool)?
    weak var sync: VPlaceholderTextEditor.Coordinator?

    public override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn {
            // 组合期（选词确认）回车不触发任何提交（ComposerNSTextView 同口径）
            if hasMarkedText() { super.keyDown(with: event); return }
            if event.modifierFlags.contains(.command), onCommandEnter?() == true { return }
            // Shift+Enter = 换行（不拦默认行为）；裸 Enter = 提交（有钩子时）
            if !event.modifierFlags.contains(.shift), !event.modifierFlags.contains(.command),
               onSubmitEnter?() == true { return }
        }
        super.keyDown(with: event)
    }

    public override func setMarkedText(_ string: Any, selectedRange: NSRange,
                                       replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        sync?.markedTextChanged(self)
    }

    /// 组字提交/取消（unmark）后同样刷新一次（提交后 string 落定，占位与绑定归位）
    public override func unmarkText() {
        super.unmarkText()
        sync?.markedTextChanged(self)
    }

    public override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, let tv = textViewSelf { sync?.updatePlaceholder(tv) }
        return ok
    }

    private var textViewSelf: PlaceholderNSTextView? { self }
}
