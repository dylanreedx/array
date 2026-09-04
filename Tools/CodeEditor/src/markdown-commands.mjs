import {EditorSelection, Transaction} from '@codemirror/state'
import {isolateHistory} from '@codemirror/commands'

const wrappers = {
  markdown1: ['**', '**', 'bold'],
  markdown2: ['*', '*', 'italic'],
  markdown3: ['[', '](url)', 'link text'],
  markdown7: ['`', '`', 'code'],
  markdown8: ['```\n', '\n```', 'code']
}
const prefixes = {markdown4: '# ', markdown5: '- ', markdown6: '> '}

export function applyMarkdownCommand(view, command) {
  if (view.state.readOnly) return false
  let change
  if (wrappers[command]) {
    const [prefix, suffix, placeholder] = wrappers[command]
    change = view.state.changeByRange(range => {
      const content = range.empty ? placeholder : view.state.sliceDoc(range.from, range.to)
      return {
        changes: {from: range.from, to: range.to, insert: prefix + content + suffix},
        range: EditorSelection.range(range.from + prefix.length, range.from + prefix.length + content.length)
      }
    })
  } else if (prefixes[command]) {
    const prefix = prefixes[command]
    const lines = new Map()
    for (const range of view.state.selection.ranges) {
      const first = view.state.doc.lineAt(range.from).number
      const finalPosition = range.to > range.from ? range.to - 1 : range.to
      const last = view.state.doc.lineAt(finalPosition).number
      for (let number = first; number <= last; number++) {
        const line = view.state.doc.line(number)
        lines.set(number, line.text.startsWith(prefix)
          ? {from: line.from, to: line.from + prefix.length, insert: ''}
          : {from: line.from, insert: prefix})
      }
    }
    change = {changes: [...lines.entries()].sort((a, b) => a[0] - b[0]).map(([, edit]) => edit)}
  } else return false
  view.dispatch({...change, annotations: [Transaction.userEvent.of('input.format'), isolateHistory.of('full')], scrollIntoView: true})
  view.focus()
  return true
}
