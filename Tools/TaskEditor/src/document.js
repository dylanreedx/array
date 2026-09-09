import {Node} from '@tiptap/core';
import StarterKit from '@tiptap/starter-kit';
import Image from '@tiptap/extension-image';
import TaskList from '@tiptap/extension-task-list';
import TaskItem from '@tiptap/extension-task-item';
import {Markdown} from '@tiptap/markdown';

// Existing blocks outside our authoring palette remain lossless, visible source.
const preserved = (name, token) => Node.create({
  name, group:'block', atom:true,
  addAttributes:()=>({source:{default:''}}),
  markdownTokenName:token,
  parseMarkdown: t => ({type:name, attrs:{source:t.raw}}),
  renderMarkdown: node => node.attrs.source,
  parseHTML:()=>[{tag:`pre[data-preserved="${name}"]`}],
  renderHTML:({node})=>['pre',{'data-preserved':name,class:'preserved-source'},node.attrs.source],
});
export function extensions() {
  return [StarterKit.configure({heading:{levels:[1,2,3]},link:{openOnClick:false}}),
    TaskList, TaskItem.configure({nested:true}), Image.configure({inline:true,allowBase64:false}),
    preserved('preservedHTML','html'),preserved('preservedTable','table'),Markdown];
}
