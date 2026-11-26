# Local/

Things that live on the owner's Mac only. Nothing in here but this file is
ever committed.

## Art/

Pictures for the app's quiet places (an empty list, a welcome, a held action),
from icons8 in the Anthropic Claude Hand Drawn and Watercolor styles. They are
not MIT. The files stay in `Local/Art/` and are never committed. A built app may
carry them with a link to icons8.com in its About section, as icons8's licence
page asks of free use in desktop apps; Settings › About shows it whenever the
app has pictures, and `./build.sh release dmg` and `ship` check it is there.
Without them the app draws a plain shape instead and is otherwise the same.
