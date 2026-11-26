import AppKit
import WebKit

// A page's main content as Markdown, for Edit › Copy Page as Markdown, and as
// plain text for what keeps an eye on a page (PinChanges, PageWatch).
//
// Read by Cairn's own script in Cairn's own world (PageScripts), so the page
// can't swap the words as they are taken. No form control is read at all, nor
// anything you can type into: no password, card number or one-time code, and
// nothing half written. Hidden things and frames are left out. What comes back
// is the website's words: data, wherever it goes.

extension PageScripts {
    private static let markdownBody = #"""
    (function (withLinks, most) {
      var SKIP = /^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE|INPUT|TEXTAREA|SELECT|OPTION|DATALIST|BUTTON|OUTPUT|IFRAME|FRAME|EMBED|OBJECT|SVG|CANVAS|VIDEO|AUDIO|IMG|PICTURE|NAV|DIALOG)$/;
      var BLOCK = /^(ADDRESS|ARTICLE|ASIDE|BLOCKQUOTE|DD|DETAILS|DIV|DL|DT|FIELDSET|FIGCAPTION|FIGURE|FOOTER|FORM|H[1-6]|HEADER|HR|LI|MAIN|OL|P|PRE|SECTION|SUMMARY|TABLE|TBODY|TD|TFOOT|TH|THEAD|TR|UL)$/;
      var length = 0, cut = false;
      function skipped(el, root) {
        var t = el.tagName.toUpperCase();
        if (SKIP.test(t)) return true;
        // Anything you can write in: a draft is yours, not the page's.
        var edit = el.getAttribute('contenteditable');
        if (edit !== null && edit !== 'false') return true;
        if (SECRETS.has(el) || el.getAttribute('aria-hidden') === 'true' || el.hidden) return true;
        var how = getComputedStyle(el);
        if (how.display === 'none' || how.visibility === 'hidden' || how.opacity === '0') return true;
        // A page's own header, footer and side rails, but not an article's.
        if (el !== root && /^(ASIDE|FOOTER|HEADER)$/.test(t) && !el.closest('article')) return true;
        return /^(navigation|banner|contentinfo|complementary|search|menu)$/.test(el.getAttribute('role') || '');
      }
      function esc(s) { return s.replace(/([\\`*_\[\]<>])/g, '\\$1'); }
      function tidy(s) { return s.replace(/[ \t\r\n\f]+/g, ' '); }
      function address(a) {
        var href = String(a.href || '');
        if (!/^(https?|mailto):/i.test(href)) return null;
        return href.replace(/\s/g, '%20').replace(/\(/g, '%28').replace(/\)/g, '%29');
      }
      // The words of one line: links, emphasis and code, no blocks.
      function inline(node, root) {
        if (node.nodeType === 3) return esc(tidy(node.nodeValue));
        if (node.nodeType !== 1 || skipped(node, root)) return '';
        var t = node.tagName;
        if (t === 'BR') return '\n';
        if (t === 'CODE' || t === 'KBD' || t === 'SAMP') {
          var code = tidy(node.textContent).trim();
          if (!code) return '';
          var tick = code.indexOf('`') < 0 ? '`' : '``';
          return tick + (tick.length > 1 ? ' ' + code + ' ' : code) + tick;
        }
        var inner = children(node).map(function (c) { return inline(c, root); }).join('');
        if (BLOCK.test(t)) inner = ' ' + inner + ' ';
        var said = inner.trim();
        if (!said) return inner ? ' ' : '';
        var lead = /^\s/.test(inner) ? ' ' : '', trail = /\s$/.test(inner) ? ' ' : '';
        if (t === 'A' && withLinks) {
          var to = address(node);
          return to ? lead + '[' + said + '](' + to + ')' + trail : inner;
        }
        if (t === 'STRONG' || t === 'B') return lead + '**' + said + '**' + trail;
        if (t === 'EM' || t === 'I') return lead + '*' + said + '*' + trail;
        return inner;
      }
      function children(el) {
        var from = el.shadowRoot || el;
        if (el.tagName === 'SLOT' && el.assignedNodes().length) return el.assignedNodes();
        return Array.prototype.slice.call(from.childNodes);
      }
      // A line of its own, its first character kept from reading as Markdown.
      function line(s) {
        return s.split('\n').map(function (l) {
          return tidy(l).trim().replace(/^(#|\+|-|=|>)/, '\\$1').replace(/^(\d+)([.)])(\s)/, '$1\\$2$3');
        }).filter(Boolean).join('\n');
      }
      function push(out, block) {
        if (!block || cut) return;
        if (length + block.length > most) { cut = true; return; }
        length += block.length;
        out.push(block);
      }
      function list(el, root, depth) {
        var lines = [], n = +(el.getAttribute('start') || 1);
        Array.prototype.forEach.call(el.children, function (li) {
          if (li.tagName !== 'LI' || skipped(li, root)) return;
          var words = '', nested = [];
          children(li).forEach(function (c) {
            if (c.nodeType === 1 && /^(UL|OL)$/.test(c.tagName)) { if (depth < 6 && !skipped(c, root)) nested.push(list(c, root, depth + 1)); }
            else words += inline(c, root);
          });
          words = tidy(words).trim();
          var mark = el.tagName === 'OL' ? (n++) + '. ' : '- ';
          if (words) lines.push('  '.repeat(depth) + mark + words);
          nested.forEach(function (s) { if (s) lines.push(s); });
        });
        return lines.join('\n');
      }
      function table(el, root) {
        var rows = [];
        Array.prototype.forEach.call(el.rows, function (tr) {
          if (skipped(tr, root) || rows.length >= 500) return;
          var cells = Array.prototype.slice.call(tr.cells).filter(function (c) { return !skipped(c, root); })
            .map(function (c) { return tidy(inline(c, root)).trim().replace(/\|/g, '\\|'); });
          if (cells.some(Boolean)) rows.push(cells);
        });
        if (!rows.length) return '';
        var wide = Math.max.apply(null, rows.map(function (r) { return r.length; }));
        // One column is a table used to lay a page out, not a table.
        if (wide < 2) return rows.map(function (r) { return r[0]; }).join('\n\n');
        function row(r) { var c = r.slice(); while (c.length < wide) c.push(''); return '| ' + c.join(' | ') + ' |'; }
        return [row(rows[0]), '|' + ' --- |'.repeat(wide)].concat(rows.slice(1).map(row)).join('\n');
      }
      function blocks(el, root, out, depth) {
        var run = '';
        function flush() { push(out, line(run)); run = ''; }
        children(el).forEach(function (c) {
          if (cut) return;
          if (c.nodeType === 3) { run += inline(c, root); return; }
          if (c.nodeType !== 1 || skipped(c, root)) return;
          var t = c.tagName;
          var holds = c.shadowRoot || c.querySelector('p,div,ul,ol,table,pre,h1,h2,h3,h4,h5,h6,blockquote,section,article');
          if (!BLOCK.test(t) && !holds) { run += inline(c, root); return; }
          flush();
          if (/^H[1-6]$/.test(t)) {
            var head = tidy(inline(c, root)).trim();
            push(out, head && '#'.repeat(+t[1]) + ' ' + head);
          } else if (t === 'PRE') {
            var text = c.innerText.replace(/\n+$/, '');
            var fence = '```';
            while (text.indexOf(fence) >= 0) fence += '`';
            var kind = ((c.querySelector('code') || c).className || '').toString().match(/(?:language|lang)-([\w+#.-]{1,20})/);
            push(out, text && fence + (kind ? kind[1] : '') + '\n' + text + '\n' + fence);
          } else if (t === 'UL' || t === 'OL') {
            push(out, list(c, root, 0));
          } else if (t === 'TABLE') {
            push(out, table(c, root));
          } else if (t === 'BLOCKQUOTE') {
            var quoted = [];
            if (depth < 40) blocks(c, root, quoted, depth + 1);
            push(out, quoted.join('\n\n').split('\n').map(function (l) { return ('> ' + l).trim(); }).join('\n').replace(/^>$/, ''));
          } else if (t === 'HR') {
            push(out, '---');
          } else if (depth < 40) {
            blocks(c, root, out, depth + 1);
          }
        });
        flush();
      }
      // The main content: what the page calls main, or its one article, when
      // there is something to it; else the body.
      function main() {
        var marked = Array.prototype.slice.call(document.querySelectorAll('main,[role=main]'));
        if (!marked.length) {
          var articles = document.querySelectorAll('article');
          if (articles.length === 1) marked = [articles[0]];
        }
        var best = null, size = 200;
        marked.forEach(function (el) {
          var n = (el.innerText || '').length;
          if (n >= size) { best = el; size = n; }
        });
        return best || document.body;
      }
      var root = main(), out = [];
      if (root) blocks(root, root, out, 0);
      return JSON.stringify({ markdown: out.join('\n\n'), cut: cut, title: document.title, url: location.href });
    })
    """#

    /// The page's main content as Markdown, at most `most` characters of it.
    /// `links` false for text that is only compared, so no address with a
    /// token in it is kept.
    static func markdown(links: Bool = true, most: Int = 400_000) -> String {
        call(markdownBody, [links, most])
    }
}

enum PageMarkdown {
    struct Page: Equatable {
        var markdown: String
        var cut: Bool
        var title: String
        var url: URL?
    }

    static func page(from value: Any?) -> Page? {
        guard let text = value as? String, let data = text.data(using: .utf8),
              let out = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let markdown = out["markdown"] as? String else { return nil }
        return Page(markdown: markdown, cut: out["cut"] as? Bool ?? false, title: out["title"] as? String ?? "",
                    url: (out["url"] as? String).flatMap { URL(string: $0) })
    }

    @MainActor
    static func read(_ web: WKWebView, links: Bool = true, most: Int = 400_000, _ done: @escaping (Page?) -> Void) {
        web.evaluateJavaScript(PageScripts.markdown(links: links, most: most), in: nil, in: Web.world) { result in
            done(page(from: try? result.get()))
        }
    }

    /// What goes to the clipboard: the content, headed by the page's title
    /// when it has no heading of its own.
    static func copied(_ page: Page) -> String? {
        guard !page.markdown.isEmpty else { return nil }
        let title = page.title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let headed = page.markdown.hasPrefix("# ") || page.markdown.contains("\n# ")
        let head = headed || title.isEmpty ? "" : "# " + title + "\n\n"
        return head + page.markdown + (page.cut ? "\n\n(cut short: the page is longer)" : "") + "\n"
    }
}

extension Browser {
    /// Edit › Copy Page as Markdown: your own copy of your own page, private
    /// tabs included, to your own clipboard.
    func copyPageAsMarkdown(to board: NSPasteboard = .general) {
        guard let tab = active, tab.isWeb, !tab.asleep, let web = tab.built else {
            announce("No page to copy")
            return
        }
        PageMarkdown.read(web) { [weak self] page in
            guard let text = page.flatMap(PageMarkdown.copied) else {
                self?.announce("Nothing to copy on this page")
                return
            }
            board.clearContents()
            board.setString(text, forType: .string)
            self?.announce("Page copied as Markdown")
        }
    }
}
