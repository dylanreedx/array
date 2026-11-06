// Offline CHECK fixture only; these hooks expose actual editor/application state.
import React from 'react';
import {createRoot} from 'react-dom/client';
import {flushSync} from 'react-dom';
import {EditorView, keymap} from '@codemirror/view';
import {EditorState} from '@codemirror/state';
import {defaultKeymap, history, historyKeymap} from '@codemirror/commands';
import {EditorView as PMView} from 'prosemirror-view';
import {EditorState as PMState} from 'prosemirror-state';
import {schema} from 'prosemirror-schema-basic';
import {exampleSetup} from 'prosemirror-example-setup';
const host=document.getElementById('root'), kind=document.body.dataset.kind;
window.events=[];
for(const name of ['input','beforeinput','keydown','focus','blur']) document.addEventListener(name,e=>events.push({type:name,trusted:e.isTrusted,data:e.data}),true);
if(kind==='react') {
 function App(){const [value,setValue]=React.useState('seed');const [revision,setRevision]=React.useState(0);window.readState=()=>({value,revision});window.refreshEditor=()=>flushSync(()=>setRevision(x=>x+1));return <input aria-label="Field" value={value} onChange={e=>setValue(e.target.value)}/>}
 createRoot(host).render(<App/>);
}
if(kind==='cm') {
 const view=new EditorView({state:EditorState.create({doc:'seed',extensions:[history(),keymap.of([...defaultKeymap,...historyKeymap])]}),parent:host});
 view.contentDOM.setAttribute('aria-label','Field');
 window.readState=()=>({value:view.state.doc.toString(),selection:view.state.selection.toJSON()});
 window.refreshEditor=()=>view.dispatch({effects:[]});
}
if(kind==='pm') {
 const view=new PMView(host,{state:PMState.create({schema,doc:schema.node('doc',null,[schema.node('paragraph',null,schema.text('seed'))]),plugins:exampleSetup({schema,menuBar:false})})});
 view.dom.setAttribute('role','textbox');view.dom.setAttribute('aria-label','Field');
 window.readState=()=>({value:view.state.doc.textBetween(0,view.state.doc.content.size,'\n'),doc:view.state.doc.toJSON(),selection:view.state.selection.toJSON()});
 window.refreshEditor=()=>view.updateState(view.state);
}
