import WebKit

enum PerformanceOptimizer {
    static func install(into controller: WKUserContentController) {
        controller.addUserScript(
            WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
    }

    private static let source = #"""
    (() => {
      const host = String(location.hostname || '').toLowerCase();
      const trusted = host === 'chatgpt.com' || host.endsWith('.chatgpt.com') ||
        host === 'chat.openai.com' || host.endsWith('.chat.openai.com');
      if (!trusted || window.__chatgptStablePerf) return;

      const hiddenAttr = 'data-chatgpt-stable-hidden';
      const completeAttr = 'data-chatgpt-stable-complete';
      const originalDisplay = new WeakMap();
      const state = {
        path: location.pathname,
        keep: 20,
        hidden: 0,
        shells: 0,
        roles: 0,
        visibleRoles: 0,
        generating: false,
        generationReason: 'none',
        mode: 'native',
        domNodes: 0,
        externalPressure: 0,
        nearBottom: true,
        scanTimer: 0,
        scrollRoot: null
      };

      const isTurn = element => {
        if (!(element instanceof Element)) return false;
        const testID = element.getAttribute('data-testid') || '';
        return element.hasAttribute('data-turn-id') || testID.startsWith('conversation-turn-');
      };

      const isVisibleControl = element => {
        const rect = element.getBoundingClientRect();
        if (rect.width <= 0 || rect.height <= 0) return false;
        const style = getComputedStyle(element);
        return style.display !== 'none' && style.visibility !== 'hidden';
      };

      const nearestTurn = element => {
        for (let node = element; node && node !== document.body; node = node.parentElement) {
          if (isTurn(node)) return node;
        }
        return null;
      };

      const findScrollRoot = element => {
        for (let node = element?.parentElement; node && node !== document.body; node = node.parentElement) {
          const style = getComputedStyle(node);
          if (/(auto|scroll)/.test(style.overflowY) && node.scrollHeight > node.clientHeight + 80) return node;
        }
        return document.scrollingElement || document.documentElement;
      };

      const reveal = target => {
        if (!(target instanceof Element) || target.getAttribute(hiddenAttr) !== '1') return;
        const saved = originalDisplay.get(target);
        if (saved) target.style.setProperty('display', saved.cssValue, saved.priority);
        else target.style.removeProperty('display');
        target.removeAttribute(hiddenAttr);
      };

      const hide = target => {
        if (!(target instanceof Element) || target.getAttribute(hiddenAttr) === '1') return;
        originalDisplay.set(target, {cssValue: target.style.getPropertyValue('display'), priority: target.style.getPropertyPriority('display')});
        target.setAttribute(hiddenAttr, '1');
        target.style.setProperty('display', 'none', 'important');
      };

      const ensureStyle = () => {
        if (document.getElementById('chatgpt-stable-performance-style')) return;
        const style = document.createElement('style');
        style.id = 'chatgpt-stable-performance-style';
        style.appendChild(document.createTextNode(`
          html { scroll-behavior: auto !important; }
          [${completeAttr}="1"] *, [${hiddenAttr}="1"] * {
            animation-duration: 0.001ms !important;
            animation-delay: 0s !important;
            transition-duration: 0.001ms !important;
            transition-delay: 0s !important;
          }
        `));
        (document.head || document.documentElement).appendChild(style);
      };

      const ensureControl = () => {
        let button = document.getElementById('chatgpt-stable-history-control');
        if (button) return button;
        button = document.createElement('button');
        button.id = 'chatgpt-stable-history-control';
        button.type = 'button';
        button.style.cssText = 'position:fixed;top:72px;left:50%;transform:translateX(-50%);z-index:2147483000;padding:6px 12px;border-radius:999px;border:1px solid rgba(128,128,128,.35);background:Canvas;color:CanvasText;font:12px -apple-system,BlinkMacSystemFont,sans-serif;box-shadow:0 2px 10px rgba(0,0,0,.12);display:none;cursor:pointer';
        button.addEventListener('click', () => revealBatch(12));
        document.documentElement.appendChild(button);
        return button;
      };

      const updateControl = () => {
        const button = ensureControl();
        if (!state.hidden) { button.style.display = 'none'; return; }
        button.replaceChildren(document.createTextNode(`Show earlier messages (${state.hidden})`));
        button.style.display = 'block';
      };

      const revealBatch = count => {
        const all = document.getElementsByTagName('*');
        const hidden = [];
        for (let i = 0; i < all.length; i++) {
          if (all[i].getAttribute(hiddenAttr) === '1') hidden.push(all[i]);
        }
        if (!hidden.length) return;
        const root = state.scrollRoot || document.scrollingElement || document.documentElement;
        const before = root.scrollHeight;
        const start = Math.max(0, hidden.length - count);
        for (let i = start; i < hidden.length; i++) reveal(hidden[i]);
        state.keep += hidden.length - start;
        requestAnimationFrame(() => {
          root.scrollTop += Math.max(0, root.scrollHeight - before);
          scheduleScan(100);
        });
      };

      const attachScrollRoot = root => {
        if (!root || state.scrollRoot === root) return;
        if (state.scrollRoot) state.scrollRoot.removeEventListener('scroll', onScroll);
        state.scrollRoot = root;
        root.addEventListener('scroll', onScroll, {passive:true});
      };

      let scrollTimer = 0;
      const onScroll = () => {
        if (scrollTimer || !state.hidden) return;
        scrollTimer = window.setTimeout(() => {
          scrollTimer = 0;
          const root = state.scrollRoot;
          if (root && root.scrollTop < 240 && state.hidden) revealBatch(12);
        }, 120);
      };

      const resetRoute = () => {
        const all = document.getElementsByTagName('*');
        for (let i = 0; i < all.length; i++) if (all[i].getAttribute(hiddenAttr) === '1') reveal(all[i]);
        state.path = location.pathname;
        state.keep = 20;
        state.hidden = 0;
        state.mode = 'native';
      };

      const scan = () => {
        state.scanTimer = 0;
        if (!document.body) return;
        ensureStyle();
        if (location.pathname !== state.path) resetRoute();

        const all = document.getElementsByTagName('*');
        state.domNodes = all.length;
        const shellSet = new Set();
        const targets = [];
        const targetSet = new Set();
        let roles = 0;
        let generating = false;
        let generationReason = 'none';

        for (let i = 0; i < all.length; i++) {
          const element = all[i];
          const testID = element.getAttribute('data-testid') || '';
          const ariaLabel = element.getAttribute('aria-label') || '';
          if (isTurn(element)) shellSet.add(element);
          if (!generating) {
            const ariaBusy = element.getAttribute('aria-busy') === 'true';
            const stopControl = testID.toLowerCase().includes('stop') || ariaLabel.toLowerCase().includes('stop');
            if ((ariaBusy || stopControl) && isVisibleControl(element)) {
              generating = true;
              generationReason = stopControl ? 'stop-control' : 'aria-busy';
            }
          }
          if (!element.hasAttribute('data-message-author-role')) continue;
          roles++;
          const target = nearestTurn(element);
          if (target && !targetSet.has(target)) {
            targetSet.add(target);
            targets.push(target);
          }
        }

        state.shells = shellSet.size;
        state.roles = roles;
        state.generating = generating;
        state.generationReason = generationReason;
        state.visibleRoles = targets.filter(target => target.getAttribute(hiddenAttr) !== '1').length;
        targets.forEach((target, index) => {
          if (index < targets.length - 1) target.setAttribute(completeAttr, '1');
          else target.removeAttribute(completeAttr);
        });

        if (targets.length) {
          const root = findScrollRoot(targets[targets.length - 1]);
          attachScrollRoot(root);
          const distanceFromBottom = root.scrollHeight - root.scrollTop - root.clientHeight;
          const nearBottom = distanceFromBottom < Math.max(600, root.clientHeight * 1.5);
          state.nearBottom = nearBottom;
          const canHide = shellSet.size >= targets.length;

          const streamingPressure = generating && Math.max(state.domNodes, state.externalPressure) >= 9_000;
          if (streamingPressure && targets.length > 4 && nearBottom && canHide) {
            const cutoff = Math.max(0, targets.length - 4);
            for (let i = 0; i < targets.length; i++) {
              if (i < cutoff) hide(targets[i]);
              else reveal(targets[i]);
            }
            state.mode = 'streaming';
          } else if (targets.length > 32 && nearBottom && canHide) {
            const cutoff = Math.max(0, targets.length - state.keep);
            for (let i = 0; i < targets.length; i++) {
              if (i < cutoff) hide(targets[i]);
              else reveal(targets[i]);
            }
            state.mode = 'tail';
          } else if (targets.length <= 32) {
            targets.forEach(reveal);
            state.mode = 'native';
          }
        }

        state.hidden = 0;
        state.visibleRoles = 0;
        for (const target of targets) {
          if (target.getAttribute(hiddenAttr) === '1') state.hidden++;
          else state.visibleRoles++;
        }
        updateControl();
      };

      const scheduleScan = delay => {
        if (state.scanTimer) window.clearTimeout(state.scanTimer);
        state.scanTimer = window.setTimeout(scan, delay);
      };

      const relevant = node => {
        if (!(node instanceof Element)) return false;
        const testID = node.getAttribute('data-testid') || '';
        if (isTurn(node) || node.hasAttribute('data-message-author-role') || testID === 'stop-button') return true;
        const descendants = node.getElementsByTagName('*');
        for (let i = 0; i < descendants.length; i++) {
          const child = descendants[i];
          const childTestID = child.getAttribute('data-testid') || '';
          if (isTurn(child) || child.hasAttribute('data-message-author-role') || childTestID === 'stop-button') return true;
        }
        return false;
      };

      const observer = new MutationObserver(mutations => {
        if (document.hidden) return;
        for (const mutation of mutations) {
          for (const node of mutation.addedNodes) {
            if (relevant(node)) { scheduleScan(350); return; }
          }
          for (const node of mutation.removedNodes) {
            if (relevant(node)) { scheduleScan(350); return; }
          }
        }
      });
      observer.observe(document.documentElement, {childList:true, subtree:true});

      window.addEventListener('popstate', () => scheduleScan(100), {passive:true});
      document.addEventListener('visibilitychange', () => {
        if (!document.hidden) scheduleScan(150);
      }, {passive:true});

      window.__chatgptStablePerf = {
        snapshot() {
          return {
            mode: state.mode,
            shells: state.shells,
            roles: state.roles,
            visibleRoles: state.visibleRoles,
            hidden: state.hidden,
            generating: state.generating,
            generationReason: state.generationReason,
            domNodes: state.domNodes,
            nearBottom: state.nearBottom
          };
        },
        pressure(domNodes) {
          if (Number.isFinite(domNodes) && domNodes >= 0) state.externalPressure = domNodes;
          scheduleScan(0);
        },
        revealAll() {
          state.keep = Number.MAX_SAFE_INTEGER;
          scheduleScan(0);
        }
      };

      ensureStyle();
      scheduleScan(250);
    })();
    """#
}
