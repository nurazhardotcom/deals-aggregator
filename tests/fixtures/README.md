# Parser fixtures

These files feed the offline FiveAM suites in `deal-aggregator/tests`. They never touch the production `data/` directory and no test performs network access; HTTP is stubbed via `*http-get*` and time via `*clock*`.

| File | Source | Item dates | Notes |
| --- | --- | --- | --- |
| `v2ex-public-sample.xml` | `https://www.v2ex.com/feed/promotions.xml` (Atom) | item carries `2026-11-08T05:08:49Z` | single promotion entry; original link and `#reply0` kept for canonicalisation tests; no accounts or tracking parameters |
| `linuxdo-public-sample.md` | `https://r.jina.ai/https://linux.do/c/welfare/36.rss` (Markdown) | item dates `2026-11-08` | Jina list shape; no body text, summary stays empty |
| `appinn-public-sample.xml` | `https://www.appinn.com/feed/` (RSS 2.0) | unrecorded (first added 2026-11-08) | keeps title, link, date, short description; full `<content:encoded>` body trimmed |
| `iplaysoft-public-sample.xml` | `https://www.iplaysoft.com/feed` (RSS 2.0) | unrecorded (first added 2026-11-08) | single entry with title, link, description; no account data |
| `epic-public-sample.json` | Epic `freeGamesPromotions` endpoint | unrecorded (first added 2026-11-08) | keeps product and promotion field shapes for the current free-window check |

## Conventions

- Never invent capture times. Samples without a capture moment say unrecorded; item publish time is not sample capture time.
- Samples hold no accounts, mailboxes, cookies, headers, or credentials; original links stay for dedup and canonicalisation tests.
- Publicly reachable does not mean freely redistributable. Check a source's terms before adding samples; prefer synthetic variants when the same parse shape can be expressed without third-party prose.
- After changing a sample, rerun `(asdf:test-system "deal-aggregator")`: parse assertions match sample contents exactly.

`linuxdo-synthetic-variants.md` is synthetic: heading levels, single-digit dates, and implausible future dates, not real captures.
