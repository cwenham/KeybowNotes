{{#each clipboard where="Paid = no" sort="Due"}}
{{#header}}
| Invoice | Client | Due | Amount |
|---|---|---|--:|
{{/header}}
| {{Invoice}} | {{Client}} | {{Due}} | {{Amount}} |
{{#footer}}

{{@count}} unpaid, £{{@sum.Amount}} in all.
{{/footer}}
{{#empty}}
Everything's paid.
{{/empty}}
{{/each}}
