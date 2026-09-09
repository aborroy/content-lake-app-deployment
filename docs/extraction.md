# Text Extraction and the `transform-extras` Profile

How binary documents become text, why that decides whether tables survive retrieval, and how to turn
on structure-aware extraction. Applies to every content source: Alfresco, Nuxeo and filesystem.

## Why this matters

Chunking is structure-aware. It splits on heading boundaries, keeps a detected table atomic instead of
hard-splitting it mid-row, exempts table regions from noise-reduction cleanup, and marks the resulting
chunk `ChunkType.TABLE` so clients can render it distinctly.

All of that depends on the text carrying structure in the first place. A table is detected by a
markdown separator row (`| --- | --- |`) or by rows holding at least two `|` characters. Fixed-width
columns drawn with dash rules are not detected, deliberately: over-detecting would wrongly exempt
ordinary prose from cleanup.

The consequence is that **plaintext extraction removes exactly the signal table detection needs**. A
PDF whose table is extracted as flattened text arrives as an undelimited run of words, is chunked on
character counts, and is classified `PROSE`. Nothing errors; the structure is simply gone before
chunking sees it.

## What each format does today

| Source content | Path | Structure preserved |
|---|---|---|
| `.md` (`text/markdown`) | read directly, no extractor involved | Yes, headings and tables |
| `.txt` and other `text/*` | read directly, no extractor involved | Only if the text already has pipe tables |
| PDF, DOCX, XLSX via `transform-core-aio` | `POST /transform` to `text/plain` | No |
| PDF, DOCX via `liteparse` | `POST /transform` to `text/markdown` | Headings only, **not** tables |
| XLSX, XLS via `liteparse` | `POST /transform` to `text/markdown` | Yes, headings and tables (liteparse 1.1.0+) |
| PDF via `convert2md` | `POST /transform` to `text/markdown` | Yes, headings and tables |
| Anything, Nuxeo ConversionService | `@convert?type=text/plain` | No |
| Anything, in-process Tika | Tika `BodyContentHandler` | No |

Two things follow from the first row and are worth knowing before deploying anything:

- **Markdown source documents already get the full treatment, with no transform engine at all.**
  `text/markdown` is read straight through, so a `.md` file's headings and pipe tables reach chunking
  intact and produce `ChunkType.TABLE` chunks on any profile, including a plain `make up-alfresco`.
  If your content is already markdown, there is nothing to install.
- **Plain text behaves exactly as it always has.** A `.txt` file is passed through unchanged.

## Plain text is the default, and needs nothing installed

**You do not need `transform-extras`, or markdown, to use this project.** `EXTRACTION_FORMAT` defaults
to `plaintext`, and on that setting:

- No engine is ever asked for markdown, even if the engine in front of it can produce it.
- Alfresco keeps using the `transform-core-aio` already in the stack.
- Nuxeo keeps using its own ConversionService; the filesystem connector keeps using in-process Tika.
  Neither has an engine configured by default, and neither needs one.
- Chunk boundaries, both fulltext mirrors and the resulting embeddings are byte-identical to a
  deployment predating any of this.

So a plain `make up-alfresco`, `make up-nuxeo` or `make up-demo` is a complete, supported
configuration. Everything below is opt-in, and the sections on engines only apply once you set
`EXTRACTION_FORMAT` to `auto` or `markdown`.

If you want better *plain text* rather than markdown, that is also available without changing the
format: `liteparse` advertises a `text/plain` target too, so pointing an engine URL at it while leaving
`EXTRACTION_FORMAT=plaintext` uses its extraction quality with no markdown involved.

## Configuration

Three knobs, all with defaults that reproduce previous behaviour exactly.

| Variable | Default | Applies to | Meaning |
|---|---|---|---|
| `EXTRACTION_FORMAT` | `plaintext` | all ingesters | `plaintext`, `auto` or `markdown` |
| `TRANSFORM_URL` | `http://transform-core-aio:8090` | Alfresco ingesters | engine base URL |
| `EXTRACTION_ENGINE_URLS` | empty | all ingesters | comma-separated list of extraction services, most structural first. Empty means none |
| `EXTRACTION_ENGINE_TIMEOUT_MS` | `300000` | Nuxeo and filesystem ingesters | read timeout. Raise it for `convert2md`, which needs tens of seconds per PDF |

`EXTRACTION_FORMAT` values:

- `plaintext` asks the engine for `text/plain`. **This is the default and needs no extra
  infrastructure**; chunk boundaries, both fulltext mirrors and the resulting embeddings are
  byte-identical to a deployment without any of this. Markdown is never requested, and the engine is
  not even asked whether it could produce it.
- `auto` asks for `text/markdown` where the engine advertises that transform, and `text/plain`
  everywhere else.
- `markdown` behaves like `auto` and additionally logs each fall back to plaintext. Use it when
  markdown is the point of the deployment: the log line is the only way to distinguish "the engine is
  not producing markdown" from "markdown is working".

Target selection is discovered, not configured. The ingester reads the engine's own
`GET /transform/config` and asks for markdown only when the engine advertises it for that MIME type,
so there is no routing table to keep in step with which engines are deployed. Setting
`EXTRACTION_FORMAT=auto` against the official `transform-core-aio` is therefore a no-op: it advertises
no markdown target.

## Turning it on

The `transform-extras` profile adds two engines: `transform-liteparse` (PDF and all Office formats,
fast, headings only) and `transform-convert2md` (PDF only, slow, recovers real markdown tables). Read
"Which engine" below before choosing, because only one of them actually preserves tables.

```bash
# Alfresco, headings only (fast)
EXTRACTION_FORMAT=auto TRANSFORM_URL=http://transform-liteparse:8090 \
  docker compose --profile alfresco --profile transform-extras up -d

# Alfresco, headings and tables (slow, PDF only -- see "Which engine" below)
EXTRACTION_FORMAT=auto TRANSFORM_URL=http://transform-convert2md:8090 \
  docker compose --profile alfresco --profile transform-extras up -d

# Nuxeo
EXTRACTION_FORMAT=auto EXTRACTION_ENGINE_URL=http://transform-liteparse:8090 \
  docker compose --profile nuxeo --profile transform-extras up -d

# Filesystem connector
EXTRACTION_FORMAT=auto EXTRACTION_ENGINE_URL=http://transform-liteparse:8090 \
  docker compose --profile alfresco --profile filesystem --profile transform-extras up -d
```

The profile on its own changes nothing: without `EXTRACTION_FORMAT` and a URL pointing at the engine,
the ingesters keep asking their existing engine for plaintext.

Re-ingest is required for existing documents. Extraction happens at ingest, so changing the format
affects newly synced content only.

Verify the profile stays optional with `make verify-profiles`, which asserts neither engine appears in
any base profile and that `--profile transform-extras` does add them.

## Running several engines at once

No single engine covers every format well, so `EXTRACTION_ENGINE_URLS` takes a list. Measured on the
eval fixtures, this combination gives tables from both PDFs and spreadsheets:

```bash
EXTRACTION_FORMAT=auto \
EXTRACTION_ENGINE_URLS="transform:http://transform-convert2md:8090,transform:http://transform-liteparse:8090" \
EXTRACTION_ENGINE_TIMEOUT_MS=600000 \
  docker compose --profile alfresco --profile transform-extras up -d
```

**Nothing routes by MIME type in configuration.** Each service is asked what it supports via its own
`GET /transform/config` and claims only that, so the list routes itself: with the above, convert2md took
all four PDF fixtures and liteparse took the DOCX and XLSX, with no rule written anywhere. Order matters
only where two services overlap, and it breaks the tie in favour of the earlier entry, so **list them
most structural first**. Reverse the two above and liteparse claims the PDFs, yielding headings but no
tables.

For the Alfresco ingesters these are tried *before* `TRANSFORM_URL`, so the repository's own transform
service remains the last engine before Tika. Every chain ends at in-process Tika.

### Adding a different kind of extraction service

An entry may carry a backend-kind prefix, so the list is not limited to the
`alfresco-transform-core` protocol:

```
EXTRACTION_ENGINE_URLS="transform:http://transform-liteparse:8090,docfilters:http://docfilters:8080"
```

An unprefixed entry means `transform`, so existing configuration is unaffected. A URL's own scheme is
never mistaken for a kind. Supporting a new kind means implementing `ExtractionBackend` in
`content-lake-core` and exposing it as a bean; the chain, the pipeline and the `TextExtractor` SPI are
untouched. An unknown kind is skipped with a warning rather than failing startup, so one bad entry
cannot stop an ingester.

## Operational notes

- **Nothing here can fail an ingest.** Extraction runs as a chain: engine first, then the
  source-specific extractor where one exists, then in-process Tika. An absent engine, a connection
  reset, a read timeout, a 500 and a `No transforms for:` 400 all fall through to the next entry with
  a warning. Only when every extractor produces nothing is the document recorded as an extraction
  failure, and the sync itself still completes.
- **Allow for a slow first call.** Each engine pays one-off initialisation on its first transform after
  container start, and `convert2md` loads a layout model, so its healthcheck allows 120 seconds against
  liteparse's 60. A cold start read as a hang leads to the engine being blamed for a timeout it did not
  cause. `EXTRACTION_ENGINE_TIMEOUT_MS` defaults to 300000 for the same reason; `convert2md` needs tens
  of seconds per PDF even warm, so do not lower it.
- **Port 8090 is not published.** Both engines are reachable only inside the stack network, matching
  `transform-core-aio`, which also publishes nothing. Do not expose it: engines transform arbitrary
  uploads with no authentication of their own.
- **The `/test` browser form stays disabled.** `TEST_ENDPOINT_ENABLED` is deliberately absent from the
  service definition. It is disabled by default in `alfresco-transform-core` 5.4.1 and must remain so
  outside local development.
- **Sizing.** `liteparse` is roughly 370 MB on disk and used 485 MB running; `convert2md` is 2.59 GB
  on disk and used 310 MB running. Neither needs a GPU, so they do not contend with the AI inference
  stack on port 12434. Both are in the profile, so enabling it pulls about 3 GB of images.
- **Both tags are pinned to `1.1.0`.** `TRANSFORM_EXTRAS_TAG` and `TRANSFORM_CONVERT2MD_TAG` both
  default to that release, so the two engines come from one upstream source tree and a run is
  reproducible. liteparse `:latest` predates the spreadsheet fix, so moving back to it silently loses
  spreadsheet columns.

## Which engine, and what each one actually recovers

The profile ships two engines from
[`alfresco-transform-extras`](https://github.com/aborroy/alfresco-transform-extras). They are not
interchangeable, and the difference is not what their advertised `text/markdown` target suggests.

**Measured on the eval fixtures, not inferred.** Both engines advertise a `text/markdown` target for
PDF; only one of them recovers tables in it.

| | `liteparse` | `convert2md` |
|---|---|---|
| Markdown headings | yes | yes |
| Markdown **tables**, spreadsheets | yes, after the fix below | n/a, PDF only |
| Markdown **tables**, PDF and DOCX | **no** | **yes** |
| Warm latency, 2-page PDF | 310-650 ms | ~20.5 s |
| Memory in use | 485 MB | 310 MB |
| Image size | 0.37 GB | 2.59 GB |
| Formats | PDF, DOCX, XLSX, PPTX, DOC | PDF only |

`liteparse` returns `## Page 1` headings and then space-padded fixed-width columns, which is precisely
the shape table detection rejects, so it does not move the TABLE rate for PDF or DOCX. `convert2md`
returns correctly aligned pipe tables whose separator-row count matched the source table count exactly,
with every column and value preserved.

Spreadsheets are now the exception. The published `liteparse` image at the time of measurement lost
columns on an XLSX (two of five survived) because it reached the sheet through a page render. That is
fixed upstream: spreadsheets are read cell by cell with Apache POI, so every column survives and the
grid becomes a real Markdown table. Re-measured on the same fixture, 46 pipe rows and 6 separator rows
against the source's 6 tables, verified against the published `angelborroy/alf-tengine-liteparse:1.1.0`
image rather than a local build. `TRANSFORM_EXTRAS_TAG` now defaults to `1.1.0` for that reason. Do not
drop back to `:latest`, which still carries the column-dropping behaviour.

So choose by what the corpus needs:

- **`liteparse` is the default.** Better section segmentation for effectively no cost on every format,
  plus real tables for spreadsheets.
- **`convert2md` when tables are the point.** ~65x the latency and PDF only, so it suits a table-heavy
  corpus where ingest time is acceptable. Note that ingest throughput, not memory, is the constraint:
  it used less RAM than liteparse on these files, and the 4 GB figure in upstream's README was not
  observed.
- **Both together is the best coverage**, and is what the list form is for. Measured on the eval
  fixtures, the pair took the corpus from 0 TABLE chunks to 30, covering three of four table-bearing
  documents. Only DOCX remains uncovered: liteparse recovers no DOCX tables and convert2md is PDF-only.

Point `TRANSFORM_URL` (Alfresco) or `EXTRACTION_ENGINE_URL` (Nuxeo, filesystem) at
`http://transform-convert2md:8090` to use it. Target selection is discovered per MIME type, so an
engine is simply never asked for a transform it does not advertise.

Other engines upstream packages and this profile does not (`html2md`, `ocr`, `whisper`, `ai`, `pii`)
attach by the same mechanism: run the container, point the URL at it.

**If you need markdown tables without the latency**, the alternative is teaching table detection to
recognise aligned fixed-width columns, which would make `liteparse` output and plain text files work
too. That is deliberately not done today: the current pipe rule is conservative because
over-detecting a table exempts ordinary prose from noise-reduction cleanup.

## Where the text ends up

Chunks and the keyword index deliberately hold different representations.

| Destination | Holds | Why |
|---|---|---|
| Chunks and their embeddings | the extracted representation as-is, markdown included | chunking segments on heading and table boundaries and classifies tables |
| `cin_ingestProperties.contentLake_extractedText` | markup-stripped plain text | hxpr folds it into the analysed `sys_fulltext` index that the lexical leg of hybrid search queries |
| `sys_fulltextBinary` | markup-stripped plain text | same content, though hxpr does not expose this field to HXQL |

Markdown punctuation is not a term anyone searches for, so leaving it in the keyword mirror would
dilute the term frequencies of the words that are. Table cells become space-separated values on one
line, which is what the flattened paths already produce, so keyword behaviour is the same whichever
path fed the document.

## Verifying it worked

`content-lake-eval` reports how chunks were actually classified:

```bash
cd ../content-lake-eval
uv run cleval chunktypes --config config/baseline.yaml
uv run cleval chunktypes --config config/tables.yaml --only-tabular
```

`config/tables.yaml` is an arm of the eval corpus in which four table-bearing documents are PDF, DOCX
and XLSX rather than plain text, so it exercises a real extraction path. A zero TABLE count there
means the engine is not being reached or is still returning plaintext; check `EXTRACTION_FORMAT` first,
then the ingester log for the fall-back warning.
