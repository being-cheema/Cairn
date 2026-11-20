# Security

Cairn handles your passwords, your history and every page you open, so a
hole in it matters more than most bugs. If you find one, please tell us
privately first.

## How to report

Report it on GitHub: this repository's **Security** tab › **Report a
vulnerability**. Only the maintainer sees it. If the hole is in code that
comes from the upstream project, [Search](https://github.com/driceroland/Search),
tell them too, through their own Security tab: this fork does not speak for
them. Say what you found, where in the code, and how to see it happen. A proof of concept
that stays on your own machine is welcome; please don't try it on other
people's accounts or data.

Please don't open a public issue or pull request that describes the problem
until a fixed version is out. A pull request that only fixes it, without
spelling out the attack, is fine.

## What happens next

- You get an answer from the person who maintains Cairn, not a form.
- The fix goes into the next version. A copy of Cairn that was built with an
  update feed picks it up on its own; one built without a feed has to be
  built again.
- Once it is out, you're thanked by name in the changelog, unless you'd
  rather not be.

## What counts

Anything that lets a web page, an extension, another app or someone on the
network do more than they should: read files, passwords, cookies or
history, get around a permission, open another app without asking, or
change the app itself. Cairn's own update, its keychain items, its
extensions layer and `./bench` are all in scope.

A site that doesn't work, or an extension that behaves differently from
Chrome, is a bug rather than a security problem: open an
issue in this repository for those.
