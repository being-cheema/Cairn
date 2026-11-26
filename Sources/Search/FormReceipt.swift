import SwiftUI

// What a form held for your click holds, shown on the question.
//
// It is a help to reading the form, not a copy of what leaves: what a page
// sends with fetch or XHR isn't a form and isn't here, hidden and secret
// fields are left out, and a page can change a value after the card is
// drawn. What is shown is compared again before anything is pressed
// (AgentControl): a field that changed meanwhile means nothing is pressed.
// It never changes what needs a click (AgentGate does not look at it), and
// it is shown to you alone: no answer to the agent and no task record has it.
//
// Two layers keep secrets off it. In the page, a field ever seen as secret
// (the shared set PageScripts keeps), a password, a card, a one-time code
// and anything hidden or not drawn is never read out. Here, a value whose
// field is named like a secret, or that is shaped like one (TypedSecrets),
// is shown as hidden.

struct FormReceipt: Equatable {
    struct Row: Equatable {
        let label: String
        let value: String
    }

    var rows: [Row] = []
    /// Fields left out: hidden, secret, or not drawn.
    var withheld = 0
    /// Fields past the most that are listed.
    var more = 0
    /// Of everything the page read out, whole, so a change anywhere in it is
    /// seen even where the card shows less. Kept for comparing only.
    private var mark = 0

    static let mostRows = 30, longestLabel = 60, longestValue = 200

    /// The same fields holding the same things. Hidden fields aren't
    /// compared: a token that renews itself would stop every send.
    static func == (a: FormReceipt, b: FormReceipt) -> Bool { a.mark == b.mark }

    /// From PageScripts' `receipt`; nil when there is no form.
    init?(_ json: Any?) {
        guard let d = json as? [String: Any], let list = d["rows"] as? [[String: Any]] else { return nil }
        withheld = d["withheld"] as? Int ?? 0
        more = d["more"] as? Int ?? 0
        var hasher = Hasher()
        hasher.combine(more)
        hasher.combine(d["rest"] as? Int ?? 0)
        for (at, field) in list.enumerated() {
            let label = field["label"] as? String ?? ""
            let name = field["name"] as? String ?? ""
            let value = field["value"] as? String ?? ""
            hasher.combine(label)
            hasher.combine(name)
            hasher.combine(value)
            hasher.combine(field["hash"] as? Int ?? 0)
            guard at < Self.mostRows else { more += 1; continue }
            rows.append(Row(label: Self.line(label.isEmpty ? name : label, Self.longestLabel),
                            value: Self.shown(value, label: label, name: name,
                                              length: field["length"] as? Int ?? value.count)))
        }
        mark = hasher.finalize()
    }

    // MARK: - what may be shown

    /// A field named like this keeps its value to itself. Wrong the safe
    /// way; the everyday "…code" fields are let through.
    private static let secretNames =
        #"pass|pwd|secret|token|api.?key|private.?key|\bssn\b|social.?sec|national.?insurance|\biban\b|routing|sort.?code|account.?(no|num)|passport|licen[cs]e.?(no|num)|\bpin\b|\botp\b|cvc|cvv|(?<!zip )(?<!zip_)(?<!zip-)(?<!post )(?<!postal )(?<!postal_)(?<!postal-)(?<!promo )(?<!promo_)(?<!promo-)(?<!coupon )(?<!country )(?<!country_)(?<!area )(?<!discount )\bcode\b"#

    static func looksSecret(_ value: String, label: String, name: String) -> Bool {
        guard !value.isEmpty else { return false }
        let said = (label + " " + name).replacingOccurrences(of: "_", with: " ")
        if said.range(of: secretNames, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        if TypedSecrets.hidden(in: value) != value { return true }
        // A long unbroken run of letters and digits is a key more often
        // than anything you would want to check by eye.
        return value.range(of: #"^(?=[^\s]*\d)(?=[^\s]*[A-Za-z])[A-Za-z0-9+=_\-]{32,}$"#, options: .regularExpression) != nil
    }

    private static func shown(_ value: String, label: String, name: String, length: Int) -> String {
        if looksSecret(value, label: label, name: name) { return TypedSecrets.mark }
        if value.isEmpty { return "(empty)" }
        let cut = line(value, longestValue)
        // Said, so a long value isn't taken for all of it.
        return length > longestValue ? "\(cut) (\(length) characters)" : cut
    }

    /// One printable line, cut short. Direction marks go too: with them a
    /// value can be drawn as something it isn't.
    private static func line(_ text: String, _ most: Int) -> String {
        let plain = text.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) || $0.properties.isBidiControl ? " " : String($0)
        }.joined()
        let squashed = plain.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return squashed.count > most ? String(squashed.prefix(most)) + "…" : squashed
    }

    // MARK: - said under the table

    /// What the table is not. `after` is for a send already on its way when
    /// it was read.
    func footnote(after: Bool) -> String {
        var parts = [after
            ? "Read from the page once it had begun sending, so it may not be what is sent."
            : "Read from the form when you were asked. If a field listed changes before you approve, nothing is pressed; the page can still change what it sends."]
        if more > 0 { parts.append("\(more) more \(more == 1 ? "field is" : "fields are") not listed.") }
        if withheld > 0 { parts.append("\(withheld) hidden or secret \(withheld == 1 ? "field is" : "fields are") left out.") }
        parts.append("This isn't the whole request: what a page sends in the background isn't shown.")
        return parts.joined(separator: " ")
    }

    // MARK: - in the page

    /// Joined to PageScripts' helpers, whose `secret`, `visible` and `name`
    /// it uses.
    static let script = #"""
    // A form's fields, for the person's card (FormReceipt). Never one that
    // is secret, hidden or not drawn: those are only counted. The browser's
    // own getters are used, as a field named "elements" or "action" would
    // otherwise stand in for the form's.
    function formProperty(form, key) {
      return Object.getOwnPropertyDescriptor(HTMLFormElement.prototype, key).get.call(form);
    }
    function fieldHash(text) {
      var h = 0;
      for (var i = 0; i < text.length; i++) h = (h * 31 + text.charCodeAt(i)) | 0;
      return h;
    }
    function receiptOf(form) {
      var fields = formProperty(form, 'elements'), rows = [], withheld = 0, more = 0, rest = 0;
      for (var i = 0; i < fields.length; i++) {
        var f = fields[i], tag = f.tagName;
        if (!/^(INPUT|SELECT|TEXTAREA)$/.test(tag) || f.matches(':disabled')) continue;
        var type = tag === 'INPUT' ? (f.type || 'text').toLowerCase() : '';
        if (/^(submit|button|reset|image)$/.test(type)) continue;
        // Not sent at all.
        if (/^(checkbox|radio)$/.test(type) && !f.checked) continue;
        var ac = (f.getAttribute('autocomplete') || '').toLowerCase();
        if (type === 'hidden' || type === 'password' || secret(f) ||
            /(^|\s)(cc-|one-time-code|current-password|new-password)/.test(ac) || !visible(f)) { withheld++; continue; }
        var value;
        if (type === 'checkbox' || type === 'radio') value = f.value && f.value !== 'on' ? 'ticked: ' + f.value : 'ticked';
        else if (type === 'file') { if (!f.files || !f.files.length) continue; value = f.files.length + ' chosen'; }
        else if (tag === 'SELECT') value = Array.prototype.map.call(f.selectedOptions, function (o) { return o.text; }).join(', ');
        else value = String(f.value);
        var row = { label: name(f), name: String(f.getAttribute('name') || f.id || '').slice(0, 80),
                    value: value.slice(0, 2000), length: value.length, hash: fieldHash(value) };
        if (rows.length < 100) rows.push(row);
        else { more++; rest = (rest * 31 + fieldHash(row.label + '=' + value)) | 0; }
      }
      return { rows: rows, withheld: withheld, more: more, rest: rest };
    }
    function receipt(el) {
      var form = el.form || (el.closest ? el.closest('form') : null);
      return form instanceof HTMLFormElement ? receiptOf(form) : null;
    }

    """#
}

/// The two columns on the question: what each listed field holds. Plain
/// words only; they are the page's.
struct FormReceiptTable: View {
    let receipt: FormReceipt
    let after: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !receipt.rows.isEmpty {
                ViewThatFits(in: .vertical) {
                    grid
                    ScrollView { grid }
                }
                .frame(maxHeight: 160)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Text(verbatim: receipt.footnote(after: after))
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var grid: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(Array(receipt.rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(verbatim: row.label).foregroundStyle(Palette.muted).frame(maxWidth: 130, alignment: .leading)
                    Text(verbatim: row.value).foregroundStyle(Palette.ink).frame(maxWidth: .infinity, alignment: .leading)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 11))
    }
}
