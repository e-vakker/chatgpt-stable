import WebKit

enum TerminalInterface {
    static let source = #"""
    (() => {
      const host = String(location.hostname || '').toLowerCase();
      const trusted = host === 'chatgpt.com' || host.endsWith('.chatgpt.com') ||
        host === 'chat.openai.com' || host.endsWith('.chat.openai.com');
      if (!trusted || window.__chatgptStableTerminal) return;
      window.__chatgptStableTerminal = true;

      const root = document.documentElement;
      const modeAttr = 'data-chatgpt-stable-terminal';
      const sidebarAttr = 'data-chatgpt-stable-terminal-sidebar';
      root.setAttribute(modeAttr, '1');
      root.setAttribute(sidebarAttr, 'closed');

      const style = document.createElement('style');
      style.id = 'chatgpt-stable-terminal-style';
      style.appendChild(document.createTextNode(`
        html[${modeAttr}="1"] { color-scheme: light dark; }
        html[${modeAttr}="1"] body {
          background: Canvas !important;
          color: CanvasText !important;
        }
        html[${modeAttr}="1"] body,
        html[${modeAttr}="1"] main {
          font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace !important;
        }
        html[${modeAttr}="1"][${sidebarAttr}="closed"] aside.dframe-sidebar,
        html[${modeAttr}="1"][${sidebarAttr}="closed"] #stage-slideover-sidebar,
        html[${modeAttr}="1"][${sidebarAttr}="closed"] #sidebar,
        html[${modeAttr}="1"][${sidebarAttr}="closed"] nav[aria-label="Chat history"] {
          display: none !important;
        }
        html[${modeAttr}="1"] [data-testid="chat-header"],
        html[${modeAttr}="1"] #page-header,
        html[${modeAttr}="1"] main > header,
        html[${modeAttr}="1"] main [role="tablist"] {
          display: none !important;
        }
        html[${modeAttr}="1"] main {
          width: 100% !important;
          max-width: none !important;
          padding-inline: 10px !important;
        }
        html[${modeAttr}="1"] [data-turn-id],
        html[${modeAttr}="1"] [data-turn-id-container],
        html[${modeAttr}="1"] [data-testid^="conversation-turn-"],
        html[${modeAttr}="1"] section[data-turn] {
          width: 100% !important;
          max-width: none !important;
          padding-block: 4px !important;
          margin-block: 0 !important;
        }
        html[${modeAttr}="1"] [data-message-author-role="assistant"],
        html[${modeAttr}="1"] [data-message-author-role="user"],
        html[${modeAttr}="1"] [data-role="assistant"],
        html[${modeAttr}="1"] [data-role="user"],
        html[${modeAttr}="1"] [data-message-author="assistant"],
        html[${modeAttr}="1"] [data-message-author="user"] {
          width: min(100%, 1120px) !important;
          max-width: 1120px !important;
          margin-inline: auto !important;
          font-size: 13px !important;
          line-height: 1.48 !important;
        }
        html[${modeAttr}="1"] [data-message-author-role="user"],
        html[${modeAttr}="1"] [data-role="user"],
        html[${modeAttr}="1"] [data-message-author="user"] {
          border-left: 2px solid color-mix(in srgb, CanvasText 24%, transparent) !important;
          padding-left: 10px !important;
        }
        html[${modeAttr}="1"] [data-user-message-bubble="true"] {
          background: transparent !important;
          border: 0 !important;
          border-radius: 0 !important;
          box-shadow: none !important;
          padding: 0 !important;
        }
        html[${modeAttr}="1"] [data-message-action-bar],
        html[${modeAttr}="1"] [data-testid$="-turn-action-button"] {
          display: none !important;
        }
        html[${modeAttr}="1"] details,
        html[${modeAttr}="1"] pre,
        html[${modeAttr}="1"] table {
          border-radius: 0 !important;
          box-shadow: none !important;
        }
        html[${modeAttr}="1"] details {
          border: 0 !important;
          padding-block: 2px !important;
          margin-block: 2px !important;
        }
        html[${modeAttr}="1"] [data-chatgpt-stable-composer="1"] {
          width: min(100%, 1120px) !important;
          max-width: 1120px !important;
          margin-inline: auto !important;
          border: 1px solid color-mix(in srgb, CanvasText 22%, transparent) !important;
          border-radius: 0 !important;
          box-shadow: none !important;
          background: Canvas !important;
          padding: 4px 6px !important;
        }
        html[${modeAttr}="1"] [data-chatgpt-stable-composer="1"] button:not([data-testid*="send" i]):not([data-testid*="stop" i]):not([aria-label*="send" i]):not([aria-label*="stop" i]) {
          display: none !important;
        }
        html[${modeAttr}="1"] #prompt-textarea,
        html[${modeAttr}="1"] [data-testid="prompt-textarea"],
        html[${modeAttr}="1"] [data-testid="chat-input"] {
          font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace !important;
          font-size: 13px !important;
          line-height: 1.4 !important;
          max-height: 32vh !important;
        }
        html[${modeAttr}="1"] #chatgpt-stable-activity-rail {
          top: 8px !important;
          right: 8px !important;
          width: 228px !important;
          max-height: min(46vh, 480px) !important;
          border-radius: 0 !important;
          background: Canvas !important;
          font: 11px/1.3 ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace !important;
        }
        html[${modeAttr}="1"] #chatgpt-stable-history-control {
          border-radius: 0 !important;
          font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace !important;
          box-shadow: none !important;
        }
        #chatgpt-stable-terminal-sidebar-toggle {
          position: fixed;
          top: 8px;
          left: 8px;
          z-index: 2147483001;
          min-width: 48px;
          padding: 4px 7px;
          border: 1px solid color-mix(in srgb, CanvasText 22%, transparent);
          border-radius: 0;
          background: Canvas;
          color: CanvasText;
          font: 11px/1.2 ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
          cursor: pointer;
          box-shadow: none;
        }
      `));
      root.appendChild(style);

      const toggleSidebar = () => {
        root.setAttribute(sidebarAttr, root.getAttribute(sidebarAttr) === 'open' ? 'closed' : 'open');
      };
      const ensureToggle = () => {
        if (document.getElementById('chatgpt-stable-terminal-sidebar-toggle')) return;
        const button = document.createElement('button');
        button.id = 'chatgpt-stable-terminal-sidebar-toggle';
        button.type = 'button';
        button.setAttribute('aria-label', 'Toggle chat list');
        button.appendChild(document.createTextNode('chats'));
        button.addEventListener('click', toggleSidebar);
        root.appendChild(button);
      };
      document.addEventListener('keydown', event => {
        if (event.altKey && !event.metaKey && !event.ctrlKey && String(event.key).toLowerCase() === 'l') {
          event.preventDefault();
          toggleSidebar();
        }
      }, true);
      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', ensureToggle, {once:true});
      } else {
        ensureToggle();
      }
    })();
    """#
}
