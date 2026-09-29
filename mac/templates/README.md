Templates for `tree.demo.md`. Relative template names in a tree are looked up
in a `templates` folder next to the tree's file.

Templates are Markdown: `#`/`##`/`###` headings, `-` bullets (a bare `-` is an
empty one to fill in), `1.` numbered lists, `**bold**`, `*italic*` and
`[links](https://…)`. `{{placeholders}}` are filled in first. If the first line
is a `#` heading and the action sets no title, that line becomes the note's title.
