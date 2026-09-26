Templates for `config.demo.json`. Relative template names in a config are looked
up in a `templates` folder next to the config file.

Templates are Markdown: `#`/`##`/`###` headings, `-` bullets (a bare `-` is an
empty one to fill in), `1.` numbered lists, `**bold**`, `*italic*` and
`[links](https://…)`. `{{placeholders}}` are filled in first. If the first line
is a `#` heading and the action sets no title, that line becomes the note's title.
