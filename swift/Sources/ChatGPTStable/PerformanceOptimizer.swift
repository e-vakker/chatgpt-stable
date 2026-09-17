import WebKit

enum PerformanceOptimizer {
    static let routeContentWorld = WKContentWorld.world(name: "ChatGPTStableWarmRoute")
    static let routeHandlerName = "warmConversationCache"

    static func install(into controller: WKUserContentController, terminalMode: Bool = false) {
        if terminalMode {
            controller.addUserScript(
                WKUserScript(source: TerminalInterface.source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
        }
        controller.addUserScript(
            WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        controller.addUserScript(
            WKUserScript(source: routeSource, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: routeContentWorld)
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
      const leanAttr = 'data-chatgpt-stable-lean';
      const activityAttr = 'data-chatgpt-stable-activity';
      const activityHiddenAttr = 'data-chatgpt-stable-activity-hidden';
      const composerAttr = 'data-chatgpt-stable-composer';
      const autoCollapsedAttr = 'data-chatgpt-stable-autocollapsed';
      const bloatHiddenAttr = 'data-chatgpt-stable-bloat-hidden';
      const terminalMode = document.documentElement?.getAttribute('data-chatgpt-stable-terminal') === '1';
      const originalDisplay = new WeakMap();
      const originalActivityDisplay = new WeakMap();
      let pinnedActivities = new WeakSet();
      const state = {
        path: location.pathname,
        keep: terminalMode ? 12 : 20,
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
        scanPending: false,
        scrollRoot: null,
        activityNodes: [],
        turnShellNodes: [],
        activityTotal: 0,
        reasoningCount: 0,
        toolCount: 0,
        detailCount: 0,
        errorCount: 0,
        artifactCount: 0,
        codeCount: 0,
        tableCount: 0,
        mediaCount: 0,
        scanMs: 0,
        hiddenActivities: 0,
        activityMode: 'all',
        activityExpanded: !terminalMode,
        showAllActivities: false,
        railKeep: terminalMode ? 20 : 40,
        needsInitialBottom: false
      };

      const isConversationPath = path => {
        const parts = String(path || '').split('/').filter(Boolean);
        const index = parts.indexOf('c');
        return index >= 0 && index + 1 < parts.length && !!parts[index + 1];
      };
      state.needsInitialBottom = isConversationPath(location.pathname);

      document.documentElement?.setAttribute(leanAttr, '1');

      const assistantSelector = '[data-message-author-role="assistant"],[data-role="assistant"],[data-message-author="assistant"]';
      const messageRoleSelector = '[data-message-author-role],[data-role],[data-message-author]';
      const isTurn = element => {
        if (!(element instanceof Element)) return false;
        const testID = element.getAttribute('data-testid') || '';
        return element.hasAttribute('data-turn-id') || element.hasAttribute('data-turn-id-container') || testID.startsWith('conversation-turn-') || (element.tagName === 'SECTION' && element.hasAttribute('data-turn'));
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
          html[${leanAttr}="1"] { scroll-behavior: auto !important; }
          html[${leanAttr}="1"] *, html[${leanAttr}="1"] *::before, html[${leanAttr}="1"] *::after {
            animation-duration: 0.001ms !important;
            animation-delay: 0s !important;
            animation-iteration-count: 1 !important;
            transition-duration: 0.001ms !important;
            transition-delay: 0s !important;
            scroll-behavior: auto !important;
          }
          html[${leanAttr}="1"] [class*="backdrop-blur"],
          html[${leanAttr}="1"] [class*="blur-"],
          html[${leanAttr}="1"] [class*="drop-shadow"] {
            -webkit-backdrop-filter: none !important;
            backdrop-filter: none !important;
            filter: none !important;
          }
          html[${leanAttr}="1"] [class*="shadow-"] { box-shadow: none !important; }
          [${completeAttr}="1"] *, [${hiddenAttr}="1"] * {
            animation: none !important;
            transition: none !important;
          }
          [${completeAttr}="1"] { contain: style; }
          [${composerAttr}="1"], nav[aria-label="Chat history"], [data-testid^="history-item-"] { contain: style; }
          [${completeAttr}="1"] details { margin-block: .3rem !important; }
          [${activityAttr}="1"] > summary { padding-block: .25rem !important; min-height: 0 !important; }
          [${completeAttr}="1"] [data-testid$="-turn-action-button"] { opacity: .08 !important; }
          [${completeAttr}="1"]:hover [data-testid$="-turn-action-button"],
          [${completeAttr}="1"] [data-testid$="-turn-action-button"]:focus-visible { opacity: 1 !important; }
          li[data-testid^="history-item-"] { min-height: 28px !important; margin-block: 0 !important; }
          [data-testid^="history-item-"][data-testid$="-options"] { opacity: .08 !important; }
          li[data-testid^="history-item-"]:hover [data-testid$="-options"],
          [data-testid^="history-item-"][data-testid$="-options"]:focus-visible { opacity: 1 !important; }
          [${completeAttr}="1"] details > summary { padding-block: .2rem !important; min-height: 0 !important; }
          [${completeAttr}="1"] pre, [${completeAttr}="1"] table { margin-block: .5rem !important; }
          [${completeAttr}="1"] pre { max-height: min(52vh, 480px) !important; overflow:auto !important; }
          #chatgpt-stable-activity-rail {
            position: fixed; right: 14px; top: 70px; z-index: 2147482998; width: 184px;
            max-height: min(56vh, 560px); overflow: hidden; border: 1px solid color-mix(in srgb, CanvasText 15%, transparent);
            border-radius: 12px; background: color-mix(in srgb, Canvas 94%, transparent); color: CanvasText;
            font: 12px/1.25 -apple-system,BlinkMacSystemFont,sans-serif; box-shadow: none; contain: layout style paint;
          }
          #chatgpt-stable-activity-header { width:100%; border:0; background:transparent; color:inherit; text-align:left; padding:8px 10px; font:inherit; font-weight:600; cursor:pointer; }
          #chatgpt-stable-activity-list { max-height: calc(min(56vh, 560px) - 34px); overflow:auto; border-top:1px solid color-mix(in srgb, CanvasText 10%, transparent); }
          #chatgpt-stable-activity-list[hidden] { display:none !important; }
          #chatgpt-stable-activity-list button { display:block; width:100%; border:0; background:transparent; color:inherit; text-align:left; padding:6px 10px; font:inherit; cursor:pointer; }
          #chatgpt-stable-activity-list button:hover { background:color-mix(in srgb, CanvasText 7%, transparent); }
          [${activityAttr}="1"] { scroll-margin-block: 120px; margin-block: .25rem !important; box-shadow: none !important; }
          [${activityHiddenAttr}="1"], [${bloatHiddenAttr}="1"] { display:none !important; }
          @media (max-width: 1100px) { #chatgpt-stable-activity-rail { display:none !important; } }
        `));
        (document.head || document.documentElement).appendChild(style);
      };

      const revealActivity = node => {
        if (!(node instanceof Element)) return;
        if (node.getAttribute(activityHiddenAttr) === '1') {
          const saved = originalActivityDisplay.get(node);
          if (saved) node.style.setProperty('display', saved.cssValue, saved.priority);
          else node.style.removeProperty('display');
          node.removeAttribute(activityHiddenAttr);
        }
      };

      const hideActivity = node => {
        if (!(node instanceof Element) || pinnedActivities.has(node) || node.getAttribute(activityHiddenAttr) === '1') return;
        originalActivityDisplay.set(node, {cssValue: node.style.getPropertyValue('display'), priority: node.style.getPropertyPriority('display')});
        node.setAttribute(activityHiddenAttr, '1');
        node.style.setProperty('display', 'none', 'important');
      };

      const virtualizeActivities = activities => {
        const root = state.scrollRoot;
        const preserveBottom = !!root && state.nearBottom;
        const previousBottomDistance = preserveBottom ? Math.max(0, root.scrollHeight - root.scrollTop - root.clientHeight) : 0;
        if (state.showAllActivities) {
          activities.forEach(item => { pinnedActivities.add(item.node); revealActivity(item.node); });
          state.activityMode = 'all';
        } else if (!state.nearBottom) {
          activities.forEach(item => revealActivity(item.node));
          state.activityMode = 'all';
        } else {
          const pressure = Math.max(state.domNodes, state.externalPressure);
          const compactKeep = terminalMode ? 8 : 12;
          const streamingKeep = terminalMode ? 4 : 6;
          const keep = state.generating && (pressure >= 5_000 || activities.length > compactKeep) ? streamingKeep : (activities.length > compactKeep ? compactKeep : activities.length);
          const cutoff = Math.max(0, activities.length - keep);
          activities.forEach((item, index) => {
            if (item.kind === 'Error' || item.kind === 'Artifact') revealActivity(item.node);
            else if (index < cutoff) hideActivity(item.node); else revealActivity(item.node);
          });
          state.activityMode = cutoff > 0 ? (state.generating ? 'streaming' : 'compact') : 'all';
        }
        if (!state.generating) {
          const collapseBefore = Math.max(0, activities.length - (terminalMode ? 2 : 3));
          activities.forEach((item, index) => {
            if (index >= collapseBefore || item.kind === 'Error' || item.kind === 'Artifact') return;
            if (item.node.tagName === 'DETAILS' && !item.node.hasAttribute(autoCollapsedAttr)) {
              if (item.node.open) item.node.open = false;
              item.node.setAttribute(autoCollapsedAttr, '1');
            }
          });
        }
        state.hiddenActivities = activities.reduce((count, item) => count + (item.node.getAttribute(activityHiddenAttr) === '1' ? 1 : 0), 0);
        if (preserveBottom) {
          requestAnimationFrame(() => {
            const target = Math.max(0, root.scrollHeight - root.clientHeight - previousBottomDistance);
            if (Math.abs(root.scrollTop - target) > 1) root.scrollTop = target;
          });
        }
      };

      const activityKind = element => {
        if (!(element instanceof Element)) return null;
        const testID = (element.getAttribute('data-testid') || '').toLowerCase();
        if (/(error|failed|failure)/.test(testID)) return 'Error';
        if (/(artifact|download|attachment|generated-file)/.test(testID)) return 'Artifact';
        if (/(reason|think|thought)/.test(testID)) return 'Reasoning';
        if (/(source|citation|reference)/.test(testID)) return 'Sources';
        if (/search/.test(testID)) return 'Search';
        if (/browser/.test(testID)) return 'Browser';
        if (/computer/.test(testID)) return 'Computer';
        if (/terminal|shell/.test(testID)) return 'Terminal';
        if (/python/.test(testID)) return 'Python';
        if (/research/.test(testID)) return 'Research';
        if (/canvas/.test(testID)) return 'Canvas';
        if (/tool/.test(testID)) return 'Tool';
        if (element.tagName === 'PRE') return 'Code';
        if (element.tagName === 'TABLE') return 'Table';
        if (element.tagName === 'CANVAS') return 'Chart';
        if (element.tagName === 'VIDEO' || element.tagName === 'AUDIO' || element.tagName === 'IFRAME' || element.tagName === 'FIGURE') return 'Media';
        if (element.tagName === 'DETAILS') return 'Detail';
        return null;
      };

      const ensureActivityRail = () => {
        let rail = document.getElementById('chatgpt-stable-activity-rail');
        if (rail) return rail;
        rail = document.createElement('section');
        rail.id = 'chatgpt-stable-activity-rail';
        rail.classList.add('rr-block');
        const header = document.createElement('button');
        header.id = 'chatgpt-stable-activity-header';
        header.type = 'button';
        header.addEventListener('click', () => {
          state.activityExpanded = !state.activityExpanded;
          const list = document.getElementById('chatgpt-stable-activity-list');
          if (list) list.hidden = !state.activityExpanded;
        });
        const thread = document.createElement('div');
        thread.id = 'chatgpt-stable-thread-nav';
        thread.style.cssText = 'display:none;padding:7px 10px;border-top:1px solid color-mix(in srgb, CanvasText 10%, transparent)';
        const threadLabel = document.createElement('div');
        threadLabel.id = 'chatgpt-stable-thread-label';
        threadLabel.style.cssText = 'margin-bottom:4px;opacity:.72';
        const threadRange = document.createElement('input');
        threadRange.id = 'chatgpt-stable-thread-range';
        threadRange.type = 'range';
        threadRange.min = '0';
        threadRange.step = '1';
        threadRange.setAttribute('aria-label', 'Conversation turn');
        threadRange.style.cssText = 'width:100%;margin:0;accent-color:currentColor';
        threadRange.addEventListener('change', () => {
          const index = Math.max(0, Math.min(state.turnShellNodes.length - 1, Number.isFinite(threadRange.valueAsNumber) ? threadRange.valueAsNumber : 0));
          const target = state.turnShellNodes[index];
          if (target) target.scrollIntoView({block:'center', behavior:'auto'});
        });
        thread.append(threadLabel, threadRange);
        const list = document.createElement('div');
        list.id = 'chatgpt-stable-activity-list';
        const reveal = document.createElement('button');
        reveal.id = 'chatgpt-stable-activity-reveal';
        reveal.type = 'button';
        reveal.style.cssText = 'width:100%;border:0;border-top:1px solid color-mix(in srgb, CanvasText 10%, transparent);background:transparent;color:inherit;text-align:left;padding:7px 10px;font:inherit;cursor:pointer;display:none';
        reveal.addEventListener('click', () => {
          state.showAllActivities = !state.showAllActivities;
          if (state.showAllActivities) {
            for (const item of state.activityNodes) { pinnedActivities.add(item.node); revealActivity(item.node); }
            state.hiddenActivities = 0;
            state.activityMode = 'all';
          } else {
            pinnedActivities = new WeakSet();
          }
          scheduleScan(100);
        });
        rail.append(header, thread, list, reveal);
        document.documentElement.appendChild(rail);
        return rail;
      };

      const updateActivityRail = activities => {
        const rail = ensureActivityRail();
        const header = rail.querySelector('#chatgpt-stable-activity-header');
        const thread = rail.querySelector('#chatgpt-stable-thread-nav');
        const threadLabel = rail.querySelector('#chatgpt-stable-thread-label');
        const threadRange = rail.querySelector('#chatgpt-stable-thread-range');
        const list = rail.querySelector('#chatgpt-stable-activity-list');
        const reveal = rail.querySelector('#chatgpt-stable-activity-reveal');
        if (!header || !thread || !threadLabel || !threadRange || !list || !reveal) return;
        const showThread = state.turnShellNodes.length > 12;
        if (!activities.length && !state.generating && !showThread) { rail.style.display = 'none'; return; }
        thread.style.display = showThread ? 'block' : 'none';
        if (showThread) {
          threadLabel.replaceChildren(document.createTextNode(`Thread · ${state.turnShellNodes.length} turns`));
          threadRange.max = String(Math.max(0, state.turnShellNodes.length - 1));
          if (!threadRange.matches(':active')) threadRange.valueAsNumber = Number(threadRange.max);
        }
        rail.style.display = 'block';
        const status = state.generating ? 'Running' : (activities.length ? 'Activity' : 'Conversation');
        const extras = [];
        if (state.errorCount) extras.push(`error ${state.errorCount}`);
        if (state.toolCount) extras.push(`tool ${state.toolCount}`);
        if (state.reasoningCount) extras.push(`reason ${state.reasoningCount}`);
        if (state.hiddenActivities) extras.push(`parked ${state.hiddenActivities}`);
        if (state.activityMode !== 'all') extras.push(state.activityMode);
        const detail = extras.length ? ` · ${extras.join(' · ')}` : '';
        header.replaceChildren(document.createTextNode(`${status}${activities.length ? ` · ${activities.length}` : ''}${detail}`));
        list.hidden = !state.activityExpanded;
        const compactable = activities.length > 12;
        reveal.style.display = state.hiddenActivities || (state.showAllActivities && compactable) ? 'block' : 'none';
        const revealLabel = state.showAllActivities ? 'Compact activity' : `Show all activity (${state.hiddenActivities} parked)`;
        reveal.replaceChildren(document.createTextNode(revealLabel));
        list.replaceChildren();
        const start = Math.max(0, activities.length - state.railKeep);
        if (start > 0) {
          const earlier = document.createElement('button');
          earlier.type = 'button';
          earlier.replaceChildren(document.createTextNode(`Earlier activity (${start})`));
          earlier.addEventListener('click', () => {
            state.railKeep += 40;
            updateActivityRail(state.activityNodes);
          });
          list.appendChild(earlier);
        }
        activities.slice(start).forEach((item, offset) => {
          const index = start + offset;
          const button = document.createElement('button');
          button.type = 'button';
          const suffix = index === activities.length - 1 && state.generating ? ' · active' : '';
          button.replaceChildren(document.createTextNode(`${item.kind} ${index + 1}${suffix}`));
          if (item.node.getAttribute(activityHiddenAttr) === '1') button.appendChild(document.createTextNode(' · parked'));
          button.addEventListener('click', () => {
            pinnedActivities.add(item.node);
            revealActivity(item.node);
            item.node.scrollIntoView({block:'center', behavior:'auto'});
            scheduleScan(100);
          });
          list.appendChild(button);
        });
      };

      const collectActivities = targets => {
        const activities = [];
        const seen = new Set();
        for (const turn of targets) {
          if (!(turn instanceof Element)) continue;
          const assistant = turn.querySelector(assistantSelector);
          if (!assistant) continue;
          const candidates = turn.querySelectorAll('details,[data-testid],pre,table,video,audio,iframe,figure,canvas');
          for (const candidate of candidates) {
            if (candidate.id?.startsWith('chatgpt-stable-')) continue;
            let node = candidate;
            const details = candidate.closest('details');
            if (details && turn.contains(details)) node = details;
            if (seen.has(node)) continue;
            const kind = activityKind(candidate) || activityKind(node);
            if (!kind) continue;
            seen.add(node);
            node.setAttribute(activityAttr, '1');
            activities.push({node, kind});
          }
        }
        state.activityNodes = activities;
        state.activityTotal = activities.length;
        state.reasoningCount = activities.filter(item => item.kind === 'Reasoning').length;
        const toolKinds = new Set(['Tool','Search','Browser','Computer','Terminal','Python','Research','Canvas']);
        state.toolCount = activities.filter(item => toolKinds.has(item.kind)).length;
        state.detailCount = activities.filter(item => item.kind === 'Detail').length;
        state.errorCount = activities.filter(item => item.kind === 'Error').length;
        state.artifactCount = activities.filter(item => item.kind === 'Artifact').length;
        state.codeCount = 0;
        state.tableCount = 0;
        state.mediaCount = 0;
        for (const assistant of document.querySelectorAll(assistantSelector)) {
          state.codeCount += assistant.querySelectorAll('pre').length;
          state.tableCount += assistant.querySelectorAll('table').length;
          state.mediaCount += assistant.querySelectorAll('img,video,audio,iframe,canvas').length;
        }
        virtualizeActivities(activities);
        updateActivityRail(activities);
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
        const hidden = Array.from(document.querySelectorAll(`[${hiddenAttr}="1"]`));
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

      const hideNonEssentialChrome = () => {
        const candidates = document.querySelectorAll('[data-testid*="upsell" i],[data-testid*="upgrade" i],[data-testid*="promo" i]');
        for (const element of candidates) {
          if (element.closest('[data-message-author-role]')) continue;
          element.setAttribute(bloatHiddenAttr, '1');
        }
      };

      const markComposer = () => {
        const input = document.querySelector('[data-testid="prompt-textarea"],#prompt-textarea,[contenteditable="true"][data-lexical-editor="true"]');
        const form = input?.closest('form');
        if (form) {
          form.setAttribute(composerAttr, '1');
          form.classList.add('rr-block');
        }
      };

      const optimizeCompletedTurn = turn => {
        if (!(turn instanceof Element)) return;
        const media = turn.querySelectorAll('img,iframe');
        for (const element of media) {
          if (!element.hasAttribute('loading')) element.setAttribute('loading', 'lazy');
          if (element.tagName === 'IMG' && !element.hasAttribute('decoding')) element.setAttribute('decoding', 'async');
        }
        const details = turn.querySelectorAll('details');
        for (const item of details) {
          if (item.hasAttribute(autoCollapsedAttr)) continue;
          const itemTestID = (item.getAttribute('data-testid') || '').toLowerCase();
          const containsError = /(error|failed|failure)/.test(itemTestID) || !!item.querySelector('[data-testid*="error" i],[data-testid*="failed" i],[data-testid*="failure" i]');
          const containsArtifact = /(artifact|download|attachment|generated-file)/.test(itemTestID) || !!item.querySelector('[data-testid*="artifact" i],[data-testid*="download" i],[data-testid*="generated-file" i]');
          if (!containsError && !containsArtifact && item.open) item.open = false;
          item.setAttribute(autoCollapsedAttr, '1');
        }
      };

      const resetRoute = () => {
        for (const element of document.querySelectorAll(`[${hiddenAttr}="1"]`)) reveal(element);
        for (const element of document.querySelectorAll(`[${activityHiddenAttr}="1"]`)) revealActivity(element);
        state.path = location.pathname;
        state.keep = terminalMode ? 12 : 20;
        state.hidden = 0;
        state.mode = 'native';
        state.showAllActivities = false;
        state.railKeep = terminalMode ? 20 : 40;
        state.needsInitialBottom = isConversationPath(location.pathname);
      };

      const scan = () => {
        const scanStarted = performance.now();
        state.scanTimer = 0;
        if (!document.body) return;
        ensureStyle();
        hideNonEssentialChrome();
        markComposer();
        if (location.pathname !== state.path) resetRoute();

        const shells = document.querySelectorAll('[data-turn-id],[data-turn-id-container],[data-testid^="conversation-turn-"],section[data-turn]');
        const shellSet = new Set(shells);
        const roleCandidates = document.querySelectorAll(messageRoleSelector);
        const roleNodes = Array.from(roleCandidates).filter(node => {
          const role = (node.getAttribute('data-message-author-role') || node.getAttribute('data-role') || node.getAttribute('data-message-author') || '').toLowerCase();
          return role === 'assistant' || role === 'user';
        });
        const targets = [];
        const targetSet = new Set();
        let generating = false;
        let generationReason = 'none';

        const busyControls = document.querySelectorAll('[aria-busy="true"],[data-testid*="stop" i],[aria-label*="stop" i]');
        for (const element of busyControls) {
          if (!isVisibleControl(element)) continue;
          const testID = (element.getAttribute('data-testid') || '').toLowerCase();
          const ariaLabel = (element.getAttribute('aria-label') || '').toLowerCase();
          generating = true;
          generationReason = testID.includes('stop') || ariaLabel.includes('stop') ? 'stop-control' : 'aria-busy';
          break;
        }

        for (const roleNode of roleNodes) {
          const target = nearestTurn(roleNode);
          if (target && !targetSet.has(target)) {
            targetSet.add(target);
            targets.push(target);
          }
        }

        state.shells = shellSet.size;
        state.turnShellNodes = Array.from(shells);
        state.roles = roleNodes.length;
        state.generating = generating;
        state.generationReason = generationReason;
        state.visibleRoles = targets.filter(target => target.getAttribute(hiddenAttr) !== '1').length;
        targets.forEach((target, index) => {
          target.classList.add('rr-block');
          if (index < targets.length - 1) {
            target.setAttribute(completeAttr, '1');
            optimizeCompletedTurn(target);
          } else {
            target.removeAttribute(completeAttr);
          }
        });

        if (targets.length) {
          const root = findScrollRoot(targets[targets.length - 1]);
          attachScrollRoot(root);
          if (state.needsInitialBottom) {
            root.scrollTop = Math.max(0, root.scrollHeight - root.clientHeight);
            state.needsInitialBottom = false;
          }
          const distanceFromBottom = root.scrollHeight - root.scrollTop - root.clientHeight;
          const nearBottom = distanceFromBottom < Math.max(600, root.clientHeight * 1.5);
          state.nearBottom = nearBottom;
          const canHide = shellSet.size >= targets.length;

          const streamingPressureThreshold = terminalMode ? 5_000 : 9_000;
          const streamingPressure = generating && Math.max(state.domNodes, state.externalPressure) >= streamingPressureThreshold;
          if (streamingPressure && targets.length > 4 && nearBottom && canHide) {
            const cutoff = Math.max(0, targets.length - 4);
            for (let i = 0; i < targets.length; i++) {
              if (i < cutoff) hide(targets[i]);
              else reveal(targets[i]);
            }
            state.mode = 'streaming';
          } else if (targets.length > (terminalMode ? 20 : 32) && nearBottom && canHide) {
            const pressure = Math.max(state.domNodes, state.externalPressure);
            const tailKeep = terminalMode
              ? (pressure >= 12_000 ? 6 : (pressure >= 5_000 ? 8 : state.keep))
              : (pressure >= 12_000 ? 8 : (pressure >= 5_000 ? 12 : state.keep));
            const cutoff = Math.max(0, targets.length - tailKeep);
            for (let i = 0; i < targets.length; i++) {
              if (i < cutoff) hide(targets[i]);
              else reveal(targets[i]);
            }
            state.mode = 'tail';
          } else if (targets.length <= (terminalMode ? 20 : 32)) {
            targets.forEach(reveal);
            state.mode = 'native';
          }
        }

        collectActivities(targets);
        state.hidden = 0;
        state.visibleRoles = 0;
        for (const target of targets) {
          if (target.getAttribute(hiddenAttr) === '1') state.hidden++;
          else state.visibleRoles++;
        }
        updateControl();
        state.scanMs = Math.max(0, performance.now() - scanStarted);
      };

      const scheduleScan = delay => {
        if (state.scanTimer) window.clearTimeout(state.scanTimer);
        state.scanTimer = window.setTimeout(() => {
          state.scanTimer = 0;
          if (state.scanPending) return;
          state.scanPending = true;
          const run = () => {
            state.scanPending = false;
            scan();
          };
          if (window.requestIdleCallback) window.requestIdleCallback(run, {timeout: 500});
          else run();
        }, delay);
      };

      const relevantSelector = '[data-turn-id],[data-turn-id-container],[data-testid^="conversation-turn-"],section[data-turn],[data-message-author-role],[data-role],[data-message-author],[aria-busy="true"],[data-testid*="stop" i],details,pre,table,video,audio,iframe,figure,canvas,[data-testid*="reason" i],[data-testid*="think" i],[data-testid*="tool" i],[data-testid*="search" i],[data-testid*="source" i],[data-testid*="citation" i]';
      const relevant = node => {
        if (!(node instanceof Element)) return false;
        if (node.matches(relevantSelector)) return true;
        return !!node.querySelector(relevantSelector);
      };

      const observer = new MutationObserver(mutations => {
        if (document.hidden) return;
        for (const mutation of mutations) {
          for (const node of mutation.addedNodes) {
            if (relevant(node)) { scheduleScan(terminalMode ? 500 : 350); return; }
          }
          for (const node of mutation.removedNodes) {
            if (relevant(node)) { scheduleScan(terminalMode ? 500 : 350); return; }
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
            nearBottom: state.nearBottom,
            activityTotal: state.activityTotal,
            reasoningCount: state.reasoningCount,
            toolCount: state.toolCount,
            detailCount: state.detailCount,
            errorCount: state.errorCount,
            artifactCount: state.artifactCount,
            codeCount: state.codeCount,
            tableCount: state.tableCount,
            mediaCount: state.mediaCount,
            scanMs: state.scanMs,
            hiddenActivities: state.hiddenActivities,
            activityMode: state.activityMode
          };
        },
        pressure(domNodes) {
          if (Number.isFinite(domNodes) && domNodes >= 0) {
            state.externalPressure = domNodes;
            state.domNodes = domNodes;
          }
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

    private static let routeSource = #"""
    (() => {
      const host = String(location.hostname || '').toLowerCase();
      const trusted = host === 'chatgpt.com' || host.endsWith('.chatgpt.com') ||
        host === 'chat.openai.com' || host.endsWith('.chat.openai.com');
      if (!trusted || window.__chatgptStableWarmRoute) return;
      window.__chatgptStableWarmRoute = true;
      const bypass = new WeakSet();
      const isConversationPath = path => {
        const parts = String(path || '').split('/').filter(Boolean);
        const index = parts.indexOf('c');
        return index >= 0 && index + 1 < parts.length && !!parts[index + 1];
      };
      const replay = anchor => {
        bypass.add(anchor);
        anchor.click();
      };
      const prewarmRecent = attempt => {
        if (isConversationPath(location.pathname)) return;
        const handler = window.webkit?.messageHandlers?.warmConversationCache;
        if (!handler) return;
        let path = null;
        for (const anchor of document.querySelectorAll('a[href]')) {
          let target;
          try { target = new URL(anchor.href, location.href); } catch (_) { continue; }
          if (target.origin === location.origin && isConversationPath(target.pathname)) { path = target.pathname; break; }
        }
        if (!path) {
          if (attempt < 3) setTimeout(() => prewarmRecent(attempt + 1), 1500);
          return;
        }
        Promise.resolve(handler.postMessage({op:'prewarm', path})).catch(() => {});
      };
      setTimeout(() => prewarmRecent(0), 2500);

      document.addEventListener('click', event => {
        if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
        const anchor = event.target instanceof Element ? event.target.closest('a[href]') : null;
        if (!anchor || bypass.has(anchor)) { if (anchor) bypass.delete(anchor); return; }
        let target;
        try { target = new URL(anchor.href, location.href); } catch (_) { return; }
        if (target.origin !== location.origin || !isConversationPath(target.pathname)) return;
        const handler = window.webkit?.messageHandlers?.warmConversationCache;
        if (!handler) return;
        event.preventDefault();
        event.stopImmediatePropagation();
        Promise.resolve(handler.postMessage({op:'query', path:target.pathname})).then(decision => {
          if (decision === 'warm' || decision === 'preserve-current') {
            const internal = new URL('chatgpt-stable://conversation');
            internal.searchParams.set('path', target.pathname);
            location.assign(internal.href);
          } else {
            replay(anchor);
          }
        }).catch(() => replay(anchor));
      }, true);
    })();
    """#
}
