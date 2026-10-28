import AppKit
import CoreText
import UniformTypeIdentifiers
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// Block layout for `AgentTranscriptCanvasView`: one function per block family,
/// each reproducing the geometry, fonts and colours of the row renderer it
/// stands in for (named in each function), and each producing only drawing
/// instructions — text lines, decorations, drawn controls, scroll regions.
/// Everything here runs at layout time; `draw` only strokes the result.
extension AgentTranscriptCanvasView {
    /// One block's drawing, before it is frozen into a `LaidBlock`.
    struct Body {
        var builder = Builder()
        var height: CGFloat = 0
        var alpha: CGFloat = 1
        var clips = false
    }

    var zoom: AgentPageZoom { renderContext.pageZoom }
    func S(_ value: Double) -> CGFloat { CGFloat(renderContext.pageZoom.scaled(value)) }
    func lineHeight(_ role: TextRole) -> CGFloat { CGFloat(renderContext.pageZoom.lineHeight(for: role)) }
    var primary: NSColor { color(renderContext.tokens.primaryText) }
    var secondary: NSColor { color(renderContext.tokens.secondaryText) }
    var hairline: CGFloat { max(CGFloat(LineWidth.hairline), 0.5) }

    // MARK: Units

    func layoutUnit(_ unit: Unit, width: CGFloat, signature: Int, variant: Int) -> LaidBlock {
        switch unit {
        case let .block(block, entry):
            let presented = toolDetail.presented(block, in: entry)
            let body = body(for: presented, role: entry.role, width: width)
            let presentedPayload: AgentBlockPayload?
            switch presented.payload {
            case .toolCall, .diff: presentedPayload = presented.payload
            default: presentedPayload = nil
            }
            return LaidBlock(id: block.id, revision: block.revision, width: width, contextSignature: signature,
                             role: entry.role, variant: variant, presented: presentedPayload,
                             height: body.height, builder: body.builder, alpha: body.alpha, clipsToBounds: body.clips)
        case let .reasoning(entry, duration):
            let body = reasoningBody(entry, duration: duration, width: width)
            return LaidBlock(id: entry.id, revision: entry.revision, width: width, contextSignature: signature,
                             role: entry.role, variant: variant, height: body.height, builder: body.builder)
        }
    }

    /// A child laid out on its own, for embedding (reasoning bodies).
    func laidChild(_ block: AgentBlock, role: AgentEntryRole, width: CGFloat) -> LaidBlock {
        let body = body(for: block, role: role, width: width)
        return LaidBlock(id: block.id, revision: block.revision, width: width, contextSignature: 0, role: role,
                         height: body.height, builder: body.builder, alpha: body.alpha, clipsToBounds: body.clips)
    }

    /// Live inputs a block's drawing depends on that its revision does not carry.
    func combineLiveVariant(of block: AgentBlock, into hasher: inout Hasher) {
        switch block.payload {
        case let .toolCall(tool) where !tool.status.agentToolIsTerminal:
            // The running clock's whole seconds: the drawn status changes with them.
            let since = renderContext.toolClockScope.startDate(for: block.id)
            hasher.combine(since.map { Int(ToolRowLiveClock.now().timeIntervalSince($0)) } ?? -1)
        case let .image(image):
            combineImage(image.attachment.id, into: &hasher)
        case let .imageGallery(gallery):
            gallery.images.forEach { combineImage($0.attachment.id, into: &hasher) }
        case .agentReference:
            for reference in AgentReferenceRenderer.references(in: block) {
                let state = renderContext.agentStatus.current(reference.payload.agentID)
                hasher.combine(state?.label)
                hasher.combine(state?.accent.map { "\($0)" })
            }
        case let .agentMessage(message):
            if let id = message.senderAgentID, let sender = renderContext.agentMessageSenders.current(id) {
                hasher.combine(sender.hasTile)
                hasher.combine(sender.identityColorName)
            }
        default:
            break
        }
    }

    private func combineImage(_ id: AgentImageAttachmentID, into hasher: inout Hasher) {
        let snapshot = renderContext.imageResources.snapshot(id)
        hasher.combine(snapshot.revision)
        hasher.combine("\(snapshot.state)")
        hasher.combine(snapshot.pixelSize?.width)
        hasher.combine(snapshot.pixelSize?.height)
    }

    func body(for block: AgentBlock, role: AgentEntryRole, width: CGFloat) -> Body {
        if AssistantProseRenderer.supportedKinds.contains(block.kind) {
            return proseBody(block, isUser: role == .user, width: width)
        }
        switch block.payload {
        case let .fencedCode(code): return codeBody(block, code: code, width: width)
        case let .toolCall(tool): return toolBody(block, tool: tool, width: width)
        case let .commandOutput(output): return commandOutputBody(block, output: output, width: width)
        case let .sessionBoundary(boundary):
            return boundaryBody(text: boundary.text, symbolName: boundary.symbolName, labelColor: secondary, width: width)
        case let .compaction(compaction):
            let label: NSColor
            switch compaction.phase {
            case "failed": label = AccentToken.accentFailed.color.nsColor(for: theme)
            case "indeterminate": label = AccentToken.accentApproval.color.nsColor(for: theme)
            default: label = secondary
            }
            return boundaryBody(text: CompactionRenderer.label(compaction), symbolName: nil, labelColor: label, width: width)
        case let .approval(request): return requestBody(block, request: request, isApproval: true, width: width)
        case let .question(request): return requestBody(block, request: request, isApproval: false, width: width)
        case let .error(error): return errorBody(block, error: error, width: width)
        case let .notice(notice): return noticeBody(notice, width: width)
        case let .diff(diff): return diffBody(block, diff: diff, width: width)
        case let .fileReferences(references): return fileReferencesBody(references.files, width: width)
        case let .plan(plan): return planBody(plan, width: width)
        case let .table(table):
            if let body = tableBody(table, width: width) { return body }
        case let .image(image): return imagesBody(block, images: [image], gallery: false, width: width)
        case let .imageGallery(gallery): return imagesBody(block, images: gallery.images, gallery: true, width: width)
        case .agentReference: return agentReferenceBody(block, width: width)
        case let .taskReference(task): return taskReferenceBody(task, width: width)
        case let .agentMessage(message): return messageBody(block, message: message, width: width)
        case .thematicBreak:
            var body = Body(height: ThematicBreakRenderer.boxHeight(zoom: zoom))
            body.builder.decorations.append(.fill(CGRect(x: 0, y: (body.height - hairline) / 2, width: width, height: hairline),
                                                  AgentLineRole.decorativeHairline.color.cgColor(for: theme), radius: 0))
            return body
        default:
            break
        }
        return plainBody(block, width: width)
    }

    // MARK: Prose and user prompts (AssistantProseRenderer, UserPromptRenderer)

    func proseBody(_ block: AgentBlock, isUser: Bool, width: CGFloat) -> Body {
        let leading = isUser ? UserPromptView.leadingInset(zoom: zoom) : 0
        let vertical = isUser ? UserPromptView.verticalInset(zoom: zoom) : 0
        let textWidth = max(1, width - leading)
        var body = Body()
        var y = vertical
        for (index, row) in AssistantProseView.rows(for: block, zoom: zoom).enumerated() {
            if index > 0 { y += AssistantProseView.blockSpacing(zoom: zoom) + row.spacingAbove }
            let resolved = AgentTextStyleResolver.resolve(
                row.runs, theme: theme, tokens: renderContext.tokens, textRole: row.textRole, style: row.style, zoom: zoom)
            let font = NSFont.token(row.textRole, zoom: zoom)
            let set = Self.typeset(resolved.attributedString, width: textWidth, originX: leading, top: y,
                                   firstIndent: row.style.firstLineHeadIndent, headIndent: row.style.headIndent,
                                   linePitch: row.style.linePitch, fallbackFont: font)
            body.builder.rows.append(TextRow(string: resolved.attributedString, lines: set.lines, links: resolved.links))
            if !row.marker.isEmpty {
                let x = leading + row.style.firstLineHeadIndent - AssistantProseView.markerGutter(zoom: zoom)
                let baseline = set.lines.first?.baseline ?? (y + font.ascender)
                body.builder.decorations.append(.text(Self.line(row.marker, font: font, color: secondary),
                                                      CGPoint(x: max(leading, x), y: baseline)))
            }
            y += set.height
        }
        body.height = ceil(y + vertical)
        if isUser {
            body.builder.decorations.insert(.fill(
                CGRect(x: 0, y: 0, width: UserPromptView.ruleWidth(zoom: zoom), height: body.height),
                AgentLineRole.authorship.color.cgColor(for: theme), radius: 0), at: 0)
        }
        return body
    }

    // MARK: Code (CodeBlockRenderer)

    func codeBody(_ block: AgentBlock, code: AgentCodePayload, width: CGFloat) -> Body {
        let header = CodeBlockView.headerHeight(zoom: zoom)
        let inset = CodeTextView.containerInset(zoom: zoom)
        let side = S(Space.l)
        let mono = monoRow(code.code, font: NSFont.token(.bodyMono, zoom: zoom), color: primary,
                           x: inset.width, top: header + inset.height)
        let codeHeight = max(CodeBlockView.minimumCodeHeight(zoom: zoom), mono.contentHeight + inset.height * 2)
        // Today's cap: past it the body scrolls inside the block.
        let height = ceil(min(CodeBlockView.maximumExpandedHeight(zoom: zoom), header + codeHeight))
        var body = Body(height: height, clips: true)
        body.builder.regions.append(ScrollRegion(
            viewport: CGRect(x: 0, y: header, width: width, height: height - header),
            contentSize: CGSize(width: mono.contentWidth + inset.width * 2, height: codeHeight)))
        var row = mono.row
        row.region = 0
        body.builder.rows.append(row)
        body.builder.decorations.append(.fill(CGRect(x: 0, y: 0, width: width, height: height),
                                              renderContext.tokens.codeSurface.color.cgColor(for: theme),
                                              radius: CGFloat(zoom.scaled(CornerRole.artifact.radius))))
        let labelFont = NSFont.token(.label, zoom: zoom)
        let language = code.language?.trimmingCharacters(in: .whitespacesAndNewlines)
        body.builder.decorations.append(.text(
            Self.line(language.flatMap { $0.isEmpty ? nil : $0 } ?? "Code", font: labelFont, color: secondary),
            CGPoint(x: side, y: S(Space.m) + labelFont.ascender)))
        let copy = textControl("Copy", font: labelFont, rightEdge: width - side, top: S(Space.s),
                               height: header - S(Space.m), action: .copy(code.code, block.id))
        body.builder.controls.append(copy)
        if !code.isComplete {
            let caption = NSFont.token(.caption, zoom: zoom)
            let streaming = Self.line("Streaming", font: caption, color: secondary)
            let streamingWidth = Self.width(of: streaming)
            body.builder.decorations.append(.text(streaming, CGPoint(x: copy.rect.minX - S(Space.m) - streamingWidth,
                                                                     y: S(Space.m) + caption.ascender)))
        }
        return body
    }

    /// Unwrapped monospace text, one CTLine per source line, for code and output.
    func monoRow(_ text: String, font: NSFont, color: NSColor, x: CGFloat, top: CGFloat)
        -> (row: TextRow, contentWidth: CGFloat, contentHeight: CGFloat) {
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let typesetter = CTTypesetterCreateWithAttributedString(Self.coreTextString(string))
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let ns = text as NSString
        var lines: [Line] = []
        var location = 0
        var y = top
        var widest: CGFloat = 0
        repeat {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            var visible = paragraph
            while visible.length > 0, let scalar = UnicodeScalar(ns.character(at: NSMaxRange(visible) - 1)),
                  CharacterSet.newlines.contains(scalar) {
                visible.length -= 1
            }
            // Lines keep their offsets in the whole string, so selection and hit
            // testing index the row's text directly.
            let line = CTTypesetterCreateLine(typesetter, CFRange(location: visible.location, length: visible.length))
            let lineWidth = Self.width(of: line)
            widest = max(widest, lineWidth)
            lines.append(Line(ctLine: line, range: visible, x: x, top: y, height: lineHeight,
                              baseline: y + font.ascender, width: lineWidth, fills: [], underlines: []))
            y += lineHeight
            location = NSMaxRange(paragraph)
        } while location < ns.length
        return (TextRow(string: string, lines: lines, links: []), ceil(widest), y - top)
    }

    /// A borderless text button sized to its title (Copy, Open Review →).
    func textControl(_ title: String, font: NSFont, rightEdge: CGFloat? = nil, leftEdge: CGFloat? = nil,
                     top: CGFloat, height: CGFloat, action: ControlAction, tint: NSColor? = nil) -> Control {
        let width = ceil(Self.width(of: Self.line(title, font: font, color: secondary))) + S(Space.s)
        let x = leftEdge ?? ((rightEdge ?? width) - width)
        return Control(rect: CGRect(x: x, y: top, width: width, height: height), title: title, style: .text,
                       action: action, font: font, tint: tint)
    }

    // MARK: Tool rows (ToolCallRenderer)

    func toolBody(_ block: AgentBlock, tool: AgentToolCallPayload, width: CGFloat) -> Body {
        let shell = tool.presentedShell.flatMap { $0.command.isEmpty ? nil : $0 }
        let title = ToolCallView.safeSingleLine(tool.name, fallback: "Tool")
        var status = tool.presentedShell == nil
            ? ToolCallView.statusText(status: tool.status, duration: tool.presentedTrailingDetailText)
            : ToolCallView.shellStatusText(
                status: ToolCallView.glyphStatus(tool.status, shell: tool.presentedShell),
                duration: tool.presentedTrailingDetailText, badge: tool.presentedShell?.badgeText)
        // S3: a running row carries its own live clock ("◐ 1m 12s"), as
        // `ToolCallView` does, started the first time the row is laid out and
        // advanced by `ToolRowLiveClock`'s shared 1 Hz tick (`tickLiveClock`).
        if tool.status.agentToolIsTerminal {
            renderContext.toolClockScope.clear(blockID: block.id)
        } else {
            let now = ToolRowLiveClock.now()
            let since = renderContext.toolClockScope.startIfNeeded(blockID: block.id, at: now)
            status = ToolCallView.runningStatusText(status: tool.status, elapsed: now.timeIntervalSince(since))
        }
        let needsAttention = tool.status == .failed || tool.presentedShell?.needsAttention == true
        let outputText = tool.presentedOutputText?.isEmpty == false ? tool.presentedOutputText : nil
        let summary = ToolCallView.presentedSummary(
            title: title, summary: tool.summary, statusLabel: tool.status.agentToolStatusPresentation.label,
            shell: shell, hasOutput: outputText != nil)
        let hasDetail = summary.lineCount > 1 || outputText != nil
        let expanded = hasDetail && renderContext.actions.isExpanded(
            blockID: block.id, default: tool.status.agentToolDefaultExpanded)
        var body = Body()
        // A shell row's headline is the command (after claude's description),
        // exactly as `ToolCallView.applyShellTitle` sets it.
        let rowHeight = headerRow(
            into: &body.builder, width: width, title: title,
            titleFont: shell == nil ? NSFont.token(.label, zoom: zoom) : ToolCallView.commandFont(zoom: zoom),
            attributedTitle: shell.map { ToolCallView.shellTitle($0, zoom: zoom, primary: primary, secondary: secondary) },
            status: status, statusAttention: needsAttention,
            symbolName: ToolCallView.symbolName(forToolNamed: tool.presentedToolNameText ?? tool.name),
            disclosure: hasDetail ? (block.id, expanded) : nil)
        body.builder.toolStatus = (status, !tool.status.agentToolIsTerminal)
        let inset = ToolCallView.horizontalInset(zoom: zoom)
        let indent = ToolCallView.detailIndent(zoom: zoom)
        let summaryFont = NSFont.token(shell == nil ? .body : .bodyMono, zoom: zoom)
        var y = rowHeight
        let text = expanded ? summary.disclosureText : summary.compactLine
        if !text.isEmpty {
            let string = NSAttributedString(string: text, attributes: [.font: summaryFont, .foregroundColor: primary])
            if expanded {
                let limit = shell == nil ? 12 : 24
                var set = Self.typeset(string, width: max(1, width - indent - inset), originX: indent, top: y,
                                       firstIndent: 0, headIndent: 0, linePitch: 0, fallbackFont: summaryFont)
                if set.lines.count > limit {
                    set.lines = Array(set.lines.prefix(limit))
                    set.height = set.lines.last.map { $0.top + $0.height - y } ?? set.height
                }
                body.builder.rows.append(TextRow(string: string, lines: set.lines, links: []))
                y += set.height
            } else {
                let lineHeight = ceil(summaryFont.ascender - summaryFont.descender + summaryFont.leading)
                body.builder.rows.append(TextRow(string: string, lines: [Self.singleLine(
                    string, x: indent, top: y, height: lineHeight, maxWidth: max(1, width - indent - inset),
                    font: summaryFont)], links: []))
                y += lineHeight
            }
        }
        if expanded, let outputText {
            // The output pane: Copy row (with its honesty note), then the
            // monospace output in a code-surface pane capped at 240pt.
            y += S(Space.xs)
            let labelFont = NSFont.token(.label, zoom: zoom)
            let copy = textControl("Copy", font: labelFont, rightEdge: width - inset, top: y, height: S(Space.xl),
                                   action: .copy(outputText, block.id))
            body.builder.controls.append(copy)
            if let note = tool.presentedOutputNote {
                let caption = NSFont.token(.caption, zoom: zoom)
                let noteString = NSAttributedString(string: note, attributes: [.font: caption, .foregroundColor: secondary])
                let line = Self.singleLine(noteString, x: indent, top: y, height: S(Space.xl),
                                           maxWidth: max(1, copy.rect.minX - indent - S(Space.s)), font: caption)
                body.builder.decorations.append(.text(line.ctLine, CGPoint(x: line.x, y: line.baseline)))
            }
            y += S(Space.xl) + S(Space.xs)
            appendOutputPane(outputText, into: &body.builder, x: indent, top: y, width: max(1, width - indent - inset),
                             filled: true)
            y = body.builder.regions.last.map { $0.viewport.maxY } ?? y
        }
        if expanded || y > rowHeight { y += ToolCallView.detailBottomInset(zoom: zoom) }
        body.height = ceil(y)
        body.alpha = tool.status.agentToolIsTerminal && !needsAttention ? CGFloat(Opacity.receded) : 1
        return body
    }

    /// A capped, independently scrolled monospace pane (tool output, command output).
    func appendOutputPane(_ text: String, into builder: inout Builder, x: CGFloat, top: CGFloat, width: CGFloat, filled: Bool) {
        let inset = CGSize(width: S(Space.l), height: S(Space.m))
        let mono = monoRow(text, font: NSFont.token(.bodyMono, zoom: zoom), color: primary,
                           x: x + inset.width, top: top + inset.height)
        let minimum = lineHeight(.bodyMono) + inset.height * 2
        let content = CGSize(width: mono.contentWidth + inset.width * 2, height: mono.contentHeight + inset.height * 2)
        let pane = CGRect(x: x, y: top, width: width, height: min(S(240), max(minimum, content.height)))
        if filled {
            builder.decorations.append(.fill(pane, renderContext.tokens.codeSurface.color.cgColor(for: theme),
                                             radius: CGFloat(zoom.scaled(CornerRole.artifact.radius))))
        }
        var row = mono.row
        row.region = builder.regions.count
        builder.regions.append(ScrollRegion(viewport: pane, contentSize: content))
        builder.rows.append(row)
    }

    // MARK: Command output (CommandOutputRenderer)

    func commandOutputBody(_ block: AgentBlock, output: AgentCommandOutputPayload, width: CGFloat) -> Body {
        let presentation = output.status.agentToolStatusPresentation
        let status = output.exitCode.map { "\(presentation.glyph) \(presentation.label), exit \($0)" }
            ?? "\(presentation.glyph) \(presentation.label)"
        let expanded = renderContext.actions.isExpanded(blockID: block.id, default: output.status.agentToolDefaultExpanded)
        var body = Body()
        let rowHeight = headerRow(
            into: &body.builder, width: width, title: "Command output", titleFont: NSFont.token(.label, zoom: zoom),
            status: status, statusAttention: output.status == .failed, symbolName: "terminal",
            disclosure: (block.id, expanded))
        guard expanded else {
            body.height = rowHeight
            body.alpha = output.status.agentToolIsTerminal && output.status != .failed ? CGFloat(Opacity.receded) : 1
            return body
        }
        let labelFont = NSFont.token(.label, zoom: zoom)
        body.builder.controls.append(textControl("Copy", font: labelFont, rightEdge: width - S(Space.l), top: rowHeight,
                                                 height: S(Space.xxl), action: .copy(output.text, block.id)))
        appendOutputPane(output.text, into: &body.builder, x: 0, top: rowHeight + S(Space.xxl) + S(Space.xs),
                         width: width, filled: false)
        body.height = ceil((body.builder.regions.last?.viewport.maxY ?? rowHeight) + S(Space.m))
        body.builder.decorations.insert(.fill(CGRect(x: 0, y: 0, width: width, height: body.height),
                                              renderContext.tokens.codeSurface.color.cgColor(for: theme),
                                              radius: CGFloat(zoom.scaled(CornerRole.artifact.radius))), at: 0)
        return body
    }

    /// The collapsed row both tool families share (`ToolCallView.layout()`):
    /// disclosure column, icon, title, trailing status. Returns the row height.
    @discardableResult
    func headerRow(into builder: inout Builder, width: CGFloat, title: String, titleFont: NSFont,
                   attributedTitle: NSAttributedString? = nil, status: String,
                   statusAttention: Bool, symbolName: String, disclosure: (AgentNodeID, Bool)?) -> CGFloat {
        let rowHeight = ToolCallView.rowHeight(zoom: zoom)
        let inset = ToolCallView.horizontalInset(zoom: zoom)
        let buttonSide = S(Space.xxl)
        if let (id, expanded) = disclosure {
            builder.controls.append(Control(
                rect: CGRect(x: inset, y: (rowHeight - buttonSide) / 2, width: buttonSide, height: buttonSide),
                title: expanded ? "Collapse \(title)" : "Expand \(title)", style: .chevron(expanded: expanded),
                action: .toggle(id, expanded: !expanded)))
        }
        let iconX = inset + buttonSide + S(Space.s)
        if let icon = Self.symbol(symbolName, pointSize: S(13), color: secondary) {
            builder.decorations.append(.symbol(icon, CGRect(
                x: iconX + (buttonSide - icon.size.width) / 2, y: (rowHeight - icon.size.height) / 2,
                width: icon.size.width, height: icon.size.height)))
        }
        let captionFont = NSFont.token(.caption, zoom: zoom)
        let statusLine = Self.line(status, font: captionFont,
                                   color: statusAttention ? AgentLineRole.attention.color.nsColor(for: theme) : secondary)
        // Right-aligned on the exact width, as the row's status label is: a
        // rounded-up width set every status a fraction of a point off one edge.
        let statusX = max(iconX + buttonSide, width - inset - min(Self.width(of: statusLine), width * 0.4))
        builder.decorations.append(.text(statusLine, CGPoint(
            x: statusX, y: Self.centredBaseline(font: captionFont, top: 0, height: rowHeight))))
        let titleX = iconX + buttonSide + S(Space.m)
        let titleString = attributedTitle
            ?? NSAttributedString(string: title, attributes: [.font: titleFont, .foregroundColor: primary])
        builder.rows.append(TextRow(string: titleString, lines: [Self.singleLine(
            titleString, x: titleX, top: 0, height: rowHeight,
            maxWidth: max(1, statusX - titleX - S(Space.m)), font: titleFont)], links: []))
        return rowHeight
    }

    // MARK: Boundaries (SessionBoundaryRenderer, CompactionRenderer)

    func boundaryBody(text: String, symbolName: String?, labelColor: NSColor, width: CGFloat) -> Body {
        let height = S(28)
        let font = NSFont.systemFont(ofSize: S(11), weight: .medium)
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: labelColor])
        let gap = S(Space.m)
        let icon = symbolName.flatMap { Self.symbol($0, pointSize: S(12), color: labelColor) }
        let glyphLead = icon.map { $0.size.width + CGFloat(Space.s) } ?? 0
        let labelWidth = min(ceil(Self.width(of: Self.line(text, font: font, color: labelColor))),
                             max(0, width - 2 * gap - glyphLead))
        let groupX = ((width - labelWidth - glyphLead) / 2).rounded()
        var body = Body(height: height)
        let rule = AgentLineRole.decorativeHairline.color.cgColor(for: theme)
        body.builder.decorations.append(.fill(CGRect(x: 0, y: (height - hairline) / 2, width: max(0, groupX - gap), height: hairline), rule, radius: 0))
        body.builder.decorations.append(.fill(CGRect(x: groupX + glyphLead + labelWidth + gap, y: (height - hairline) / 2,
                                                     width: max(0, width - groupX - glyphLead - labelWidth - gap), height: hairline), rule, radius: 0))
        if let icon {
            body.builder.decorations.append(.symbol(icon, CGRect(x: groupX, y: (height - icon.size.height) / 2,
                                                                 width: icon.size.width, height: icon.size.height)))
        }
        body.builder.rows.append(TextRow(string: string, lines: [Self.singleLine(
            string, x: groupX + glyphLead, top: 0, height: height, maxWidth: max(1, labelWidth), font: font)], links: []))
        return body
    }

    // MARK: Requests (ApprovalRenderer, QuestionRenderer)

    func requestBody(_ block: AgentBlock, request: AgentRequestPayload, isApproval: Bool, width: CGFloat) -> Body {
        let header = AgentRequestView.headerHeight(zoom: zoom)
        let inset = AgentRequestView.horizontalInset(zoom: zoom)
        let actionHeight = AgentRequestView.actionHeight(zoom: zoom)
        var body = Body()
        let statusAttention = request.status == .failed || request.responseState == .failed
        let titleBottom = appendCardHeader(
            into: &body.builder, width: width, header: header, inset: inset,
            title: isApproval ? "Approval requested" : "Question", titleFont: NSFont.token(.title, zoom: zoom),
            titleColor: primary, status: AgentRequestView.statusText(payload: request), statusAttention: statusAttention)
        _ = titleBottom
        let promptFont = NSFont.token(.body, zoom: zoom)
        let prompt = NSAttributedString(string: agentPlainText(request.prompt),
                                        attributes: [.font: promptFont, .foregroundColor: primary])
        var set = Self.typeset(prompt, width: max(1, width - inset * 2), originX: inset, top: header,
                               firstIndent: 0, headIndent: 0, linePitch: 0, fallbackFont: promptFont)
        if set.lines.count > 4 { set.lines = Array(set.lines.prefix(4)) }
        let promptHeight = max(lineHeight(.body), min(set.lines.reduce(0) { $0 + $1.height }, lineHeight(.body) * 4))
        body.builder.rows.append(TextRow(string: prompt, lines: set.lines, links: []))
        var y = header + promptHeight
        let actionable = request.requestID != nil && [.pending, .inProgress].contains(request.status)
            && !request.choices.isEmpty && renderContext.canRespondToRequests
        if actionable, let requestID = request.requestID {
            y += S(Space.m)
            let choices = Array(request.choices.prefix(AgentRequestView.maximumChoices))
            let gap = S(Space.s)
            let buttonWidth = max(1, (width - inset * 2 - gap * CGFloat(choices.count - 1)) / CGFloat(choices.count))
            for (index, choice) in choices.enumerated() {
                body.builder.controls.append(Control(
                    rect: CGRect(x: inset + CGFloat(index) * (buttonWidth + gap), y: y, width: buttonWidth, height: actionHeight),
                    title: ApprovalDecision.displayTitle(forChoice: choice), style: .choice,
                    action: .perform(.submitResponse(requestID: requestID, value: choice)),
                    // A response already on the wire must not be sent twice.
                    enabled: request.responseState != .submitting,
                    font: NSFont.token(.label, zoom: zoom)))
            }
            y += actionHeight
        }
        body.height = ceil(y + AgentRequestView.bottomInset(zoom: zoom))
        body.builder.decorations.insert(.fill(CGRect(x: 0, y: 0, width: width, height: body.height),
                                              renderContext.tokens.artifactSurface.color.cgColor(for: theme),
                                              radius: CGFloat(zoom.scaled(CornerRole.artifact.radius))), at: 0)
        _ = block
        return body
    }

    /// A card header: title at the left, trailing status, both centred in `header`.
    @discardableResult
    func appendCardHeader(into builder: inout Builder, width: CGFloat, header: CGFloat, inset: CGFloat,
                          title: String, titleFont: NSFont, titleColor: NSColor, status: String?,
                          statusAttention: Bool) -> CGFloat {
        var titleLimit = width - inset - S(Space.m)
        if let status, !status.isEmpty {
            let caption = NSFont.token(.caption, zoom: zoom)
            let line = Self.line(status, font: caption,
                                 color: statusAttention ? AgentLineRole.attention.color.nsColor(for: theme) : secondary)
            let statusWidth = min(ceil(Self.width(of: line)) + S(Space.s), width * 0.4)
            let statusX = max(inset, width - inset - statusWidth)
            builder.decorations.append(.text(line, CGPoint(x: statusX, y: Self.centredBaseline(font: caption, top: 0, height: header))))
            titleLimit = statusX - S(Space.m)
        }
        let titleString = NSAttributedString(string: title, attributes: [.font: titleFont, .foregroundColor: titleColor])
        let line = Self.singleLine(titleString, x: inset, top: 0, height: header, maxWidth: max(1, titleLimit - inset), font: titleFont)
        builder.decorations.append(.text(line.ctLine, CGPoint(x: line.x, y: line.baseline)))
        return header
    }

    // MARK: Errors and notices (ErrorNoticeRenderer)

    func errorBody(_ block: AgentBlock, error: AgentErrorPayload, width: CGFloat) -> Body {
        let contextFull = error.message == AgentContextFullRecovery.canonicalErrorMessage
        var actions: [(String, AgentRenderAction)] = []
        if contextFull {
            actions = [("Compact & retry", .contextFullRecovery(blockID: block.id, action: .compactAndRetry)),
                       ("New session with summary", .contextFullRecovery(blockID: block.id, action: .forkWithSummary)),
                       ("Copy transcript", .contextFullRecovery(blockID: block.id, action: .copyTranscript))]
        } else {
            if error.isRecoverable { actions.append(("Retry", .retry(blockID: block.id))) }
            actions.append(("Copy details", .copy(blockID: block.id)))
        }
        let metadata = error.code.map { ToolCallView.safeSingleLine($0, fallback: "") }.flatMap { $0.isEmpty ? nil : $0 }
        var body = errorNoticeBody(
            title: contextFull ? "Context full" : "Error",
            status: contextFull ? "! Recovery available" : "! Failed", isError: true,
            message: contextFull ? AgentErrorNoticeView.contextFullRecoveryMessage : error.message,
            metadata: metadata, actions: actions, stacked: contextFull, width: width)
        body.builder.decorations.append(.stroke(CGRect(x: 0, y: 0, width: width, height: body.height),
                                                AgentLineRole.attention.color.cgColor(for: theme),
                                                radius: CGFloat(zoom.scaled(CornerRole.artifact.radius)), width: hairline))
        return body
    }

    func noticeBody(_ notice: AgentNoticePayload, width: CGFloat) -> Body {
        let status = notice.status.map { "\($0.agentToolStatusPresentation.glyph) \($0.agentToolStatusPresentation.label)" }
        return errorNoticeBody(title: "Notice", status: status, isError: false, message: agentPlainText(notice.message),
                               metadata: nil, actions: [], stacked: false, width: width)
    }

    private func errorNoticeBody(title: String, status: String?, isError: Bool, message: String, metadata: String?,
                                 actions: [(String, AgentRenderAction)], stacked: Bool, width: CGFloat) -> Body {
        let header = S(Space.xxl + Space.l)
        let inset = S(Space.l)
        let actionHeight = S(Space.xxl + Space.xs)
        var body = Body()
        // An error's status reads in the attention colour, a notice's does not.
        appendCardHeader(into: &body.builder, width: width, header: header, inset: inset, title: title,
                         titleFont: NSFont.token(.title, zoom: zoom), titleColor: isError ? primary : secondary,
                         status: status, statusAttention: isError)
        let bodyFont = NSFont.token(.body, zoom: zoom)
        let string = NSAttributedString(string: message, attributes: [.font: bodyFont, .foregroundColor: primary])
        var set = Self.typeset(string, width: max(1, width - inset * 2), originX: inset, top: header,
                               firstIndent: 0, headIndent: 0, linePitch: 0, fallbackFont: bodyFont)
        if set.lines.count > 5 { set.lines = Array(set.lines.prefix(5)) }
        body.builder.rows.append(TextRow(string: string, lines: set.lines, links: []))
        var y = header + max(lineHeight(.body), min(set.lines.reduce(0) { $0 + $1.height }, lineHeight(.body) * 5))
        if let metadata {
            y += S(Space.s)
            let font = NSFont.token(.captionMono, zoom: zoom)
            let meta = NSAttributedString(string: metadata, attributes: [.font: font, .foregroundColor: secondary])
            body.builder.rows.append(TextRow(string: meta, lines: [Self.singleLine(
                meta, x: inset, top: y, height: lineHeight(.caption), maxWidth: max(1, width - inset * 2), font: font)], links: []))
            y += lineHeight(.caption)
        }
        if !actions.isEmpty {
            y += S(Space.m)
            let font = NSFont.token(.label, zoom: zoom)
            if stacked {
                for (index, action) in actions.enumerated() {
                    if index > 0 { y += S(Space.xs) }
                    body.builder.controls.append(Control(rect: CGRect(x: inset, y: y, width: width - inset * 2, height: actionHeight),
                                                         title: action.0, style: .choice, action: .perform(action.1), font: font))
                    y += actionHeight
                }
            } else {
                let gap = S(Space.s)
                let buttonWidth = max(1, (width - inset * 2 - gap * CGFloat(actions.count - 1)) / CGFloat(actions.count))
                for (index, action) in actions.enumerated() {
                    body.builder.controls.append(Control(
                        rect: CGRect(x: inset + CGFloat(index) * (buttonWidth + gap), y: y, width: buttonWidth, height: actionHeight),
                        title: action.0, style: .choice, action: .perform(action.1), font: font))
                }
                y += actionHeight
            }
        }
        body.height = ceil(y + S(Space.l))
        if isError {
            body.builder.decorations.insert(.fill(CGRect(x: 0, y: 0, width: width, height: body.height),
                                                  renderContext.tokens.artifactSurface.color.cgColor(for: theme),
                                                  radius: CGFloat(zoom.scaled(CornerRole.artifact.radius))), at: 0)
        }
        return body
    }

    // MARK: File changes (DiffSummaryRenderer)

    func diffBody(_ block: AgentBlock, diff: AgentDiffPayload, width: CGFloat) -> Body {
        let inset = AgentDiffSummaryView.horizontalInset(zoom: zoom)
        let header = AgentDiffSummaryView.headerHeight(zoom: zoom)
        let fileRow = AgentDiffSummaryView.fileRowHeight(zoom: zoom)
        let caption = NSFont.token(.caption, zoom: zoom)
        var body = Body()
        let counts = AgentDiffSummaryView.countsText(diff.files, pending: diff.presentedFilesArePending)
        let countsFont = NSFont.monospacedDigitSystemFont(ofSize: caption.pointSize, weight: .regular)
        let countsLine = Self.line(counts, font: countsFont, color: secondary)
        let countsWidth = min(ceil(Self.width(of: countsLine)) + S(Space.s), width * 0.5)
        body.builder.decorations.append(.text(countsLine, CGPoint(
            x: max(inset, width - inset - countsWidth), y: Self.centredBaseline(font: caption, top: 0, height: header))))
        let title = CTLineCreateWithAttributedString(Self.coreTextString(NSAttributedString(
            string: "CHANGES", attributes: [.font: caption, .kern: 0.8, .foregroundColor: secondary])))
        body.builder.decorations.append(.text(title, CGPoint(x: inset, y: Self.centredBaseline(font: caption, top: 0, height: header))))
        var y = header
        let summary = diff.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !summary.isEmpty {
            let font = NSFont.token(.body, zoom: zoom)
            let string = NSAttributedString(string: summary, attributes: [.font: font, .foregroundColor: primary])
            var set = Self.typeset(string, width: max(1, width - inset * 2), originX: inset, top: y,
                                   firstIndent: 0, headIndent: 0, linePitch: 0, fallbackFont: font)
            if set.lines.count > 2 { set.lines = Array(set.lines.prefix(2)) }
            body.builder.rows.append(TextRow(string: string, lines: set.lines, links: []))
            y += min(set.lines.reduce(0) { $0 + $1.height }, lineHeight(.body) * 2) + S(Space.s)
        }
        let added = AccentToken.accentDone.color.nsColor(for: theme)
        let removed = AccentToken.accentFailed.color.nsColor(for: theme)
        let mono = NSFont.monospacedSystemFont(ofSize: NSFont.token(.label, zoom: zoom).pointSize, weight: .regular)
        for file in diff.files.prefix(AgentDiffSummaryView.maximumVisibleFiles) {
            let barWidth = min(AgentDiffSummaryView.statBarWidth(zoom: zoom), width * 0.22)
            let barX = width - inset - barWidth
            let total = CGFloat(file.addedLineCount ?? 0) + CGFloat(file.removedLineCount ?? 0)
            if total > 0 {
                let barHeight = S(Space.s)
                let barY = y + (fileRow - barHeight) / 2
                let addedWidth = (barWidth * CGFloat(file.addedLineCount ?? 0) / total).rounded()
                let radius = CornerStyle.current == .sharp ? 0 : barHeight / 2
                if addedWidth > 0 {
                    body.builder.decorations.append(.fill(CGRect(x: barX, y: barY, width: addedWidth, height: barHeight), added.cgColor, radius: radius))
                }
                if barWidth - addedWidth > 0 {
                    body.builder.decorations.append(.fill(CGRect(x: barX + addedWidth, y: barY, width: barWidth - addedWidth, height: barHeight), removed.cgColor, radius: radius))
                }
            }
            let stat = AgentDiffSummaryView.statText(file, added: added, removed: removed, unavailable: secondary, zoom: zoom)
            let statLine = CTLineCreateWithAttributedString(Self.coreTextString(stat))
            let statWidth = min(ceil(Self.width(of: statLine)) + S(Space.s), width * 0.34)
            let statX = max(inset, barX - S(Space.s) - statWidth)
            body.builder.decorations.append(.text(statLine, CGPoint(x: statX, y: Self.centredBaseline(font: mono, top: y, height: fileRow))))
            let name = NSAttributedString(string: ToolCallView.safeSingleLine(file.displayName, fallback: "Changed file"),
                                          attributes: [.font: mono, .foregroundColor: primary])
            body.builder.rows.append(TextRow(string: name, lines: [Self.singleLine(
                name, x: inset, top: y, height: fileRow, maxWidth: max(1, statX - inset - S(Space.s)), font: mono,
                truncation: .middle)], links: []))
            y += fileRow
        }
        let overflow = diff.files.count - AgentDiffSummaryView.maximumVisibleFiles
        if overflow > 0 {
            body.builder.decorations.append(.text(Self.line("+\(overflow) more files", font: caption, color: secondary),
                                                  CGPoint(x: inset, y: Self.centredBaseline(font: caption, top: y, height: fileRow))))
            y += fileRow
        }
        if !diff.text.isEmpty {
            let model = AgentDiffSummaryView.parsedModel(blockID: block.id, revision: block.revision, text: diff.text)
            let rendered = AgentDiffSummaryView.truncatedBody(model: model, theme: theme)
            if rendered.shown > 0 {
                y += AgentDiffSummaryView.bodySpacing(zoom: zoom)
                let set = Self.typeset(rendered.attributed, width: max(1, width - inset * 2), originX: inset, top: y,
                                       firstIndent: 0, headIndent: 0, linePitch: 0,
                                       fallbackFont: NSFont.token(.bodyMono, zoom: zoom))
                body.builder.rows.append(TextRow(string: rendered.attributed, lines: set.lines, links: []))
                y += set.height
                if rendered.total > rendered.shown {
                    y += S(Space.xs)
                    body.builder.decorations.append(.text(
                        Self.line("+\(rendered.total - rendered.shown) more lines", font: caption, color: secondary),
                        CGPoint(x: inset, y: Self.centredBaseline(font: caption, top: y, height: fileRow))))
                    y += fileRow
                }
            }
        }
        if diff.canOpenReview {
            let font = NSFont.token(.label, zoom: zoom)
            body.builder.controls.append(textControl(
                "Open Review →", font: font, leftEdge: inset, top: y + S(Space.xs),
                height: AgentDiffSummaryView.actionHeight(zoom: zoom), action: .perform(.openDiff(blockID: block.id)),
                tint: primary))
            y += S(Space.xs) + AgentDiffSummaryView.actionHeight(zoom: zoom)
        }
        body.height = ceil(y + AgentDiffSummaryView.bottomInset(zoom: zoom))
        body.builder.decorations.insert(.fill(CGRect(x: 0, y: 0, width: width, height: body.height),
                                              renderContext.tokens.artifactSurface.color.cgColor(for: theme),
                                              radius: CGFloat(zoom.scaled(CornerRole.artifact.radius))), at: 0)
        body.clips = true
        return body
    }

    // MARK: File attachments (FileReferenceRenderer)

    func fileReferencesBody(_ files: [AgentFileReferenceMetadata], width: CGFloat) -> Body {
        guard !files.isEmpty else { return Body() }
        let height = AgentFileReferenceRailView.railHeight(zoom: zoom)
        let chipHeight = S(26)
        let glyphFont = NSFont.systemFont(ofSize: S(13), weight: .semibold)
        let caption = NSFont.token(.caption, zoom: zoom)
        var body = Body(height: height, clips: true)
        var x: CGFloat = 0
        let top = (height - chipHeight) / 2
        let radius = CGFloat(zoom.scaled(CornerRole.artifact.radius))
        for file in files {
            let glyph = Self.line("▤", font: glyphFont, color: secondary)
            let name = NSAttributedString(string: ComposerImageDisplay.sanitizedFilename(file.displayName, fallback: "File"),
                                          attributes: [.font: caption, .foregroundColor: primary])
            let nameWidth = min(ceil(Self.width(of: CTLineCreateWithAttributedString(Self.coreTextString(name)))), S(200))
            let glyphWidth = ceil(Self.width(of: glyph))
            let chipWidth = S(Space.s) + glyphWidth + S(Space.xs) + nameWidth + S(Space.s)
            let chip = CGRect(x: x, y: top, width: chipWidth, height: chipHeight)
            body.builder.decorations.append(.fill(chip, renderContext.tokens.artifactSurface.color.cgColor(for: theme), radius: radius))
            body.builder.decorations.append(.stroke(chip, renderContext.tokens.decorativeLine.color.cgColor(for: theme),
                                                    radius: radius, width: hairline))
            body.builder.decorations.append(.text(glyph, CGPoint(x: x + S(Space.s), y: Self.centredBaseline(font: glyphFont, top: top, height: chipHeight))))
            body.builder.rows.append(TextRow(string: name, lines: [Self.singleLine(
                name, x: x + S(Space.s) + glyphWidth + S(Space.xs), top: top, height: chipHeight,
                maxWidth: nameWidth, font: caption, truncation: .middle)], links: []))
            x += chipWidth + S(Space.s)
        }
        return body
    }

    // MARK: Plans (PlanRenderer)

    func planBody(_ plan: AgentPlanPayload, width: CGFloat) -> Body {
        let header = S(Space.xxl + Space.xs)
        let inset = S(Space.l)
        let rowBase = S(Space.xl + Space.s)
        var body = Body()
        let presentation = plan.status.agentToolStatusPresentation
        let title = (plan.title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "Plan"
        appendCardHeader(into: &body.builder, width: width, header: header, inset: inset, title: title,
                         titleFont: NSFont.token(.label, zoom: zoom), titleColor: primary,
                         status: "\(presentation.glyph) \(presentation.label)", statusAttention: plan.status == .failed)
        var y = header
        let label = NSFont.token(.label, zoom: zoom)
        let caption = NSFont.token(.caption, zoom: zoom)
        for row in AgentPlanView.flatten(plan.steps).prefix(100) {
            let indent = CGFloat(min(row.depth, 5)) * S(Space.l)
            let glyph = row.step.status.agentToolStatusPresentation.glyph
            let text = "\(row.ordinal)  \(glyph) \(ToolCallView.safeSingleLine(row.step.title, fallback: "Step"))"
            let string = NSAttributedString(string: text, attributes: [.font: label, .foregroundColor: primary])
            let titleHeight = ceil(label.ascender - label.descender + label.leading)
            body.builder.rows.append(TextRow(string: string, lines: [Self.singleLine(
                string, x: inset + indent, top: y + S(Space.xs), height: titleHeight,
                maxWidth: max(1, width - inset * 2 - indent), font: label)], links: []))
            var rowHeight = rowBase
            let detail = row.step.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if row.step.status != .completed, !detail.isEmpty {
                let detailString = NSAttributedString(string: detail, attributes: [.font: caption, .foregroundColor: secondary])
                var set = Self.typeset(detailString, width: max(1, width - inset * 2 - indent - S(Space.xxl)),
                                       originX: inset + indent + S(Space.xxl), top: y + S(Space.xs) + titleHeight + S(Space.xs),
                                       firstIndent: 0, headIndent: 0, linePitch: 0, fallbackFont: caption)
                if set.lines.count > 2 { set.lines = Array(set.lines.prefix(2)) }
                body.builder.rows.append(TextRow(string: detailString, lines: set.lines, links: []))
                rowHeight += min(set.lines.reduce(0) { $0 + $1.height }, lineHeight(.caption) * 2)
            }
            y += rowHeight
        }
        body.height = ceil(y + S(Space.s))
        body.builder.decorations.insert(.fill(CGRect(x: 0, y: 0, width: width, height: body.height),
                                              renderContext.tokens.artifactSurface.color.cgColor(for: theme),
                                              radius: CGFloat(zoom.scaled(CornerRole.artifact.radius))), at: 0)
        body.clips = true
        return body
    }

    // MARK: Tables (TableRenderer)

    /// The same prepared cells and column widths `AgentTableView` computes; each
    /// cell placed and wrapped here, rules drawn as fills.
    func tableBody(_ table: AgentTablePayload, width: CGFloat) -> Body? {
        guard let prepared = AgentTableView.prepare(table, context: renderContext) else { return nil }
        let widths = AgentTableView.columnWidths(prepared, width: width, zoom: zoom)
        let gutter = S(Space.l)
        let padding = S(Space.xs)
        var body = Body()
        var y: CGFloat = 0
        let fallback = NSFont.token(.body, zoom: zoom)
        for (rowIndex, cells) in prepared.rows.enumerated() {
            var x: CGFloat = 0
            var rowHeight: CGFloat = 0
            var rowCells: [TextRow] = []
            for (column, cell) in cells.enumerated() where column < widths.count {
                let set = Self.typeset(cell, width: max(1, widths[column]), originX: x, top: y + padding,
                                       firstIndent: 0, headIndent: 0, linePitch: 0, fallbackFont: fallback)
                let alignment = prepared.alignments.indices.contains(column) ? prepared.alignments[column] : .left
                let lines = set.lines.map { line -> Line in
                    switch alignment {
                    case .center: return line.shifted(dx: (widths[column] - line.width) / 2, dy: 0)
                    case .right: return line.shifted(dx: widths[column] - line.width, dy: 0)
                    default: return line
                    }
                }
                rowCells.append(TextRow(string: cell, lines: lines, links: []))
                rowHeight = max(rowHeight, set.height)
                x += widths[column] + gutter
            }
            body.builder.rows += rowCells
            y += rowHeight + padding * 2
            if prepared.hasHeader, rowIndex == 0 {
                body.builder.decorations.append(.fill(CGRect(x: 0, y: y - 1, width: min(width, x - gutter), height: 1),
                                                      AgentLineRole.controlBoundary.color.cgColor(for: theme), radius: 0))
            } else if rowIndex < prepared.rows.count - 1 {
                body.builder.decorations.append(.fill(CGRect(x: 0, y: y - hairline, width: min(width, x - gutter), height: hairline),
                                                      AgentLineRole.decorativeHairline.color.cgColor(for: theme), radius: 0))
            }
        }
        body.height = ceil(y)
        return body
    }

    // MARK: Images (ImageRenderer)

    func imagesBody(_ block: AgentBlock, images: [AgentImagePayload], gallery: Bool, width: CGFloat) -> Body {
        let hInset = S(Space.l), vInset = S(Space.l), gap = S(Space.m), cellInset = S(Space.m)
        guard !images.isEmpty else { return Body(height: 2 * vInset + lineHeight(.label)) }
        let columns: Int
        if !gallery || images.count == 1 { columns = 1 } else if width >= S(560) { columns = 3 } else if width >= S(340) { columns = 2 } else { columns = 1 }
        let cellWidth = floor((width - 2 * hInset - CGFloat(columns - 1) * gap) / CGFloat(columns))
        let areaWidth = max(1, cellWidth - 2 * cellInset)
        let cap = gallery ? S(180) : S(360)
        var body = Body()
        let label = NSFont.token(.label, zoom: zoom)
        let caption = NSFont.token(.caption, zoom: zoom)
        var rowTop = vInset
        var index = 0
        while index < images.count {
            let rowImages = images[index..<min(images.count, index + columns)]
            var rowHeight: CGFloat = 0
            for (column, image) in rowImages.enumerated() {
                let attachment = image.attachment
                let snapshot = renderContext.imageResources.snapshot(attachment.id)
                let ratio: CGFloat
                if let size = snapshot.pixelSize, size.width > 0, size.height > 0 { ratio = size.width / size.height }
                else if let w = attachment.pixelWidth, let h = attachment.pixelHeight, w > 0, h > 0 { ratio = CGFloat(w) / CGFloat(h) }
                else { ratio = 4.0 / 3.0 }
                let imageHeight = min(max(S(72), ceil(areaWidth / ratio)), cap)
                let captionText = agentPlainText(image.caption)
                let cellHeight = cellInset + lineHeight(.label) + S(Space.xs) + lineHeight(.caption) + S(Space.m) + imageHeight
                    + (captionText.isEmpty ? 0 : S(Space.m) + lineHeight(.caption)) + cellInset
                rowHeight = max(rowHeight, cellHeight)
                let cell = CGRect(x: hInset + CGFloat(column) * (cellWidth + gap), y: rowTop, width: cellWidth, height: cellHeight)
                let radius = CGFloat(zoom.scaled(CornerRole.card.radius))
                body.builder.decorations.append(.fill(cell, SurfaceToken.tileBody.color.cgColor(for: theme), radius: radius))
                body.builder.decorations.append(.stroke(cell, renderContext.tokens.decorativeLine.color.cgColor(for: theme),
                                                        radius: radius, width: hairline))
                let name = snapshot.displayName ?? attachment.displayName.map { String(($0 as NSString).lastPathComponent.prefix(80)) }
                let titleString = NSAttributedString(string: name.flatMap { $0.isEmpty ? nil : $0 } ?? "Image \(index + column + 1)",
                                                     attributes: [.font: label, .foregroundColor: primary])
                var y = cell.minY + cellInset
                body.builder.rows.append(TextRow(string: titleString, lines: [Self.singleLine(
                    titleString, x: cell.minX + cellInset, top: y, height: lineHeight(.label), maxWidth: areaWidth,
                    font: label, truncation: .middle)], links: []))
                y += lineHeight(.label) + S(Space.xs)
                let meta = Self.imageMetadata(attachment: attachment, snapshot: snapshot)
                let metaString = NSAttributedString(string: meta, attributes: [.font: caption, .foregroundColor: secondary])
                body.builder.rows.append(TextRow(string: metaString, lines: [Self.singleLine(
                    metaString, x: cell.minX + cellInset, top: y, height: lineHeight(.caption), maxWidth: areaWidth,
                    font: caption)], links: []))
                y += lineHeight(.caption) + S(Space.m)
                let imageRect = CGRect(x: cell.minX + cellInset, y: y, width: areaWidth, height: imageHeight)
                let placeholder = Self.imagePlaceholder(snapshot.state)
                body.builder.decorations.append(.image(attachment.id, imageRect,
                                                       placeholder: Self.line(placeholder, font: caption, color: secondary)))
                requestImageSource(attachment, snapshot: snapshot, blockID: block.id)
                let previewable = snapshot.state == .available && snapshot.canPreview
                body.builder.controls.append(Control(
                    rect: imageRect, title: titleString.string, style: .region(hoverFill: nil, pressedFill: nil, radius: 0),
                    action: .perform(.previewImage(blockID: block.id, attachmentID: attachment.id)), enabled: previewable))
                body.builder.images.append(AgentImageMenuTarget(rect: imageRect, blockID: block.id,
                                                                attachmentID: attachment.id, snapshot: snapshot))
                y += imageHeight
                if !captionText.isEmpty {
                    y += S(Space.m)
                    let captionString = NSAttributedString(string: captionText, attributes: [.font: caption, .foregroundColor: secondary])
                    body.builder.rows.append(TextRow(string: captionString, lines: [Self.singleLine(
                        captionString, x: cell.minX + cellInset, top: y, height: lineHeight(.caption),
                        maxWidth: areaWidth, font: caption)], links: []))
                }
            }
            rowTop += rowHeight + gap
            index += columns
        }
        body.height = ceil(rowTop - gap + vInset)
        return body
    }

    private static func imagePlaceholder(_ state: AgentImageResourceState) -> String {
        switch state {
        case .available: return "Image ready"
        case .processing: return "Processing image…"
        case .failed: return "Image failed"
        case .missing: return "Image unavailable on this host"
        }
    }

    private static func imageMetadata(attachment: AgentImageAttachmentMetadata, snapshot: AgentImageResourceSnapshot) -> String {
        var parts: [String] = []
        if let type = snapshot.contentType ?? attachment.contentType {
            parts.append(UTType(type)?.preferredFilenameExtension?.uppercased() ?? type)
        }
        if let size = snapshot.pixelSize {
            parts.append("\(Int(size.width))×\(Int(size.height))")
        } else if let w = attachment.pixelWidth, let h = attachment.pixelHeight {
            parts.append("\(w)×\(h)")
        }
        if let bytes = snapshot.byteCount ?? attachment.byteCount {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        }
        switch snapshot.state {
        case .available: parts.append("Available locally")
        case .processing: parts.append("Processing")
        case .failed: parts.append("Failed")
        case .missing: parts.append("Missing")
        }
        return parts.joined(separator: " · ")
    }

    /// Asks the host for the image at its FULL pixel size, once per revision, and
    /// watches it for changes. Drawing scales that source to whatever the layer is
    /// shown at; there is no downscaled copy.
    func requestImageSource(_ attachment: AgentImageAttachmentMetadata, snapshot: AgentImageResourceSnapshot, blockID: AgentNodeID) {
        let id = attachment.id
        if imageObservations[id] == nil {
            imageObservations[id] = renderContext.imageResources.observe(id: id) { [weak self] _ in
                guard let self else { return }
                self.imageSources[id] = nil
                self.imageRequests[id]?.cancel()
                self.imageRequests[id] = nil
                self.invalidatePresentation(of: blockID)
            }
        }
        guard snapshot.state == .available, imageSources[id]?.revision != snapshot.revision, imageRequests[id] == nil else { return }
        let full = snapshot.pixelSize
            ?? attachment.pixelWidth.flatMap { w in attachment.pixelHeight.map { NSSize(width: CGFloat(w), height: CGFloat($0)) } }
            ?? NSSize(width: 4096, height: 4096)
        let revision = snapshot.revision
        imageRequests[id] = renderContext.imageResources.requestThumbnail(id: id, targetPixelSize: full, revision: revision) { [weak self] result in
            guard let self else { return }
            self.imageRequests[id] = nil
            if case let .success(source) = result, source.attachmentID == id, source.revision == revision {
                self.imageSources[id] = (revision, source.image)
                self.needsDisplay = true
            }
        }
    }

    // MARK: Agent references (AgentReferenceRenderer)

    func agentReferenceBody(_ block: AgentBlock, width: CGFloat) -> Body {
        let references = AgentReferenceRenderer.references(in: block)
        let label = NSFont.token(.label, zoom: zoom)
        var widths: [CGFloat] = []
        var titles: [(name: String, status: String?, accent: NSColor?)] = []
        for reference in references {
            let state = renderContext.agentStatus.current(reference.payload.agentID)
            let raw = reference.payload.displayNameAtSpawn.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let trimmed = String(raw.trimmingCharacters(in: .whitespaces).prefix(80))
            let name = trimmed.isEmpty ? "Subagent" : trimmed
            titles.append((name, state?.label, state?.accent.map { $0.color.nsColor(for: theme) }))
            widths.append(AgentReferenceChipView.preferredWidth(name: name, label: state?.label, zoom: zoom))
            subscribeStatus(reference.payload.agentID, blockID: block.id)
        }
        let flow = AgentReferenceChipRowView.flow(widths: widths, width: width, zoom: zoom)
        var body = Body(height: flow.height)
        let radius = CGFloat(zoom.scaled(CornerRole.artifact.radius))
        for (index, reference) in references.enumerated() where index < flow.frames.count {
            let chip = flow.frames[index]
            let info = titles[index]
            let fill = info.accent?.withAlphaComponent(0.09).cgColor
            if let fill { body.builder.decorations.append(.fill(chip, fill, radius: radius)) }
            body.builder.decorations.append(.stroke(chip, (info.accent?.withAlphaComponent(0.42) ?? renderContext.tokens.decorativeLine.color.nsColor(for: theme)).cgColor,
                                                    radius: radius, width: hairline))
            let title = NSMutableAttributedString(string: info.name, attributes: [.font: label, .foregroundColor: primary])
            if let status = info.status {
                title.append(NSAttributedString(string: "  ·  \(status)", attributes: [.font: label, .foregroundColor: secondary]))
            }
            let glyphBox = S(14)
            let titleWidth = min(ceil(Self.width(of: CTLineCreateWithAttributedString(Self.coreTextString(title)))),
                                 chip.width - glyphBox - S(Space.s) - 2 * S(Space.l))
            let contentX = chip.minX + (chip.width - (glyphBox + S(Space.s) + titleWidth)) / 2
            if let glyph = Self.symbol("person.2.fill", pointSize: S(11), color: info.accent ?? secondary, weight: .semibold) {
                body.builder.decorations.append(.symbol(glyph, CGRect(
                    x: contentX + (glyphBox - glyph.size.width) / 2, y: chip.midY - glyph.size.height / 2,
                    width: glyph.size.width, height: glyph.size.height)))
            }
            body.builder.rows.append(TextRow(string: title, lines: [Self.singleLine(
                title, x: contentX + glyphBox + S(Space.s), top: chip.minY, height: chip.height,
                maxWidth: max(1, titleWidth), font: label)], links: []))
            body.builder.controls.append(Control(
                rect: chip, title: "Open subagent \(info.name)",
                style: .region(hoverFill: AgentSurfaceRole.rowHover.color.cgColor(for: theme),
                               pressedFill: AgentSurfaceRole.rowSelected.color.cgColor(for: theme), radius: radius),
                action: .perform(.revealAgent(blockID: reference.blockID, agentID: reference.payload.agentID,
                                              parentAgentID: reference.payload.parentAgentID))))
        }
        return body
    }

    private func subscribeStatus(_ agentID: UUID, blockID: AgentNodeID) {
        guard statusSubscriptions[agentID] == nil else { return }
        if let token = renderContext.agentStatus.subscribe(agentID, { [weak self] _ in
            Task { @MainActor [weak self] in self?.invalidatePresentation(of: blockID) }
        }) {
            statusSubscriptions[agentID] = token
        }
    }

    // MARK: Task references (TaskReferenceRenderer)

    func taskReferenceBody(_ task: AgentTaskReferencePayload, width: CGFloat) -> Body {
        let summary = task.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasSummary = !summary.isEmpty
        let cardHeight = S(hasSummary ? 44 : 26)
        let rowHeight = cardHeight + S(14)
        let label = NSFont.token(.label, zoom: zoom)
        let caption = NSFont.token(.caption, zoom: zoom)
        let textX = S(Space.s) + S(14) + S(Space.xs)
        let titleString = NSAttributedString(string: task.title, attributes: [.font: label, .foregroundColor: primary])
        let summaryString = NSAttributedString(string: summary, attributes: [.font: caption, .foregroundColor: secondary])
        let titleWidth = Self.width(of: CTLineCreateWithAttributedString(Self.coreTextString(titleString)))
        let summaryWidth = hasSummary ? Self.width(of: CTLineCreateWithAttributedString(Self.coreTextString(summaryString))) : 0
        let cardWidth = min(width, ceil(textX + max(titleWidth, summaryWidth) + S(Space.m)), S(440))
        let card = CGRect(x: 0, y: (rowHeight - cardHeight) / 2, width: cardWidth, height: cardHeight)
        var body = Body(height: rowHeight)
        let radius = CGFloat(zoom.scaled(CornerRole.artifact.radius))
        body.builder.decorations.append(.fill(card, renderContext.tokens.artifactSurface.color.cgColor(for: theme), radius: radius))
        body.builder.decorations.append(.stroke(card, renderContext.tokens.decorativeLine.color.cgColor(for: theme), radius: radius, width: hairline))
        let lineHeight = S(17)
        let titleY = card.minY + (hasSummary ? S(5) : floor((cardHeight - lineHeight) / 2))
        let glyphFont = NSFont.systemFont(ofSize: S(13), weight: .semibold)
        body.builder.decorations.append(.text(Self.line("▣", font: glyphFont, color: secondary),
                                              CGPoint(x: S(Space.s), y: Self.centredBaseline(font: glyphFont, top: titleY, height: lineHeight))))
        let textWidth = max(1, cardWidth - textX - S(Space.s))
        body.builder.rows.append(TextRow(string: titleString, lines: [Self.singleLine(
            titleString, x: textX, top: titleY, height: lineHeight, maxWidth: textWidth, font: label)], links: []))
        if hasSummary {
            body.builder.rows.append(TextRow(string: summaryString, lines: [Self.singleLine(
                summaryString, x: textX, top: titleY + lineHeight, height: lineHeight, maxWidth: textWidth, font: caption)], links: []))
        }
        return body
    }

    // MARK: Agent messages (AgentMessageRenderer)

    func messageBody(_ block: AgentBlock, message: AgentMessagePayload, width: CGFloat) -> Body {
        let rowInset = S(7), padding = S(Space.m), accentWidth = S(3)
        let cardWidth = min(width, S(640))
        let sender = message.senderAgentID.flatMap { renderContext.agentMessageSenders.current($0) }
        let accent = sender?.identityColorName.map { ZoneChromeNSView.color(named: $0) }
        let label = NSFont.token(.label, zoom: zoom)
        let bodyFont = NSFont.token(.body, zoom: zoom)
        let contentX = accentWidth + padding
        let bodyWidth = max(1, cardWidth - accentWidth - 2 * padding)
        let headerTop = rowInset + padding
        let headerHeight = S(18)
        let text = NSAttributedString(string: message.text, attributes: [.font: bodyFont, .foregroundColor: primary])
        let set = Self.typeset(text, width: bodyWidth, originX: contentX, top: headerTop + headerHeight + S(Space.xs),
                               firstIndent: 0, headIndent: 0, linePitch: 0, fallbackFont: bodyFont)
        let cardHeight = 2 * padding + headerHeight + S(Space.xs) + set.height
        let card = CGRect(x: 0, y: rowInset, width: cardWidth, height: cardHeight)
        var body = Body(height: ceil(cardHeight + 2 * rowInset))
        let radius = CGFloat(zoom.scaled(AgentTileRadius.artifact))
        body.builder.decorations.append(.fill(card, renderContext.tokens.artifactSurface.color.cgColor(for: theme), radius: radius))
        body.builder.decorations.append(.fill(CGRect(x: 0, y: rowInset + radius / 2, width: accentWidth, height: cardHeight - radius),
                                              (accent ?? renderContext.tokens.decorativeLine.color.nsColor(for: theme)).cgColor, radius: 0))
        body.builder.decorations.append(.stroke(card, renderContext.tokens.decorativeLine.color.cgColor(for: theme), radius: radius, width: hairline))
        var x = contentX
        if let glyph = Self.symbol("bubble.left.fill", pointSize: S(11), color: accent ?? secondary, weight: .semibold) {
            body.builder.decorations.append(.symbol(glyph, CGRect(x: x + (S(12) - glyph.size.width) / 2,
                                                                  y: headerTop + (headerHeight - glyph.size.height) / 2,
                                                                  width: glyph.size.width, height: glyph.size.height)))
        }
        x += S(12) + S(Space.xs)
        let header = NSMutableAttributedString(string: message.senderName, attributes: [
            .font: NSFont.systemFont(ofSize: label.pointSize, weight: .semibold), .foregroundColor: primary])
        header.append(NSAttributedString(string: "  ·  \(AgentMessageCardView.caption(message.origin))",
                                         attributes: [.font: label, .foregroundColor: secondary]))
        let headerLine = Self.singleLine(header, x: x, top: headerTop, height: headerHeight,
                                         maxWidth: max(1, cardWidth - x - padding), font: label)
        body.builder.rows.append(TextRow(string: header, lines: [headerLine], links: []))
        body.builder.rows.append(TextRow(string: text, lines: set.lines, links: []))
        if message.origin == .array, sender?.hasTile == true, let senderID = message.senderAgentID {
            body.builder.controls.append(Control(
                rect: CGRect(x: contentX, y: headerTop, width: x - contentX + headerLine.width, height: headerHeight),
                title: "Show \(message.senderName)", style: .region(hoverFill: nil, pressedFill: nil, radius: 0),
                action: .perform(.revealMessageSender(blockID: block.id, agentID: senderID))))
        }
        return body
    }

    // MARK: Completed reasoning (CompletedReasoningDisclosureView)

    func reasoningBody(_ entry: AgentEntry, duration: TimeInterval?, width: CGFloat) -> Body {
        guard let presentation = CompletedReasoningDisclosurePresenter.presentation(
            for: entry, authoritativeDuration: duration, actions: renderContext.actions) else { return Body() }
        let header = S(Space.xl + Space.xs)
        let inset = S(Space.l)
        let buttonSide = S(Space.xxl)
        var body = Body()
        body.builder.controls.append(Control(
            rect: CGRect(x: inset, y: (header - buttonSide) / 2, width: buttonSide, height: buttonSide),
            title: presentation.isExpanded ? "Collapse reasoning" : "Expand reasoning",
            style: .chevron(expanded: presentation.isExpanded),
            action: .toggle(entry.id, expanded: !presentation.isExpanded)))
        let iconX = inset + buttonSide + S(Space.s)
        if let icon = Self.symbol("bubble.left", pointSize: S(13), color: secondary) {
            body.builder.decorations.append(.symbol(icon, CGRect(x: iconX + (buttonSide - icon.size.width) / 2,
                                                                 y: (header - icon.size.height) / 2,
                                                                 width: icon.size.width, height: icon.size.height)))
        }
        let label = NSFont.token(.label, zoom: zoom)
        let titleX = iconX + buttonSide + S(Space.m)
        let title = NSAttributedString(string: presentation.title, attributes: [.font: label, .foregroundColor: secondary])
        body.builder.rows.append(TextRow(string: title, lines: [Self.singleLine(
            title, x: titleX, top: 0, height: header, maxWidth: max(1, width - titleX - inset), font: label)], links: []))
        var y = header
        if presentation.isExpanded {
            y += S(Space.m)
            let x = ToolCallView.detailIndent(zoom: zoom)
            let childWidth = max(1, width - x - inset)
            for (index, block) in presentation.bodyBlocks.enumerated() {
                if index > 0 { y += S(Space.m) }
                let child = laidChild(block, role: .assistant, width: childWidth)
                body.builder.embed(child, dx: x, dy: y)
                y += child.height
            }
            y += S(Space.m)
        }
        body.height = ceil(y)
        return body
    }

    // MARK: Fallback

    /// Anything without a drawn form: its copy text, secondary, so nothing a
    /// provider sent ever disappears.
    func plainBody(_ block: AgentBlock, width: CGFloat) -> Body {
        let font = NSFont.token(.body, zoom: zoom)
        let text = AgentTranscriptCopyController.plainText(for: [block])
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: secondary])
        let set = Self.typeset(string, width: width, originX: 0, top: 0, firstIndent: 0, headIndent: 0,
                               linePitch: AssistantProseView.bodyLinePitch(zoom: zoom), fallbackFont: font)
        var body = Body(height: ceil(set.height))
        body.builder.rows.append(TextRow(string: string, lines: set.lines, links: []))
        return body
    }

    // MARK: CoreText helpers

    /// CoreText reads its own colour key; AppKit's `.foregroundColor` is copied
    /// across as a CGColor so CTLineDraw paints the token colour.
    static func coreTextString(_ string: NSAttributedString) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: string)
        string.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: string.length)) { value, range, _ in
            guard let color = value as? NSColor else { return }
            copy.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String), value: color.cgColor, range: range)
        }
        return copy
    }

    static func line(_ text: String, font: NSFont, color: NSColor) -> CTLine {
        CTLineCreateWithAttributedString(coreTextString(NSAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: color])))
    }

    static func width(of line: CTLine) -> CGFloat { CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) }

    static func centredBaseline(font: NSFont, top: CGFloat, height: CGFloat) -> CGFloat {
        top + ((height - (font.ascender - font.descender)) / 2).rounded() + font.ascender
    }

    /// A one-line row, truncated with an ellipsis to `maxWidth`.
    static func singleLine(_ string: NSAttributedString, x: CGFloat, top: CGFloat, height: CGFloat,
                           maxWidth: CGFloat, font: NSFont, truncation: CTLineTruncationType = .end) -> Line {
        let ct = coreTextString(string)
        var line = CTLineCreateWithAttributedString(ct)
        if string.length > 0, width(of: line) > maxWidth {
            let token = CTLineCreateWithAttributedString(NSAttributedString(
                string: "\u{2026}", attributes: ct.attributes(at: 0, effectiveRange: nil)))
            line = CTLineCreateTruncatedLine(line, Double(maxWidth), truncation, token) ?? line
        }
        return Line(ctLine: line, range: NSRange(location: 0, length: string.length), x: x, top: top,
                    height: height, baseline: centredBaseline(font: font, top: top, height: height),
                    width: width(of: line), fills: [], underlines: [])
    }

    /// Wraps `string` into lines with the given indents and pitch. Inline code
    /// fills and link underlines are resolved here, once, so draw only strokes.
    static func typeset(
        _ string: NSAttributedString, width: CGFloat, originX: CGFloat, top: CGFloat,
        firstIndent: CGFloat, headIndent: CGFloat, linePitch: CGFloat, fallbackFont: NSFont
    ) -> (lines: [Line], height: CGFloat) {
        let naturalFallback = ceil(fallbackFont.ascender - fallbackFont.descender + fallbackFont.leading)
        guard string.length > 0 else { return ([], max(naturalFallback, linePitch)) }
        let ct = coreTextString(string)
        let typesetter = CTTypesetterCreateWithAttributedString(ct)
        var lines: [Line] = []
        var start = 0
        var y = top
        while start < string.length {
            let indent = lines.isEmpty ? firstIndent : headIndent
            var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(max(1, width - indent)))
            if count <= 0 { count = 1 }
            let ctLine = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let lineWidth = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))
            let natural = ceil(ascent + descent + leading)
            let height = linePitch > 0 ? max(linePitch, ceil(ascent + descent)) : natural
            let baseline = y + ((height - (ascent + descent)) / 2).rounded() + ascent
            let x = originX + indent
            var fills: [(CGRect, CGColor)] = []
            var underlines: [(CGRect, CGColor)] = []
            for run in (CTLineGetGlyphRuns(ctLine) as? [CTRun]) ?? [] {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                let range = CTRunGetStringRange(run)
                let x1 = CTLineGetOffsetForStringIndex(ctLine, range.location, nil)
                let x2 = CTLineGetOffsetForStringIndex(ctLine, range.location + range.length, nil)
                guard x2 > x1 else { continue }
                if let background = attributes[NSAttributedString.Key.backgroundColor] as? NSColor {
                    fills.append((CGRect(x: x + x1 - 2, y: baseline - ascent - 1, width: x2 - x1 + 4,
                                         height: ascent + descent + 2), background.cgColor))
                }
                if let underline = attributes[NSAttributedString.Key.underlineStyle] as? Int, underline != 0 {
                    let color = (attributes[NSAttributedString.Key.foregroundColor] as? NSColor)?.cgColor
                        ?? NSColor.labelColor.cgColor
                    underlines.append((CGRect(x: x + x1, y: baseline + 1.5, width: x2 - x1, height: 1), color))
                }
            }
            lines.append(Line(ctLine: ctLine, range: NSRange(location: start, length: count), x: x, top: y,
                              height: height, baseline: baseline, width: lineWidth, fills: fills, underlines: underlines))
            y += height
            start += count
        }
        return (lines, max(y - top, naturalFallback))
    }

    /// A vector SF Symbol in one colour. Drawn per frame, so it stays sharp at any
    /// zoom (`CanvasSymbolImage` rasterizes, which a canvas zoom would scale).
    private static var symbolCache: [String: NSImage] = [:]
    static func symbol(_ name: String, pointSize: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) -> NSImage? {
        let key = "\(name)|\(pointSize)|\(weight.rawValue)|\(color.cgColor.components ?? [])"
        if let cached = symbolCache[key] { return cached }
        let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: ToolCallView.fallbackSymbolName, accessibilityDescription: nil)
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = base?.withSymbolConfiguration(configuration) else { return nil }
        symbolCache[key] = image
        return image
    }
}
