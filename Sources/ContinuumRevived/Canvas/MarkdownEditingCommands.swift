import AppKit

/// Focused Markdown source-editing behavior shared by note and file tiles.
/// It deliberately operates on the native NSTextView so undo, selection,
/// accessibility, and input methods keep their AppKit semantics.
@MainActor
enum MarkdownEditingCommands {
    enum Command: Int {
        case bold = 1
        case italic
        case link
        case heading
        case unorderedList
        case quote
        case inlineCode
        case fencedCode
    }

    static func makeContextMenu(target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu(title: "Markdown")
        addResponderItem("Undo", action: #selector(UndoManager.undo), key: "z", to: menu)
        addResponderItem("Redo", action: #selector(UndoManager.redo), key: "Z", to: menu)
        menu.addItem(.separator())
        addResponderItem("Cut", action: #selector(NSText.cut(_:)), key: "x", to: menu)
        addResponderItem("Copy", action: #selector(NSText.copy(_:)), key: "c", to: menu)
        addResponderItem("Paste", action: #selector(NSText.paste(_:)), key: "v", to: menu)
        addResponderItem("Select All", action: #selector(NSText.selectAll(_:)), key: "a", to: menu)
        menu.addItem(.separator())
        appendFormattingItems(to: menu, target: target, action: action)
        return menu
    }

    /// Compact title-bar authoring control. It keeps formatting discoverable in
    /// every editable Markdown tile without consuming a full editor toolbar.
    static func makeToolbarPopUp(target: AnyObject, action: Selector) -> NSPopUpButton {
        let popUp = NSPopUpButton(frame: .zero, pullsDown: true)
        popUp.controlSize = .small
        popUp.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        let menu = NSMenu(title: "Format")
        menu.addItem(NSMenuItem(title: "Format", action: nil, keyEquivalent: ""))
        appendFormattingItems(to: menu, target: target, action: action)
        popUp.menu = menu
        popUp.setAccessibilityLabel("Markdown formatting")
        popUp.toolTip = "Format Markdown"
        return popUp
    }

    private static func appendFormattingItems(to menu: NSMenu, target: AnyObject, action: Selector) {
        let entries: [(String, Command)] = [
            ("Bold", .bold), ("Italic", .italic), ("Link", .link),
            ("Heading", .heading), ("List", .unorderedList), ("Quote", .quote),
            ("Inline Code", .inlineCode), ("Code Block", .fencedCode)
        ]
        for (title, command) in entries {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            item.tag = command.rawValue
            menu.addItem(item)
        }
    }

    private static func addResponderItem(_ title: String, action: Selector, key: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = nil
        menu.addItem(item)
    }

    static func apply(_ command: Command, in textView: NSTextView) {
        switch command {
        case .bold: wrapSelection(in: textView, prefix: "**", suffix: "**", placeholder: "bold")
        case .italic: wrapSelection(in: textView, prefix: "*", suffix: "*", placeholder: "italic")
        case .link: wrapSelection(in: textView, prefix: "[", suffix: "](url)", placeholder: "link text")
        case .heading: applyLinePrefix("# ", in: textView)
        case .unorderedList: applyLinePrefix("- ", in: textView)
        case .quote: applyLinePrefix("> ", in: textView)
        case .inlineCode: wrapSelection(in: textView, prefix: "`", suffix: "`", placeholder: "code")
        case .fencedCode: insertFencedCode(in: textView)
        }
    }

    static func handleKeyEquivalent(_ event: NSEvent, in textView: NSTextView) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == .command,
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch key {
        case "b": wrapSelection(in: textView, prefix: "**", suffix: "**", placeholder: "bold")
        case "i": wrapSelection(in: textView, prefix: "*", suffix: "*", placeholder: "italic")
        case "k": wrapSelection(in: textView, prefix: "[", suffix: "](url)", placeholder: "link text")
        default: return false
        }
        return true
    }

    static func handleCommand(_ selector: Selector, in textView: NSTextView) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            return continueList(in: textView)
        case #selector(NSResponder.insertTab(_:)):
            indentSelectedLines(in: textView, removing: false)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            indentSelectedLines(in: textView, removing: true)
            return true
        default:
            return false
        }
    }

    private static func applyLinePrefix(_ prefix: String, in textView: NSTextView) {
        transformSelectedLines(in: textView) { line in
            line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : prefix + line
        }
    }

    private static func insertFencedCode(in textView: NSTextView) {
        wrapSelection(in: textView, prefix: "```\n", suffix: "\n```", placeholder: "code")
    }

    private static func wrapSelection(
        in textView: NSTextView,
        prefix: String,
        suffix: String,
        placeholder: String
    ) {
        let selection = textView.selectedRange()
        let source = textView.string as NSString
        let selected = selection.length > 0 ? source.substring(with: selection) : placeholder
        let replacement = prefix + selected + suffix
        guard textView.shouldChangeText(in: selection, replacementString: replacement) else { return }
        textView.textStorage?.replaceCharacters(in: selection, with: replacement)
        let contentRange = NSRange(location: selection.location + prefix.utf16.count, length: selected.utf16.count)
        textView.setSelectedRange(contentRange)
        textView.didChangeText()
    }

    private static func continueList(in textView: NSTextView) -> Bool {
        let source = textView.string as NSString
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return false }
        let lineRange = source.lineRange(for: NSRange(location: selection.location, length: 0))
        let beforeCaret = source.substring(with: NSRange(
            location: lineRange.location,
            length: selection.location - lineRange.location
        ))
        let pattern = #"^(\s*)([-*+] |(\d+)\. )(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: beforeCaret,
                range: NSRange(location: 0, length: (beforeCaret as NSString).length)
              ) else { return false }
        let nsLine = beforeCaret as NSString
        let indent = nsLine.substring(with: match.range(at: 1))
        let marker = nsLine.substring(with: match.range(at: 2))
        let content = nsLine.substring(with: match.range(at: 4))

        if content.trimmingCharacters(in: .whitespaces).isEmpty {
            let remove = NSRange(location: lineRange.location, length: beforeCaret.utf16.count)
            guard textView.shouldChangeText(in: remove, replacementString: "") else { return true }
            textView.textStorage?.replaceCharacters(in: remove, with: "")
            textView.setSelectedRange(NSRange(location: lineRange.location, length: 0))
            textView.didChangeText()
            return true
        }

        let nextMarker: String
        if match.range(at: 3).location != NSNotFound,
           let number = Int(nsLine.substring(with: match.range(at: 3))) {
            nextMarker = "\(number + 1). "
        } else {
            nextMarker = marker
        }
        let insertion = "\n" + indent + nextMarker
        guard textView.shouldChangeText(in: selection, replacementString: insertion) else { return true }
        textView.textStorage?.replaceCharacters(in: selection, with: insertion)
        textView.setSelectedRange(NSRange(location: selection.location + insertion.utf16.count, length: 0))
        textView.didChangeText()
        return true
    }

    private static func indentSelectedLines(in textView: NSTextView, removing: Bool) {
        transformSelectedLines(in: textView) { line in
            if removing {
                if line.hasPrefix("    ") { return String(line.dropFirst(4)) }
                if line.hasPrefix("\t") { return String(line.dropFirst()) }
                return line
            }
            return "    " + line
        }
    }

    private static func transformSelectedLines(
        in textView: NSTextView,
        transform: (String) -> String
    ) {
        let source = textView.string as NSString
        let selection = textView.selectedRange()
        let linesRange = source.lineRange(for: selection)
        let original = source.substring(with: linesRange)
        let trailingNewline = original.hasSuffix("\n")
        var lines = original.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if trailingNewline, lines.last == "" { lines.removeLast() }
        var replacement = lines.map(transform).joined(separator: "\n")
        if trailingNewline { replacement += "\n" }
        guard textView.shouldChangeText(in: linesRange, replacementString: replacement) else { return }
        textView.textStorage?.replaceCharacters(in: linesRange, with: replacement)
        textView.setSelectedRange(NSRange(location: linesRange.location, length: replacement.utf16.count))
        textView.didChangeText()
    }
}
