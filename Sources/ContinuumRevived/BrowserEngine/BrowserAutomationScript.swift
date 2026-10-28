// The page half of `BrowserAutomation` (`.plans/80-browser-computer-use`,
// S2). It runs in the isolated content world `array.automation`, so the page
// can neither see it nor change what it sees: the world has its own globals
// and its own DOM prototypes, so a page that patches `getBoundingClientRect`
// or `querySelectorAll` patches them only for itself.
//
// Each call sends this source ahead of the operation; it defines its state
// once per document and is a no-op after that, so tiles no agent drives pay
// nothing.
//
// Tags (`e5`) belong to the element, not to a snapshot: an element keeps its
// tag for as long as it stays in the document, and a tag whose element is
// gone resolves to `stale`. They live in this world's own maps; nothing is
// written into the DOM.
enum BrowserAutomationScript {
    static let bootstrap = #"""
    if (!globalThis.__arrayAutomation) {
      const state = { next: 1, byRef: new Map(), refOf: new WeakMap(), lastMutation: Date.now(), observer: null };
      const LEAF_ROLES = new Set(['button', 'link', 'heading', 'option', 'checkbox', 'radio', 'tab', 'menuitem',
        'img', 'textbox', 'searchbox', 'combobox', 'slider', 'spinbutton', 'switch', 'clickable']);
      const CONTAINER_ROLES = new Set(['list', 'listitem', 'navigation', 'main', 'form', 'dialog', 'alertdialog',
        'table', 'row', 'cell', 'columnheader', 'group', 'menu', 'menubar', 'tablist', 'tabpanel', 'listbox',
        'banner', 'contentinfo', 'region', 'alert', 'status', 'tree', 'treeitem', 'grid', 'gridcell', 'toolbar']);
      const MAX_ELEMENTS = 6000;

      function observe() {
        if (state.observer || !document.documentElement) return;
        state.observer = new MutationObserver(() => { state.lastMutation = Date.now(); });
        state.observer.observe(document.documentElement, { subtree: true, childList: true, attributes: true, characterData: true });
      }
      function collapse(text, max) {
        const s = (text || '').replace(/\s+/g, ' ').trim();
        return s.length > max ? s.slice(0, max - 1) + '…' : s;
      }
      function isPassword(el) { return el.tagName === 'INPUT' && (el.type || '').toLowerCase() === 'password'; }
      function implicitRole(el) {
        const tag = el.tagName.toLowerCase();
        const type = (el.getAttribute('type') || '').toLowerCase();
        switch (tag) {
          case 'a': return el.hasAttribute('href') ? 'link' : null;
          case 'button': case 'summary': return 'button';
          case 'input':
            if (type === 'hidden') return null;
            if (['button', 'submit', 'reset', 'image'].includes(type)) return 'button';
            if (type === 'checkbox') return 'checkbox';
            if (type === 'radio') return 'radio';
            if (type === 'range') return 'slider';
            if (type === 'number') return 'spinbutton';
            if (type === 'search') return 'searchbox';
            return 'textbox';
          case 'textarea': return 'textbox';
          case 'select': return (el.multiple || el.size > 1) ? 'listbox' : 'combobox';
          case 'option': return 'option';
          case 'img': return el.getAttribute('alt') ? 'img' : null;
          case 'h1': case 'h2': case 'h3': case 'h4': case 'h5': case 'h6': return 'heading';
          case 'ul': case 'ol': return 'list';
          case 'li': return 'listitem';
          case 'nav': return 'navigation';
          case 'main': return 'main';
          case 'form': return 'form';
          case 'dialog': return 'dialog';
          case 'table': return 'table';
          case 'tr': return 'row';
          case 'td': return 'cell';
          case 'th': return 'columnheader';
          case 'details': return 'group';
          case 'iframe': return 'iframe';
        }
        if (el.isContentEditable && (el.parentElement === null || !el.parentElement.isContentEditable)) return 'textbox';
        return null;
      }
      function roleOf(el, style) {
        const explicit = (el.getAttribute('role') || '').trim().split(/\s+/)[0];
        if (explicit && explicit !== 'presentation' && explicit !== 'none' && explicit !== 'generic') return explicit;
        const implicit = implicitRole(el);
        if (implicit) return implicit;
        if (style.cursor === 'pointer' && !(el.parentElement && getComputedStyle(el.parentElement).cursor === 'pointer')) return 'clickable';
        if (el.hasAttribute('onclick') || (el.hasAttribute('tabindex') && el.tabIndex >= 0)) return 'clickable';
        return null;
      }
      function nameOf(el, role) {
        const doc = el.ownerDocument;
        const labelledBy = el.getAttribute('aria-labelledby');
        if (labelledBy) {
          const text = labelledBy.split(/\s+/).map(id => doc.getElementById(id)).filter(Boolean).map(n => n.innerText || n.textContent).join(' ');
          if (collapse(text, 80)) return collapse(text, 80);
        }
        const aria = el.getAttribute('aria-label');
        if (aria && aria.trim()) return collapse(aria, 80);
        const tag = el.tagName;
        if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') {
          if (el.labels && el.labels.length) return collapse(el.labels[0].innerText, 80);
          if (['button', 'submit', 'reset'].includes((el.type || '').toLowerCase())) return collapse(el.value, 80);
          const placeholder = el.getAttribute('placeholder');
          if (placeholder) return collapse(placeholder, 80);
          return collapse(el.getAttribute('title') || el.getAttribute('name') || '', 80);
        }
        if (tag === 'IMG') return collapse(el.getAttribute('alt'), 80);
        if (tag === 'IFRAME') return collapse(el.getAttribute('title') || el.getAttribute('src') || '', 80);
        if (LEAF_ROLES.has(role) || role === 'listitem' || role === 'cell' || role === 'columnheader' || role === 'option')
          return collapse(el.innerText || el.textContent, 80);
        return collapse(el.getAttribute('title') || '', 80);
      }
      function refFor(el) {
        let ref = state.refOf.get(el);
        if (!ref) {
          ref = 'e' + state.next++;
          state.refOf.set(el, ref);
          state.byRef.set(ref, new WeakRef(el));
        }
        return ref;
      }
      function deepActive(doc) {
        let active = doc.activeElement;
        while (active && active.shadowRoot && active.shadowRoot.activeElement) active = active.shadowRoot.activeElement;
        if (active && active.tagName === 'IFRAME') {
          try { if (active.contentDocument) return deepActive(active.contentDocument); } catch (_) {}
        }
        return active;
      }
      function valueOf(el) {
        if (isPassword(el)) return el.value ? '••••••' : '';
        if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') return el.value;
        if (el.tagName === 'SELECT') return Array.from(el.selectedOptions).map(o => o.label).join(', ');
        if (el.isContentEditable) return collapse(el.innerText, 200);
        return null;
      }
      function describe(el) {
        if (!el) return 'nothing';
        let style;
        try { style = getComputedStyle(el); } catch (_) { style = {}; }
        const role = roleOf(el, style) || el.tagName.toLowerCase();
        const name = nameOf(el, role);
        const ref = state.refOf.get(el);
        return role + (name ? ' "' + name + '"' : '') + (ref ? ' [ref=' + ref + ']' : '');
      }
      function line(el, role, depth, lines, active) {
        const name = nameOf(el, role);
        let s = role + (name ? ' "' + name.replace(/"/g, '\\"') + '"' : '') + ' [ref=' + refFor(el) + ']';
        if (role === 'heading') s += ' [level=' + (el.getAttribute('aria-level') || el.tagName.slice(1)) + ']';
        if (el.disabled || el.getAttribute('aria-disabled') === 'true') s += ' [disabled]';
        if (el.checked === true || el.getAttribute('aria-checked') === 'true') s += ' [checked]';
        const expanded = el.getAttribute('aria-expanded') ?? (el.tagName === 'DETAILS' ? String(el.open) : null);
        if (expanded !== null) s += ' [expanded=' + expanded + ']';
        if (el.selected === true || el.getAttribute('aria-selected') === 'true') s += ' [selected]';
        if (el === active) s += ' [focused]';
        if (el.tagName === 'A' && el.getAttribute('href')) s += ' [url=' + collapse(el.getAttribute('href'), 120) + ']';
        const value = valueOf(el);
        if (value !== null && value !== '' && role !== 'button') s += ' value="' + collapse(value, 200).replace(/"/g, '\\"') + '"';
        lines.push({ d: depth, k: 'e', s: s });
      }
      function walk(node, depth, lines, counter, active) {
        for (let child = node.firstChild; child; child = child.nextSibling) {
          if (counter.n >= MAX_ELEMENTS) { counter.cut = true; return; }
          if (child.nodeType === Node.TEXT_NODE) {
            const text = collapse(child.textContent, 300);
            if (!text) continue;
            // Runs of text at one depth read as one line, up to a point:
            // `<p>Hello <b>world</b></p>` is "text: Hello world".
            const last = lines[lines.length - 1];
            if (last && last.k === 't' && last.d === depth && last.s.length + text.length < 500) last.s += ' ' + text;
            else lines.push({ d: depth, k: 't', s: 'text: ' + text });
            continue;
          }
          if (child.nodeType !== Node.ELEMENT_NODE) continue;
          const el = child;
          const tag = el.tagName;
          if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NOSCRIPT' || tag === 'TEMPLATE' || tag === 'HEAD') continue;
          if (el.getAttribute('aria-hidden') === 'true' || el.hidden) continue;
          counter.n++;
          const style = getComputedStyle(el);
          if (style.display === 'none') continue;
          const visible = style.visibility !== 'hidden' && style.visibility !== 'collapse';
          const role = visible ? roleOf(el, style) : null;
          if (role && role !== 'iframe') {
            const rect = el.getBoundingClientRect();
            const sized = rect.width > 0 || rect.height > 0 || style.display === 'contents';
            if (sized) {
              line(el, role, depth, lines, active);
              if (!LEAF_ROLES.has(role)) walkChildren(el, depth + 1, lines, counter, active);
              continue;
            }
          }
          if (role === 'iframe') {
            let inner = null;
            try { inner = el.contentDocument; } catch (_) {}
            const name = nameOf(el, role);
            lines.push({ d: depth, k: 'e', s: 'iframe' + (name ? ' "' + name + '"' : '') + (inner ? '' : ' [not reachable: another origin]') });
            if (inner && inner.body) walk(inner.body, depth + 1, lines, counter, active);
            continue;
          }
          walkChildren(el, depth, lines, counter, active);
        }
      }
      function walkChildren(el, depth, lines, counter, active) {
        if (el.shadowRoot) walk(el.shadowRoot, depth, lines, counter, active);
        walk(el, depth, lines, counter, active);
      }
      function frameOffset(el) {
        let x = 0, y = 0;
        let win = el.ownerDocument.defaultView;
        while (win && win !== window) {
          const frame = win.frameElement;
          if (!frame) break;
          const r = frame.getBoundingClientRect();
          x += r.left + frame.clientLeft;
          y += r.top + frame.clientTop;
          win = win.parent;
        }
        return { x, y };
      }
      function element(ref) {
        const weak = state.byRef.get(ref);
        const el = weak && weak.deref();
        return el && el.isConnected ? el : null;
      }

      globalThis.__arrayAutomation = {
        outline() {
          observe();
          for (const [ref, weak] of state.byRef) { const el = weak.deref(); if (!el || !el.isConnected) state.byRef.delete(ref); }
          const lines = [];
          const counter = { n: 0, cut: false };
          if (document.body) walk(document.body, 0, lines, counter, deepActive(document));
          return { lines, cut: counter.cut, url: location.href, title: document.title };
        },
        // Scrolls the element into view and returns its centre in top-level
        // CSS px, and whether a click there would land on it.
        target(a) {
          observe();
          const el = element(a.ref);
          if (!el) return { stale: true };
          el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
          const rect = el.getBoundingClientRect();
          if (rect.width <= 0 || rect.height <= 0) return { invisible: true, what: describe(el) };
          const view = el.ownerDocument.defaultView;
          const cx = Math.min(Math.max(rect.left + rect.width / 2, 0), view.innerWidth - 1);
          const cy = Math.min(Math.max(rect.top + rect.height / 2, 0), view.innerHeight - 1);
          const hit = el.ownerDocument.elementFromPoint(cx, cy);
          let lands = !!hit && (hit === el || el.contains(hit) || (hit.tagName === 'LABEL' && hit.control === el));
          if (!lands && hit && el.getRootNode() instanceof ShadowRoot) lands = hit.contains(el);
          const offset = frameOffset(el);
          return {
            x: cx + offset.x, y: cy + offset.y,
            rect: { x: rect.left + offset.x, y: rect.top + offset.y, w: rect.width, h: rect.height },
            lands, cover: lands ? null : describe(hit), what: describe(el),
            editable: el.tagName === 'TEXTAREA' || el.isContentEditable ||
              (el.tagName === 'INPUT' && !['button', 'submit', 'reset', 'image', 'checkbox', 'radio', 'range', 'file', 'color', 'hidden'].includes((el.type || '').toLowerCase())),
          };
        },
        at(a) {
          const hit = document.elementFromPoint(a.x, a.y);
          return { what: describe(hit) };
        },
        focusedIs(a) {
          const el = element(a.ref);
          const active = deepActive(document);
          return { focused: !!el && !!active && (active === el || el.contains(active)), value: el ? valueOf(el) : null };
        },
        select(a) {
          const el = element(a.ref);
          if (!el) return { stale: true };
          if (typeof el.select === 'function') el.select();
          else { const sel = el.ownerDocument.getSelection(); sel.selectAllChildren(el); }
          return { ok: true };
        },
        scroll(a) {
          if (a.ref) {
            const el = element(a.ref);
            if (!el) return { stale: true };
            el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
            return { what: describe(el), scrollX, scrollY };
          }
          window.scrollBy({ left: a.dx || 0, top: a.dy || 0, behavior: 'instant' });
          return { scrollX, scrollY, maxY: document.documentElement.scrollHeight - innerHeight };
        },
        // One poll of a wait condition. `quietMs` since the last DOM change
        // and a complete document count as idle.
        probe(a) {
          observe();
          const text = a.text ? (document.body ? document.body.innerText : '').includes(a.text) : null;
          const ref = a.ref ? !!element(a.ref) && element(a.ref).getClientRects().length > 0 : null;
          return { text, ref, quietMs: Date.now() - state.lastMutation, ready: document.readyState === 'complete' };
        },
      };
    }
    """#

    /// The body handed to `callAsyncJavaScript`: define the world's state if
    /// this document has none yet, then run one operation. `op` and `a` arrive
    /// as arguments, never spliced into the source.
    static let call = bootstrap + "\nreturn globalThis.__arrayAutomation[op](a);"
}
