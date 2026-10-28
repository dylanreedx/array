import re,sys,collections
lines=open(sys.argv[1]).read().splitlines()
WAIT=('mach_msg2_trap','__psynch_cvwait','__workq_kernreturn','semaphore_wait_trap','__wait4','kevent64','poll','__ulock_wait','kevent_id')
start=next(i for i,l in enumerate(lines) if 'Main Thread' in l and re.match(r'^ {4}\d+ Thread_',l))
nodes=[]
for l in lines[start+1:]:
    if re.match(r'^ {4}\d+ Thread_',l) or l.strip()=='': break
    m=re.match(r'^(\s*[+!:| ]*?)(\d+) (.*)$',l)
    if m: nodes.append((len(m.group(1)),int(m.group(2)),re.sub(r'\s+\(in ([^)]*)\).*',r' [\1]',m.group(3))))
cat=collections.Counter(); detail=collections.defaultdict(collections.Counter); stack=[]
def category(names):
    j=' '.join(names)
    if 'CanvasCameraDriver' in j or 'setViewport' in j: c='camera step (incl. AppKit under it)'
    elif 'prepareForReuse' in j: c='transcript cell reuse'
    elif 'installCanvasGestureMonitors' in j: c='scroll/pinch routing monitor'
    elif 'rightMouseDown' in j: c='context menu'
    elif '_layoutSubtreeWithOldSize' in j or 'layoutIfNeeded' in j: c='AppKit layout pass'
    elif 'display_if_needed' in j or 'NSViewBackingLayer display' in j: c='CA display (drawing layers)'
    elif 'CA::Transaction' in j: c='CA commit other'
    elif 'startResidencyEvaluation' in j: c='residency 10 Hz pass'
    elif 'scheduleCompanionSyncPublish' in j: c='companion sync'
    elif 'performAnimations' in j: c='NSAnimation'
    else: c='other'
    return c
for i,(d,n,name) in enumerate(nodes):
    while stack and stack[-1][0]>=d: stack.pop()
    stack.append((d,name))
    kids=0;k=i+1;md=None
    while k<len(nodes) and nodes[k][0]>d:
        if md is None: md=nodes[k][0]
        if nodes[k][0]==md: kids+=nodes[k][1]
        k+=1
    s=n-kids
    if s<=0 or any(w in name for w in WAIT): continue
    names=[nm for _,nm in stack]
    c=category(names)
    cat[c]+=s
    arr=[nm for nm in names if '[Array]' in nm and 'main' not in nm and not nm.startswith(('thunk','partial apply','@objc'))]
    key=(arr[-1] if arr else '(no Array frame) '+ next((nm for nm in reversed(names) if '[AppKit]' in nm and '???' not in nm), name))[:100]
    detail[c][key]+=s
tot=sum(cat.values()); print('busy',tot)
for c,v in cat.most_common():
    print(f'\n{v:6d} {100*v/tot:5.1f}%  {c}')
    for k,x in detail[c].most_common(6): print(f'        {x:6d}  {k}')
