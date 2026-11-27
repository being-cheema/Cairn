import Foundation

// What kind of page this is, in a few typed fields, and one part of a page
// at full size.
//
// A read of a whole page is long; most of the time an agent needs to know
// "this is a login form, here are its fields" or "ten results, here are
// their links". The classification is structural and a guess (confidence
// says how sure, signals say why), and every word in it is the page's: it
// goes through Quarantine like the rest of a read. Never a secret's value.

extension PageScripts {
    /// The page's archetype and its typed fields, as the page script sees
    /// them. Fields are cut to what a budget will take afterwards
    /// (ArchetypeBudget); here only to a sane size.
    static func archetype() -> String {
        call(#"""
        (function () {
          var map = eids(candidates()), signals = [];
          function eidOfFirst(sel) { var el = document.querySelector(sel); return el && map.has(el) ? map.get(el) : null; }
          function text(el) { return squash(el && (el.innerText || el.textContent)).slice(0, 120); }
          var body = document.body ? document.body.innerText : '';
          var lower = (document.title + ' ' + body.slice(0, 6000)).toLowerCase();
          var visibleEls = Array.prototype.filter.call(document.querySelectorAll('input:not([type=hidden]),select,textarea'), visible);
          function field(el) {
            var f = { eid: eidFor(el, map), role: role(el), name: name(el).slice(0, 60) };
            if (secret(el)) f.secret = true;
            return f;
          }
          function submitOf(root) {
            var b = (root || document).querySelector('button[type=submit],input[type=submit],button:not([type])');
            return b && visible(b) ? { eid: eidFor(b, map), name: name(b).slice(0, 60) } : null;
          }
          var ld = [];
          Array.prototype.forEach.call(document.querySelectorAll('script[type="application/ld+json"]'), function (s) {
            try { var j = JSON.parse(s.textContent); (Array.isArray(j) ? j : j['@graph'] || [j]).forEach(function (x) { if (x && x['@type']) ld.push(x); }); } catch (e) {}
          });
          function ldType(re) { return ld.filter(function (x) { return re.test(String(x['@type'])); })[0]; }
          var og = (document.querySelector('meta[property="og:type"]') || {}).content || '';
          var out = null;
          if (document.querySelector('iframe[src*=recaptcha],iframe[src*=hcaptcha],iframe[src*=turnstile],.g-recaptcha,.h-captcha,.cf-turnstile') ||
              /verify you are human|are you a robot|unusual traffic from your/.test(lower)) {
            out = { type: 'captcha', confidence: 'medium', signals: ['captcha widget or wording'], fields: {} };
          } else if (/subscribe to (continue|read|unlock)|you.ve reached your (free|monthly)|unlock this (article|story)/.test(lower)) {
            out = { type: 'paywall', confidence: 'low', signals: ['subscription wording'], fields: {} };
          } else if (visibleEls.some(function (e) { return e.type === 'password'; }) && visibleEls.length <= 6) {
            out = { type: 'login', confidence: 'high', signals: ['password field in a small form'],
              fields: { fields: visibleEls.slice(0, 6).map(field), submit: submitOf(visibleEls[0].form) } };
          } else if (visibleEls.some(function (e) { return /(^|\s)cc-/.test((e.getAttribute('autocomplete') || '').toLowerCase()); })) {
            out = { type: 'checkout', confidence: 'high', signals: ['card fields'],
              fields: { fields: visibleEls.slice(0, 12).map(field), submit: submitOf(visibleEls[0].form) } };
          } else if (ldType(/Product/) || og === 'product' || (document.querySelector('[itemprop=price],[class*=price]') && /add to (cart|bag|basket)|buy now/.test(lower))) {
            var p = ldType(/Product/) || {}, offer = [].concat(p.offers || [])[0] || {};
            var price = offer.price || text(document.querySelector('[itemprop=price],[class*=price]'));
            out = { type: 'product', confidence: p['@type'] ? 'high' : 'medium', signals: [p['@type'] ? 'JSON-LD Product' : 'price and a buy button'],
              fields: { name: squash(p.name || (document.querySelector('h1') || {}).innerText), price: String(price || '').slice(0, 40),
                currency: String(offer.priceCurrency || '').slice(0, 8), availability: String(offer.availability || '').split('/').pop(),
                buy: (function () { var b = Array.prototype.filter.call(document.querySelectorAll('button,input[type=submit],a'), function (x) {
                  return visible(x) && /add to (cart|bag|basket)|buy now/i.test(name(x)); })[0]; return b ? { eid: eidFor(b, map), name: name(b).slice(0, 60) } : null; })() } };
          } else if (document.querySelector('[role=search] input,input[type=search]') && /[?&](q|query|search|s|k)=/.test(location.search)
                     && document.querySelectorAll('main li a[href],main article a[href],[role=list] a[href],ol li a[href]').length >= 5) {
            var links = Array.prototype.filter.call(document.querySelectorAll('main li a[href],main article a[href],ol li a[href],[role=list] a[href]'), visible);
            var seen = {}, results = [];
            links.forEach(function (a) { if (map.has(a) && !seen[a.href] && name(a).length > 3) { seen[a.href] = 1; results.push({ eid: map.get(a), title: name(a).slice(0, 100), href: a.origin + a.pathname }); } });
            out = { type: 'search_results', confidence: 'medium', signals: ['search box, a query in the address and a list of links'],
              fields: { query: (new URLSearchParams(location.search).get('q') || new URLSearchParams(location.search).get('query') || '').slice(0, 100), count: results.length, results: results.slice(0, 20) } };
          } else if (ldType(/Article|NewsArticle|BlogPosting/) || og === 'article' || (document.querySelector('article') && body.length > 1500 && document.querySelector('h1'))) {
            var a = ldType(/Article|NewsArticle|BlogPosting/) || {}, para = document.querySelector('article p, main p');
            out = { type: 'article', confidence: a['@type'] || og === 'article' ? 'high' : 'medium', signals: ['article markup and a long text'],
              fields: { headline: squash(a.headline || (document.querySelector('h1') || {}).innerText), published: String(a.datePublished || '').slice(0, 30),
                words: body.split(/\s+/).length, lead: text(para).slice(0, 200) } };
          } else if (/\b(404|not found|page not found|forbidden|access denied|something went wrong|server error|bad gateway)\b/.test(lower.slice(0, 400))) {
            out = { type: 'error', confidence: 'low', signals: ['error wording near the top'], fields: { heading: text(document.querySelector('h1')) } };
          }
          return JSON.stringify({ archetype: out });
        })
        """#, [])
    }

    /// One part of a page at full size: the container round a control (its
    /// row, card, form or landmark), as text and as the controls inside it.
    static func zoom(key: String, eid: String, chars: Int) -> String {
        call(#"""
        (function (key, eid, chars) {
          var hits = findEid(eid);
          if (!hits.length) return JSON.stringify({ error: 'detached', message: 'Nothing on the page has that eid now' });
          var el = hits[0], map = eids(candidates()), box = up(el);
          while (box && !(box.matches && box.matches(CARD + ',main,nav,header,footer,aside,[role=main],[role=navigation],[role=dialog],table'))) box = up(box);
          if (!box) box = el.parentElement || el;
          var text = String(box.innerText || box.textContent || '');
          var controls = [];
          Array.prototype.forEach.call(box.querySelectorAll(SEL), function (c) {
            if (controls.length >= 60 || !map.has(c)) return;
            var n = { eid: map.get(c), role: role(c), name: name(c).slice(0, 80) };
            if (/^(INPUT|TEXTAREA|SELECT)$/.test(c.tagName) && !/^(submit|button|reset|image|checkbox|radio)$/i.test(c.type || '')) {
              if (secret(c)) n.redacted = true; else n.value = String(c.value).slice(0, 200);
            }
            if (c.tagName === 'A' && c.href) n.href = String(c.href).slice(0, 200);
            controls.push(n);
          });
          return JSON.stringify({ ok: true, container: { eid: eidFor(box, map), tag: box.tagName.toLowerCase(), role: role(box) },
            textLength: text.length, text: text.slice(0, chars), truncated: text.length > chars, controls: controls });
        })
        """#, [key, eid, chars])
    }
}

/// A typed summary held to a budget (about four characters to a token): the
/// longest lists are cut first, then the fields of what is left.
enum ArchetypeBudget {
    static func tokens(_ value: Any) -> Int {
        guard JSONSerialization.isValidJSONObject(["v": value]),
              let data = try? JSONSerialization.data(withJSONObject: ["v": value]) else { return 0 }
        return (data.count + 3) / 4
    }

    static func fit(_ summary: [String: Any], tokens budget: Int) -> [String: Any] {
        var out = summary
        guard tokens(out) > budget else { return out }
        out["truncated"] = true
        var fields = out["fields"] as? [String: Any] ?? [:]
        // The longest list again and again, halved, until it fits.
        while tokens(out) > budget {
            let lists = fields.filter { ($0.value as? [Any])?.isEmpty == false }
            guard let longest = lists.max(by: { ($0.value as? [Any])?.count ?? 0 < ($1.value as? [Any])?.count ?? 0 }),
                  let list = longest.value as? [Any], list.count > 1 else { break }
            fields[longest.key] = Array(list.prefix(list.count / 2))
            out["fields"] = fields
        }
        // Still too long: the words themselves, cut.
        while tokens(out) > budget {
            var cut = false
            for (key, value) in fields {
                if let text = value as? String, text.count > 40 { fields[key] = String(text.prefix(text.count / 2)) + "…"; cut = true }
            }
            out["fields"] = fields
            if !cut { break }
        }
        if tokens(out) > budget { out["fields"] = [:] as [String: Any] }
        return out
    }
}
