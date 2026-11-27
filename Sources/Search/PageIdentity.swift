import Foundation

// What an agent can say about an element that outlives a read: its eid, and
// what comes of acting on it.
//
// The scripts here run in Search's own content world, beside PageScripts'
// (they are put in front of every one of them: PageScripts.call). Nothing in
// this file keeps anything on disk: an eid is worked out again from the page
// each time it is asked about, so there is nothing to clear. Page text goes
// into a hash and never out of it.

extension PageScripts {
    /// Functions shared by every script: a synchronous SHA-256 (the page
    /// world has only the asynchronous one), the eid, and the five-point
    /// probe of whether a click would land.
    static let identity = #"""
    // SHA-256 of a string's UTF-8, as hex. The round constants and the
    // starting values are the fractional parts of the cube and square roots
    // of the first primes, as the standard defines them, so there is no
    // table to mistype; the test holds the two known answers.
    var sha256hex = (function () {
      var K = [], H0 = [], n = 0, c = 2;
      while (n < 64) {
        var prime = true;
        for (var d = 2; d * d <= c; d++) if (c % d === 0) { prime = false; break; }
        if (prime) {
          if (n < 8) H0[n] = Math.floor((Math.sqrt(c) % 1) * 4294967296) | 0;
          K[n] = Math.floor((Math.cbrt(c) % 1) * 4294967296) | 0;
          n++;
        }
        c++;
      }
      function rotr(x, k) { return (x >>> k) | (x << (32 - k)); }
      return function (text) {
        var s = unescape(encodeURIComponent(String(text))), len = s.length, words = [], i;
        for (i = 0; i < len; i++) words[i >> 2] = (words[i >> 2] | 0) | (s.charCodeAt(i) << (24 - (i % 4) * 8));
        words[len >> 2] = (words[len >> 2] | 0) | (0x80 << (24 - (len % 4) * 8));
        var total = (((len + 8) >> 6) + 1) << 4;
        for (i = 0; i < total; i++) words[i] = words[i] | 0;
        words[total - 1] = len * 8;
        var H = H0.slice();
        for (var b = 0; b < total; b += 16) {
          var w = [];
          for (var t = 0; t < 64; t++) {
            if (t < 16) w[t] = words[b + t];
            else {
              var a15 = w[t - 15], a2 = w[t - 2];
              var s0 = rotr(a15, 7) ^ rotr(a15, 18) ^ (a15 >>> 3), s1 = rotr(a2, 17) ^ rotr(a2, 19) ^ (a2 >>> 10);
              w[t] = (w[t - 16] + s0 + w[t - 7] + s1) | 0;
            }
          }
          var v = H.slice();
          for (t = 0; t < 64; t++) {
            var e = v[4], a = v[0];
            var t1 = (v[7] + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & v[5]) ^ (~e & v[6])) + K[t] + w[t]) | 0;
            var t2 = ((rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & v[1]) ^ (a & v[2]) ^ (v[1] & v[2]))) | 0;
            v = [(t1 + t2) | 0, a, v[1], v[2], (v[3] + t1) | 0, e, v[5], v[6]];
          }
          for (i = 0; i < 8; i++) H[i] = (H[i] + v[i]) | 0;
        }
        return H.map(function (x) { return ('00000000' + (x >>> 0).toString(16)).slice(-8); }).join('');
      };
    })();
    function sha8(text) { return sha256hex(text).slice(0, 8); }
    // For comparing a value before and after, never for naming one.
    function cheap(text) {
      var h = 2166136261;
      for (var i = 0; i < text.length; i++) { h ^= text.charCodeAt(i); h = Math.imul(h, 16777619); }
      return (h >>> 0).toString(16);
    }

    function up(n) {
      if (n.parentElement) return n.parentElement;
      var root = n.getRootNode ? n.getRootNode() : null;
      return root && root.host ? root.host : null;
    }
    var LANDMARKS = {main:1, navigation:1, banner:1, contentinfo:1, complementary:1, search:1, form:1, dialog:1, alertdialog:1};
    var LANDMARK_TAGS = /^(main|nav|header|footer|aside|form|dialog)$/;
    function landmarkOf(el) {
      for (var n = up(el); n; n = up(n)) {
        var r = (n.getAttribute('role') || '').toLowerCase(), t = n.tagName.toLowerCase();
        if (LANDMARKS[r] || LANDMARK_TAGS.test(t)) return (r || t) + ':' + squash(n.getAttribute('aria-label')).toLowerCase().slice(0, 30);
      }
      return '';
    }
    // Tags from the element up, without the divs and spans that only wrap:
    // a page that adds a wrapper has not made a new control.
    function pathOf(el) {
      var parts = [];
      for (var n = up(el), k = 0; n && k < 10; n = up(n), k++) {
        var t = n.tagName.toLowerCase(), r = n.getAttribute('role');
        if (t === 'html' || t === 'body') break;
        if (r || !/^(div|span)$/.test(t)) parts.unshift(r ? t + ':' + r : t);
      }
      return parts.join('>');
    }
    function ordinalOf(el) {
      var tag = el.tagName, r = el.getAttribute('role') || '', n = 0, k = 0;
      for (var s = el.previousElementSibling; s && k < 200; s = s.previousElementSibling, k++) {
        if (s.tagName === tag && (s.getAttribute('role') || '') === r) n++;
      }
      return n;
    }
    var CARD = 'li,tr,article,[role=listitem],[role=row],[role=article],[role=dialog],dialog,form,section,fieldset';
    var CARD_TEXT = new Map();
    function lead(node, most) {
      var walker = document.createTreeWalker(node, 4), out = '', t;
      while (out.length < most && (t = walker.nextNode())) {
        var p = t.parentElement;
        if (p && /^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE)$/.test(p.tagName)) continue;
        out += ' ' + t.nodeValue;
      }
      return squash(out).toLowerCase().replace(/\d+/g, '#').slice(0, most);
    }
    function ancestorText(el) {
      var a = up(el);
      while (a && !(a.matches && a.matches(CARD))) a = up(a);
      if (!a) return '';
      if (!CARD_TEXT.has(a)) CARD_TEXT.set(a, lead(a, 60));
      return CARD_TEXT.get(a);
    }
    // sha256(tag, role, accessible name, structural path, nearest landmark,
    // sibling ordinal, the words that set its row or card apart).prefix(8).
    function eidBase(el) {
      return [el.tagName.toLowerCase(), role(el), name(el).toLowerCase(), pathOf(el), landmarkOf(el), ordinalOf(el),
        ancestorText(el)].join('\u0001');
    }
    // The eid of every control a read would list, in document order. Two
    // that come out the same are told apart by their order, so an eid names
    // one element or none.
    function eids(list) {
      var seen = Object.create(null), out = new Map();
      for (var i = 0; i < list.length; i++) {
        var el = list[i];
        if (!wanted(el) || !visible(el)) continue;
        var base = eidBase(el), n = seen[base] | 0;
        seen[base] = n + 1;
        out.set(el, sha8(n ? base + '\u0001#' + n : base));
      }
      return out;
    }
    // For any element, listed or not: what covers a control, say.
    function eidFor(el, map) {
      for (var n = el; n; n = up(n)) if (map && map.has(n)) return map.get(n);
      return sha8(eidBase(el));
    }
    function findEid(eid) {
      var hits = [];
      eids(candidates()).forEach(function (id, el) { if (id === eid) hits.push(el); });
      return hits;
    }

    function deepAt(x, y) {
      var el = document.elementFromPoint(x, y);
      while (el && el.shadowRoot) {
        var inner = el.shadowRoot.elementFromPoint(x, y);
        if (!inner || inner === el) break;
        el = inner;
      }
      return el;
    }
    function reaches(el, hit) {
      for (var n = hit; n; n = n.parentNode || n.host) if (n === el) return true;
      var label = hit && hit.closest ? hit.closest('label') : null;
      return !!(label && label.control === el);
    }
    // Whether a click would land on it: the middle and four points inset
    // from its corners are each asked what is drawn there. A control that
    // is not on screen can't be asked, and is not hit-testable.
    function probe(el, map) {
      var r = el.getBoundingClientRect(), vw = innerWidth, vh = innerHeight;
      if (!(r.bottom > 0 && r.right > 0 && r.top < vh && r.left < vw)) return { testable: false, points: '0/0', why: 'offscreen', by: null };
      var at = [[0.5, 0.5], [0.15, 0.15], [0.85, 0.15], [0.15, 0.85], [0.85, 0.85]];
      var tested = 0, reached = 0, centre = null, by = null;
      for (var i = 0; i < at.length; i++) {
        var x = r.left + r.width * at[i][0], y = r.top + r.height * at[i][1];
        if (x < 0 || y < 0 || x >= vw || y >= vh) continue;
        tested++;
        var hit = deepAt(x, y), ok = !!hit && reaches(el, hit);
        if (ok) reached++;
        else if (by === null && hit && hit !== document.documentElement && hit !== document.body) by = hit;
        if (i === 0) centre = ok;
      }
      // A click goes to the middle: where that is on screen it decides.
      var testable = tested === 0 ? false : (centre !== null ? centre : reached * 2 >= tested);
      return { testable: testable, points: reached + '/' + tested, by: testable || !by ? null : eidFor(by, map) };
    }

    // What this element holds, for noticing a change. A secret one only says
    // whether it holds anything.
    function factsOf(el) {
      var v = '';
      if (/^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName) && !/^(submit|button|reset|image|checkbox|radio)$/i.test(el.type || '')) {
        v = secret(el) ? (el.value ? 'filled' : 'empty') : String(el.value).slice(0, 200);
      } else if (el.isContentEditable) v = String(el.innerText).slice(0, 200);
      return cheap([role(el), name(el), v, el.checked === true ? 1 : 0, el.disabled ? 1 : 0,
        el.getAttribute('aria-expanded'), el.getAttribute('aria-selected'), el.getAttribute('aria-pressed')].join('\u0001'));
    }
    """#

    /// What the page is, as an action's receipt compares it before and
    /// after: a hash of its controls and words, what has focus, what is in
    /// its storage by key and a hash of each value (never the value), and
    /// the requests it made so far, by what the page itself can see.
    ///
    /// `i` is the element of the last read the action is about; nil for the
    /// one that has focus (a key press).
    static func snapshot(key: String, snap: Int, index: Int?) -> String {
        call(#"""
        (function (key, snap, i) {
          var kept = globalThis[key], el = null;
          if (i !== null) el = kept && kept.snap === snap ? kept.els[i] : null;
          else if (document.activeElement && document.activeElement !== document.body &&
                   document.activeElement !== document.documentElement) el = document.activeElement;
          var list = candidates(), map = eids(list), nodes = {}, count = 0, parts = [];
          map.forEach(function (id, n) {
            if (count++ >= 600) return;
            var f = factsOf(n);
            nodes[id] = f;
            parts.push(id + f);
          });
          var text = document.body ? document.body.innerText : '';
          var words = sha8(text.slice(0, 30000));
          function store(s) {
            var o = {};
            try { for (var k = 0; k < s.length && k < 300; k++) { var name = s.key(k); o[name] = cheap(String(s.getItem(name)).slice(0, 2000)); } }
            catch (e) { return null; }
            return o;
          }
          var cookies = {};
          try {
            document.cookie.split(';').forEach(function (p) {
              var kv = p.split('='), n = kv.shift().trim();
              if (n) cookies[n] = cheap(kv.join('='));
            });
          } catch (e) {}
          var seen = [];
          try {
            var entries = performance.getEntriesByType('resource');
            var mine = entries.slice(Math.max(0, entries.length - 60));
            mine.forEach(function (e) {
              if (!/^(fetch|xmlhttprequest|beacon)$/.test(e.initiatorType)) return;
              var origin = ''; try { origin = new URL(e.name).origin; } catch (x) {}
              seen.push({ via: e.initiatorType, origin: origin, status: e.responseStatus || null });
            });
            var total = entries.length;
          } catch (e) { total = 0; }
          var active = document.activeElement, focus = null;
          if (active && active !== document.body && active !== document.documentElement) {
            focus = { eid: eidFor(active, map), role: role(active), name: squash(name(active)).slice(0, 60) };
          }
          var out = { url: location.href, hash: sha256hex(location.href + '|' + parts.join(',') + '|' + words).slice(0, 12),
            nodes: nodes, nodeCount: map.size, textLength: text.length, focus: focus,
            storage: { local: store(globalThis.localStorage), session: store(globalThis.sessionStorage), cookies: cookies },
            requests: { total: total, recent: seen, full: total >= 250 },
            // Only to be guessed from, in the app: never handed on.
            sample: (document.title + ' ' + text.slice(0, 4000)).toLowerCase(),
            captcha: !!document.querySelector('iframe[src*=recaptcha],iframe[src*=hcaptcha],iframe[src*=turnstile],iframe[src*="challenges.cloudflare"],.g-recaptcha,.h-captcha,.cf-turnstile'),
            password: !!document.querySelector('input[type=password]') };
          if (el && el.isConnected) {
            var form = el.form || (el.closest ? el.closest('form') : null), values = '', invalid = [];
            if (form) {
              var rows = [];
              Array.prototype.forEach.call(form.elements, function (f) {
                if (!f.name || /^(submit|button|reset|image|file)$/i.test(f.type || '')) return;
                rows.push(f.name + '=' + (secret(f) ? '*' : (f.type === 'checkbox' || f.type === 'radio') ? String(f.checked) : String(f.value).slice(0, 500)));
                if (f.willValidate && !f.validity.valid && invalid.length < 10) {
                  invalid.push({ eid: eidFor(f, map), message: squash(f.validationMessage).slice(0, 120) });
                }
              });
              values = sha8(rows.sort().join('\n'));
            }
            var g = gate(el);
            out.target = { eid: eidFor(el, map), role: g.role, tag: g.tag, secret: g.secret, submits: g.submits, inForm: g.inForm,
              disabled: !!el.disabled || el.getAttribute('aria-disabled') === 'true', form: values, invalid: invalid,
              hit: probe(el, map) };
          }
          return JSON.stringify(out);
        })
        """#, [key, snap, index.map { $0 as Any } ?? NSNull()])
    }

    /// The element of the last read that an eid names now. It is put in that
    /// read's list when it wasn't in it (the page may have drawn it again),
    /// so the handle that comes of it is as good as one from a read.
    static func resolve(key: String, eid: String) -> String {
        call(#"""
        (function (key, eid) {
          var kept = globalThis[key];
          if (!kept) return JSON.stringify({ error: 'stale_element', message: 'Nothing has been read from this page yet' });
          var hits = findEid(eid);
          if (!hits.length) return JSON.stringify({ error: 'detached', message: 'Nothing on the page has that eid now' });
          if (hits.length > 1) return JSON.stringify({ error: 'ambiguous_eid', message: 'More than one element has that eid' });
          var at = kept.els.indexOf(hits[0]);
          if (at < 0) { at = kept.els.length; kept.els.push(hits[0]); }
          return JSON.stringify({ ok: true, index: at, snap: kept.snap });
        })
        """#, [key, eid])
    }

    /// Several fields set in one go, each as a person's typing would leave
    /// it to the page's own scripts: through the field's native setter, with
    /// the events a keystroke or a choice fires, so a framework that holds
    /// the value itself notices. Nothing is touched if any one of them is a
    /// secret, a file, or not a field. Reports what each holds afterwards and
    /// what the browser says is wrong with the form.
    static func fill(key: String, snap: Int, fields: [[String: Any]]) -> String {
        call(#"""
        (function (key, snap, fields) {
          function no(code, message, at) { return JSON.stringify({ error: code, message: message, field: at }); }
          var kept = globalThis[key];
          if (!kept || kept.snap !== snap) return no('stale_element', 'The page has changed since that read_page', null);
          var els = [];
          for (var n = 0; n < fields.length; n++) {
            var el = kept.els[fields[n].i];
            if (!el || !el.isConnected) return no('detached', 'That element is no longer in the page', n);
            if (el.tagName === 'INPUT' && /^file$/i.test(el.type || '')) return no('file_input', 'Choosing files is left to you', n);
            if (secret(el)) return no('secret_field', 'A password, card or one-time-code field is never filled for an agent', n);
            var ok = el.tagName === 'SELECT' || editable(el) || (el.tagName === 'INPUT' && /^(checkbox|radio)$/i.test(el.type || ''));
            if (!ok) return no('not_editable', 'That element is not something to fill', n);
            if (el.disabled || el.readOnly) return no('disabled', 'That field is disabled or read-only', n);
            els.push(el);
          }
          var map = eids(candidates()), report = [], forms = [];
          els.forEach(function (el, k) {
            var want = fields[k].value, row = { eid: eidFor(el, map), taken: true };
            el.scrollIntoView({ block: 'center', inline: 'nearest' });
            el.focus();
            if (el.tagName === 'SELECT') {
              var pick = -1;
              for (var o = 0; o < el.options.length; o++) {
                if (el.options[o].value === want || squash(el.options[o].text) === squash(want)) { pick = o; break; }
              }
              if (pick < 0) { row.taken = false; row.why = 'no_such_option'; }
              else {
                el.selectedIndex = pick;
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
              }
            } else if (/^(checkbox|radio)$/i.test(el.type || '')) {
              var yes = /^(true|1|yes|on|checked)$/i.test(String(want));
              // A click, as a person's: it is what a framework listens to.
              if (el.checked !== yes) el.click();
              row.taken = el.checked === yes;
            } else if (el.isContentEditable) {
              el.textContent = want;
              el.dispatchEvent(new InputEvent('input', { bubbles: true, data: want, inputType: 'insertText' }));
              row.taken = el.textContent === want;
            } else {
              var proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
              var setter = Object.getOwnPropertyDescriptor(proto, 'value');
              if (setter && setter.set) setter.set.call(el, want); else el.value = want;
              el.dispatchEvent(new Event('input', { bubbles: true }));
              el.dispatchEvent(new Event('change', { bubbles: true }));
              row.taken = el.value === want;
              // What a field that bounced it holds is the page's to say, and
              // a field that is not a secret is not secret.
              if (!row.taken) row.holds = String(el.value).slice(0, 200);
            }
            var f = el.form || (el.closest ? el.closest('form') : null);
            if (f && forms.indexOf(f) < 0) forms.push(f);
            report.push(row);
          });
          // Asked, not shown: nothing is drawn on the page.
          var invalid = [];
          forms.forEach(function (f) {
            Array.prototype.forEach.call(f.elements, function (c) {
              if (c.willValidate && !c.validity.valid && invalid.length < 20) {
                invalid.push({ eid: eidFor(c, map), message: squash(c.validationMessage).slice(0, 120) });
              }
            });
          });
          report.forEach(function (row, k) {
            row.valid = !invalid.some(function (v) { return v.eid === row.eid; });
          });
          return JSON.stringify({ ok: true, fields: report, invalid: invalid });
        })
        """#, [key, snap, fields])
    }
}
