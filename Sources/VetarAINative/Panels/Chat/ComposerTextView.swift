//
//  ComposerTextView.swift
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

//  会话输入框：NSTextView 封装（SwiftUI TextField 拿不到 IME 组合态与剪贴板图片）。
//  行为对照现状 textarea 事件链（checkpoint-067b R-1/D-6 / B14 0.4.22）：
//    · Enter = 发送；Shift+Enter = 换行
//    · 输入法组合期（hasMarkedText）回车 = 选词确认，不发送
//    · 粘贴：剪贴板含图片/文件 → 回调给暂存区，纯文本照常插入
//    · 多行自适应高度（约 1~6 行）
//

import SwiftUI
import AppKit

/// 问题2/3（实测）修复的纯策略载体——把「绑定→视图回写」与「占位符显隐」从
/// NSViewRepresentable 回调里抽成可单测的判定函数。
///
/// 根因记录：
///   · 问题2：流式期间 accumulator 15fps 合帧 flush → ChatDetailView 整体重渲 →
///     updateNSView 每帧执行。旧逻辑 `tv.string != text → tv.string = text` 在 IME
///     组字（marked text）期间必然误伤：组字内容在 text storage 里，但绑定值经
///     delegate 链未必同步（中文首字母是 marked text，绑定仍为空），下一帧即用
///     旧绑定整体覆盖 text storage —— 组字被抹、选区重置、焦点/IME 被打断，
///     表现为「思考中无法打字，输入框一直在刷新」。
///   · 问题3：占位符旧条件只看 `tv.string.isEmpty`——marked text 期间 string 仍
///     为空，首字母按下后灰字不消失。
public enum ComposerSyncPolicy {
    /// 是否允许把绑定值回写进 NSTextView。
    /// 仅当绑定值相对 coordinator 上次同步值发生了「外部变更」（如 send() 清空输入框）
    /// 才回写；用户自己敲出来的内容（textDidChange 已同步过，binding == lastSynced）
    /// 一律不回写。IME 组字中（hasMarkedText）无论何种情况都禁止回写——
    /// 回写会摧毁组字会话。
    public static func shouldPushBindingToView(binding: String, lastSynced: String,
                                               hasMarkedText: Bool) -> Bool {
        if hasMarkedText { return false }
        return binding != lastSynced
    }

    /// 占位符隐藏条件：text 非空即隐藏；IME 组字中（hasMarkedText，string 仍为空）
    /// 也算「输入中」——中文输入首字母即隐藏灰字。
    public static func placeholderHidden(viewString: String, hasMarkedText: Bool) -> Bool {
        !viewString.isEmpty || hasMarkedText
    }
}

/// 补充一（0.7.6 实测：「新建 Agent 后输入框无法输入文字，切换一下 agent 回来
/// 恢复」）：占位符标签是 ComposerNSTextView 的前柱子视图，AppKit 命中测试落在
/// 它上面时点击**不会**把焦点交给下面的 text view（label 拒当 first responder，
/// mouseDown 被空吞）——表象「输入框无法输入文字」；点到未覆盖区域或焦点本在
/// 输入框时正常，故呈偶发（新建 Agent 后输入框必为空、占位符必可见，且新建流程
/// 焦点在侧栏名称栏/添加按钮，点输入区首行即命中）。修复：命中测试穿透。
final class ComposerPassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

public struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    /// 自适应高度（约 1~6 行，38~120pt，现状 minHeight/maxHeight 口径）
    @Binding var height: CGFloat
    var placeholder: String
    var disabled: Bool
    var onSend: () -> Void
    /// 粘贴到图片/文件（URL 列表；图片为 dataURI 时走 onPasteImages）
    var onPasteImages: ([NSImage]) -> Void
    var onPasteFiles: ([URL]) -> Void

    public init(text: Binding<String>, height: Binding<CGFloat>, placeholder: String, disabled: Bool,
                onSend: @escaping () -> Void,
                onPasteImages: @escaping ([NSImage]) -> Void,
                onPasteFiles: @escaping ([URL]) -> Void) {
        self._text = text
        self._height = height
        self.placeholder = placeholder
        self.disabled = disabled
        self.onSend = onSend
        self.onPasteImages = onPasteImages
        self.onPasteFiles = onPasteFiles
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        //  programmatic 创建的 NSTextView 必须显式给非零初始 frame + 宽度随动，
        //  否则 text view 宽度为 0（AX 树 0×38），点击落不进、键盘输入无从进入。
        let tv = ComposerNSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 38))
        tv.autoresizingMask = [.width]
        tv.minSize = NSSize(width: 0, height: 38)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.delegate = context.coordinator
        tv.drawsBackground = false
        tv.isRichText = false
        tv.font = NSFont.systemFont(ofSize: 14)
        tv.textColor = NSColor(VTheme.textPrimary)
        tv.textContainerInset = NSSize(width: 0, height: 2)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.onSend = onSend
        tv.onPasteImages = onPasteImages
        tv.onPasteFiles = onPasteFiles
        tv.coordinator = context.coordinator

        scroll.documentView = tv
        context.coordinator.textView = tv
        return scroll
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? ComposerNSTextView else { return }
        tv.onSend = onSend
        tv.onPasteImages = onPasteImages
        tv.onPasteFiles = onPasteFiles
        // 问题2：只在「外部变更」（绑定值偏离 coordinator 上次同步值，如 send() 清空）
        // 时回写 text storage；用户输入 / IME 组字产生的内容不在这里回写——
        // 否则流式 15fps 重渲会每帧用旧绑定覆盖 text storage，组字被抹、焦点被打断。
        if ComposerSyncPolicy.shouldPushBindingToView(
            binding: text, lastSynced: context.coordinator.lastSyncedText,
            hasMarkedText: tv.hasMarkedText()), tv.string != text {
            tv.string = text
            context.coordinator.lastSyncedText = text
            context.coordinator.updateHeight(tv)
        }
        tv.isEditable = !disabled
        context.coordinator.placeholder = placeholder
        context.coordinator.updatePlaceholder(tv)
        context.coordinator.parent = self
    }

    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: ComposerNSTextView?
        var placeholder: String = ""
        /// 绑定值上次同步快照：textDidChange / 组字钩子 / 外部回写三处共同维护。
        /// updateNSView 用它区分「用户敲的」（== 绑定值，不回写）与「外部改的」
        ///（≠ 绑定值，如发送后清空，需回写）。
        var lastSyncedText = ""
        private var placeholderLabel: NSTextField?

        init(_ parent: ComposerTextView) { self.parent = parent }

        public func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? ComposerNSTextView else { return }
            parent.text = tv.string
            lastSyncedText = tv.string
            updateHeight(tv)
            updatePlaceholder(tv)
        }

        /// 问题2/3：IME 组字生命周期钩子（setMarkedText/unmarkText 时调用）——
        /// 组字变化不一定走 textDidChange，这里显式同步绑定 + 刷新占位符，
        /// 保证中文首字母按下即隐藏灰字、且 15fps 重渲拿不到可回写的旧绑定。
        func markedTextChanged(_ tv: ComposerNSTextView) {
            parent.text = tv.string
            lastSyncedText = tv.string
            updatePlaceholder(tv)
        }

        func updateHeight(_ tv: NSTextView) {
            guard let layout = tv.textContainer?.layoutManager,
                  let container = tv.textContainer else { return }
            layout.ensureLayout(for: container)
            let h = min(max(layout.usedRect(for: container).height + 14, 38), 120)
            if abs(parent.height - h) > 0.5 { parent.height = h }
        }

        func updatePlaceholder(_ tv: ComposerNSTextView) {
            if placeholderLabel == nil {
                let label = ComposerPassthroughLabel(labelWithString: placeholder)
                label.font = NSFont.systemFont(ofSize: 14)
                label.textColor = NSColor(VTheme.textTertiary)
                label.translatesAutoresizingMaskIntoConstraints = false
                label.lineBreakMode = .byTruncatingTail
                tv.addSubview(label)
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: tv.leadingAnchor, constant: 5),
                    label.topAnchor.constraint(equalTo: tv.topAnchor, constant: 2),
                    label.trailingAnchor.constraint(lessThanOrEqualTo: tv.trailingAnchor),
                ])
                placeholderLabel = label
            }
            placeholderLabel?.stringValue = placeholder
            // 问题3：text 非空即隐藏；IME 组字中（hasMarkedText）也算「输入中」
            placeholderLabel?.isHidden = ComposerSyncPolicy.placeholderHidden(
                viewString: tv.string, hasMarkedText: tv.hasMarkedText())
        }
    }
}

/// 拦截回车（IME 组合期放行）与粘贴板图片/文件的 NSTextView。
public final class ComposerNSTextView: NSTextView {
    var onSend: (() -> Void)?
    var onPasteImages: (([NSImage]) -> Void)?
    var onPasteFiles: (([URL]) -> Void)?
    weak var coordinator: ComposerTextView.Coordinator?

    public override func keyDown(with event: NSEvent) {
        // checkpoint-067b R-1：组合期（选词确认）回车不发送
        if event.keyCode == 36 || event.keyCode == 76 {   // Return / keypad Enter
            if hasMarkedText() {
                super.keyDown(with: event)
                return
            }
            if event.modifierFlags.contains(.shift) {
                super.keyDown(with: event)   // Shift+Enter = 换行（B14：不拦默认行为）
                return
            }
            onSend?()   // Enter = 发送（不插入换行 = preventDefault 语义）
            return
        }
        super.keyDown(with: event)
    }

    // 问题2/3：IME 组字开始/更新（中文首字母是 marked text，string 可能仍为空）——
    // 显式通知 coordinator 同步绑定与占位符，不依赖 textDidChange 是否覆盖组字变化。
    public override func setMarkedText(_ string: Any, selectedRange: NSRange,
                                       replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        coordinator?.markedTextChanged(self)
    }

    /// 组字提交/取消（unmark）后同样刷新一次（提交后 string 落定，占位符与绑定归位）
    public override func unmarkText() {
        super.unmarkText()
        coordinator?.markedTextChanged(self)
    }

    public override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        // 图片优先（截图粘贴）
        if let images = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage], !images.isEmpty {
            onPasteImages?(images)
            return
        }
        // 文件 URL（Finder 复制/拖拽粘贴）
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            onPasteFiles?(urls)
            return
        }
        super.paste(sender)
    }

    public override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { coordinator?.updatePlaceholder(self) }
        return ok
    }
}
