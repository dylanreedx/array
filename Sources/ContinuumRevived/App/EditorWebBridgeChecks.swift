import AppKit
import Foundation
@preconcurrency import WebKit

/// Runs the packaged CodeMirror code in WebKit, including its real history and
/// input handlers. No test substitute for the web editor is installed.
@MainActor
enum EditorWebBridgeChecks {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func run() throws {
        _ = NSApplication.shared
        let host = CodeEditorHostView(frame: NSRect(x: 0, y: 0, width: 720, height: 480))
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        var loaded: Result<UInt64, CodeEditorHostError>?
        host.loadDocument(documentID: "fixture.swift#generation-a", text: "let value = 1\n", language: "swift", revision: 0) { loaded = $0 }
        try wait("editor load") { loaded != nil }
        _ = try loaded!.get()

        let result = try evaluate(host.webView, """
        const id = 'fixture.swift#generation-a';
        const editor = window.arrayEditor;
        function expect(value, message) { if (!value) throw new Error(message); }
        function snapshot() { return editor.snapshot({documentId:id}); }
        async function insert(text) {
          editor.runCommand({documentId:id,command:'focus'});
          const inserted = document.execCommand('insertText', false, text);
          // execCommand first mutates WebKit's DOM; CodeMirror ingests that
          // mutation through its observer before updating the editor state.
          await new Promise(resolve => setTimeout(resolve, 50));
          return inserted;
        }
        editor.runCommand({documentId:id,command:'reveal',line:1,column:1});
        expect(await insert('😀 café '), 'WebKit insertText must reach the actual editor');
        const edited = snapshot();
        expect(edited.text === '😀 café let value = 1\\n', 'UTF-16 input was not preserved: ' + JSON.stringify(edited.text));
        expect(edited.revision > 0, 'User edit must advance the web revision');
        editor.setPreferences({appearance:'dark',fontSize:18,lineHeight:1.8,wordWrap:true,lineNumbers:false});
        editor.setPreferences({vimEnabled:true});
        editor.setPreferences({appearance:'light',vimEnabled:false});
        expect(snapshot().text === edited.text, 'Preferences changed document text');
        expect(JSON.stringify(snapshot().selection) === JSON.stringify(edited.selection), 'Preferences changed the selection');
        expect(editor.runCommand({documentId:id,command:'undo'}).handled, 'Preference changes destroyed undo history');
        expect(snapshot().text === 'let value = 1\\n', 'Undo must restore the original document');
        expect(editor.runCommand({documentId:id,command:'redo'}).handled, 'Redo history missing');
        expect(snapshot().text === edited.text, 'Redo did not restore Unicode input');
        editor.setPreferences({vimEnabled:true});
        editor.snapshot({documentId:id,freeze:true});
        const frozen = snapshot().text;
        await insert('MUST NOT APPEAR');
        expect(snapshot().text === frozen, 'Frozen editor accepted native text insertion with Vim enabled');
        editor.runCommand({documentId:id,command:'resumeEditing'});
        editor.setPreferences({vimEnabled:false});
        expect(await insert('resumed '), 'Resumed editor rejected text insertion');
        expect(snapshot().text.includes('resumed '), 'Resume did not restore editing');
        const replacement = 'replacement.py#generation-b';
        editor.loadDocument({documentId:replacement,text:'print("new")',language:'python',revision:0});
        let staleRejected = false;
        try { editor.applyEdits({documentId:id,expectedRevision:0,revision:1,changes:[{from:0,to:0,insert:'stale'}]}); }
        catch (_) { staleRejected = true; }
        expect(staleRejected, 'Old document generation was accepted');
        expect(editor.snapshot({documentId:replacement}).text === 'print("new")', 'Stale edits damaged replacement');
        expect(!editor.runCommand({documentId:replacement,command:'undo'}).handled, 'Replacement inherited old history');
        return {passed:true, unicode:true, history:true, preferences:true, frozen:true, staleGeneration:true};
        """)
        guard let dictionary = result as? [String: Any], dictionary["passed"] as? Bool == true else {
            throw Failure(description: "Editor bridge returned an unexpected result: \(result)")
        }
        print("PASS editor-web-bridge: real WebKit Unicode input, preference/Vim reconfiguration, undo/redo, freeze/resume, document generation")
    }

    private static func evaluate(_ webView: WKWebView, _ body: String) throws -> Any {
        var reply: Result<Any, Error>?
        webView.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { reply = $0 }
        try wait("WebKit bridge assertions") { reply != nil }
        return try reply!.get()
    }

    private static func wait(_ operation: String, until complete: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(15)
        while !complete(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        if !complete() { throw Failure(description: "Timed out waiting for \(operation)") }
    }
}
