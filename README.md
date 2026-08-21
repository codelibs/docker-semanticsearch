# Semantic Search on Fess

[Fess](https://fess.codelibs.org/) is an open-source Enterprise Search Server. This
Docker environment runs Fess with OpenSearch configured for **semantic (vector) search**
and sets the embedding model up automatically, so a single `docker compose up` gives you
working **hybrid search** (BM25 + vector).

- Fess: **15.8**
- Search engine: OpenSearch (`ghcr.io/codelibs/fess-opensearch:3.8.0`)
- Semantic search: **Fess core** — no plugin. Semantic search moved into Fess itself in
  15.8, and [`fess-webapp-semantic-search`](https://github.com/codelibs/fess-webapp-semantic-search)
  is deprecated (see [Upgrading from Fess 15.7](#upgrading-from-fess-157))
- Embedding model (default): `paraphrase-multilingual-MiniLM-L12-v2` (384-dim, multilingual),
  hosted in OpenSearch ML Commons
- UI theme (default): **SemanticLens** — labels each result with the searcher that
  produced it (keyword / semantic / hybrid) and shows a legend, so you can see how
  hybrid search ranked each hit

## Public Site

Visit our public site at [semantic.codelibs.org](https://semantic.codelibs.org/).

## How It Works

Fess 15.8 chunks documents and generates embeddings **on the Fess side**: a scheduler job
reads crawled documents, splits `content` into chunks, calls the OpenSearch ML Commons
`_predict` API for each chunk, and stores the vectors in the `content_chunk_vector`
(nested `knn_vector`) field of the same document. At query time Fess embeds the query,
runs a `knn` query, and fuses the result with BM25 through RankFusion (RRF).

OpenSearch therefore only has to *host the model*. There is no ingest pipeline and no
`neural` query — those belonged to the 15.7 plugin design.

Services start in dependency order (the base/development stack is everything except
`https-portal`):

```
search01 (OpenSearch 3.8, k-NN + ML Commons, ml role)
   │ (healthy)
   ▼
init-semantic (one-shot: registers + deploys the embedding
   │            model, writes the model id to a shared volume)
   │ (completed)
   ▼
fess01 (Fess 15.8; entrypoint injects the model id as a JVM property)
   │ (healthy)
   ├──────────────────────────────► https-portal (TLS reverse proxy,
   │                                              production overlay only)
   ▼
init-fess-chunk (one-shot: verifies the chunk-vector mapping,
                 enables + launches the Content Chunk Vector Indexer job)
```

- **`init-semantic`** runs once after OpenSearch is healthy. It sets
  `plugins.ml_commons.only_run_on_ml_node=false` (needed on a single node), registers and
  deploys the embedding model, verifies that the model's embedding dimension matches
  `MODEL_DIMENSION`, and writes the generated `model_id` to `data/semantic/model_id`. It is
  idempotent: on restart it reuses an existing deployed model.
- **`fess01`** reads that `model_id` through a small entrypoint wrapper
  (`bin/fess-entrypoint.sh`) and passes it as
  `-Dfess.system.content_chunker.embedding.opensearch.model.id`. The id is read **once at
  boot**, so a running container keeps a stale id until it is recreated.
- **`init-fess-chunk`** runs once after `fess01` is healthy. It first checks that
  `fess.search` really carries `content_chunk_vector` with the configured dimension and ANN
  engine plus `index.knn: true` — those are baked in when the index is *created*, so a
  mismatch means the index predates the settings and needs a reindex. It then enables the
  **Content Chunk Vector Indexer** scheduler job (Fess ships it disabled at `0 13 * * *`)
  with `CHUNK_JOB_CRON` and launches it once. Without this step no vectors are ever
  produced and semantic search stays silently empty. It talks to Fess through the admin
  UI's own HTML forms (log in, then POST the job form), and it is idempotent: an
  already-enabled job with the requested cron is left untouched.

## Getting Started

### Prerequisites

Docker (Compose v2.24+ for the production overlay) and Git. On Linux, ensure
`vm.max_map_count >= 262144` for OpenSearch (Docker Desktop handles this automatically)
and note that `bin/setup.sh` uses `sudo` to set the bind-mount ownership.

### Setup

```sh
git clone https://github.com/codelibs/docker-semanticsearch.git
cd docker-semanticsearch
bash ./bin/setup.sh
```

`bin/setup.sh` runs on the host only — it never talks to OpenSearch or Fess. It creates
the bind-mount data directories, seeds `system.properties` from the tracked template
(first run only), syncs the static UI theme from
[`fess-themes`](https://github.com/codelibs/fess-themes), seeds a per-domain https-portal
vhost template when `DOMAIN` is customised, removes any leftover
`fess-webapp-semantic-search` jar, and (on Linux, via `sudo`) chowns `./data` to the
container UIDs. Re-running it is safe.

### Start

```sh
docker compose up -d
```

The **first** start downloads the embedding model (~490 MB) inside OpenSearch and can take
several minutes. Two one-shot helper containers must finish before semantic search is
ready:

```sh
docker compose logs -f init-semantic init-fess-chunk
docker compose ps -a
```

Once `fess01` is healthy and both helpers show `Exited (0)`, open `http://localhost:8080/`.

### Crawl and search

1. Sign in to the admin UI at `http://localhost:8080/admin` (default `admin` / `admin`;
   on first sign-in with the default password Fess asks you to set a new one).
2. **Admin > Crawler > Web Config > Create New**: enter a **Name** and the seed **URLs**
   (one per line). Optionally scope the crawl with **Included URLs For Crawling** (a regex,
   e.g. `https://example.com/docs/.*`) and a **Max Access Count**, then **Create**.
3. **Admin > System > Scheduler > Default Crawler > Start now** to run the crawl (or wait
   for its schedule).
4. Vectors are produced afterwards by the **Content Chunk Vector Indexer** job, which runs
   on `CHUNK_JOB_CRON` (default: hourly). The crawler does **not** chain into it, so a
   freshly crawled document is keyword-searchable immediately but becomes
   semantically searchable only after the next chunk-job run. To force it, use
   **Admin > System > Scheduler > Content Chunk Vector Indexer > Start now**.
5. Search at `http://localhost:8080/`. Results combine keyword (BM25) and semantic (vector)
   ranking automatically via RankFusion (RRF).

Check how far the vector indexing has got:

```sh
curl -s -XPOST "http://localhost:9200/fess.search/_search" \
  -H 'Content-Type: application/json' -d '
{"size":0,"aggs":{"status":{"terms":{"field":"content_chunk_status","missing":"pending"}}}}'
```

`done` = chunked and embedded, `chunked` = chunked but no vector, `skipped` = too many
chunks (`MAX_CHUNKS_PER_DOC`), `fail` = see the Fess log, `pending` = not processed yet.

### Stop

```sh
docker compose down
```

## When semantic search does *not* run

Fess 15.8 skips the semantic branch and answers with keyword search alone whenever the
assembled query contains Fess search syntax. That covers more than hand-typed operators:

- selecting a **facet** (adds `filetype:…` and friends)
- choosing a **label** (adds `label:"…"`)
- choosing a **sort order** (adds `sort:…`)
- advanced search phrases, exclusions, site/date filters
- a query with a **related query** configured (expands to `("A" OR "B")`)
- a query containing `"` `(` `)` `:` `[` `]` `{` `}` `^` `~` `*` `?` `\`, `&&`, `||`, a
  leading `+`/`-`, or uppercase `AND` / `OR` / `NOT` / `TO` — including a half-width `?`
  at the end of a natural-language question

Semantic search is also skipped for geo and similar-document searches, and RankFusion
itself stops past `rank.fusion.window_size` (default 200), so deep result pages are
keyword-only. This is a deliberate core behaviour, not a configuration problem.

## Configuration

Configuration uses three layers — no values need to be entered through the Admin UI.

### 1. Environment variables (`.env`)

All tunables fall back to the defaults in `compose.yaml`, so `.env` is optional. To
override:

```sh
cp .env.example .env
# edit .env
```

| Variable | Default | Purpose |
| --- | --- | --- |
| `FESS_VERSION` / `OPENSEARCH_VERSION` | `15.8.0` / `3.8.0` | Image tags |
| `MODEL_NAME` / `MODEL_VERSION` / `MODEL_FORMAT` | multilingual MiniLM-L12-v2 / `1.0.1` / `TORCH_SCRIPT` | ML Commons model to deploy |
| `MODEL_DIMENSION` | `384` | Must match the model; baked into the index mapping |
| `MODEL_MAX_WAIT` | `900` | Seconds to wait for model register + deploy |
| `CHUNK_SIZE` / `CHUNK_OVERLAP` | `250` / `0` | Chunk length in **characters** |
| `MAX_CHUNKS_PER_DOC` | `2000` | Documents above this are `skipped` |
| `KNN_METHOD` / `KNN_ENGINE` / `KNN_SPACE_TYPE` | `hnsw` / `lucene` / `cosinesimil` | ANN settings, baked into the mapping |
| `KNN_K` | `100` | Neighbours fetched per ANN query |
| `SEMANTIC_MIN_SCORE` | `0.5` | Minimum cosine similarity (0–1) |
| `CHUNK_JOB_CRON` | `0 * * * *` | Schedule for the vector indexer job |
| `CHUNK_JOB_AUTOSTART` | `true` | Launch the job once at stack start |
| `CHUNK_JOB_START_DELAY` | `35` | Seconds to wait before that launch |
| `CHUNK_JOB_CONCURRENCY` / `CHUNK_JOB_BULK_SIZE` | `2` / `20` | Indexer job throughput |
| `CHUNK_SETUP_MAX_WAIT` | `300` | Seconds `init-fess-chunk` waits to launch the job |
| `THEME_NAME` / `FESS_THEMES_REF` / `FESS_THEMES_REPO` / `FESS_THEMES_DIR` | `semanticlens` / `main` | UI theme source |
| `OPENSEARCH_HEAP` / `OPENSEARCH_HEAP_PROD` | `2g` / `3g` | JVM heap |
| `FESS_ADMIN_PASSWORD` | `admin` | Initial admin password |
| `DOMAIN` | `semantic.codelibs.org` | Production overlay only |

> **Chunk size must fit the model.** `CHUNK_SIZE` is measured in characters, but the
> embedding model has a *token* limit — `paraphrase-multilingual-MiniLM-L12-v2` accepts
> 128 tokens, roughly 250 Japanese characters. Anything beyond that is truncated before
> the vector is computed, silently and with no error, so the tail of every chunk simply
> stops being searchable. Fess core defaults to 800 characters because it targets
> 512-token models; raise `CHUNK_SIZE` only together with a model that can take it.
> Boundary-aware splitting makes the real chunk length about 0.8×–1.05× of the value.

> **`CHUNK_OVERLAP` is 0 on purpose.** Fess writes the chunks back into the searchable
> `content` array, so overlapped text is indexed twice: BM25 term frequencies are
> inflated and highlights can repeat the overlapped region. Fess logs a warning at boot
> whenever the value is non-zero. Raise it only when semantic recall across chunk
> boundaries matters more to you than BM25 accuracy.

### 2. `-D` properties in `compose.yaml`

Two distinct channels live in `FESS_JAVA_OPTS`:

| Channel | Reaches | Used for |
| --- | --- | --- |
| `-Dfess.config.<key>` | `fess_config.properties` | crawler/query settings |
| `-Dfess.system.<key>` | `system.properties` | **all `content_chunker.*` settings** |

`content_chunker.*` is read from the `system.properties` channel **only** —
`-Dfess.config.content_chunker.*` is ignored. A key written into
`data/fess/opt/fess/system.properties` takes precedence over the matching
`-Dfess.system.*`, which is why the template deliberately does not list any
`content_chunker.*` key: `.env` stays the single source of truth.

`-Drank.fusion.searchers` is intentionally **not** set. Leaving it unset registers every
searcher, which is what hybrid search means here. Do not carry over the 15.7 value
`default,semantic`: the core searcher is named `semantic_chunk`, so that allowlist would
exclude it and Fess would log a warning while quietly serving keyword-only results.

The only runtime-dynamic value,
`content_chunker.embedding.opensearch.model.id`, is injected by `bin/fess-entrypoint.sh`.

### 3. Dynamic system settings (`system.properties`)

Admin > General settings (theme, suggest, purge intervals, …) live in
`data/fess/opt/fess/system.properties`, seeded on first run from the tracked
`system.properties.template`. The live file is git-ignored and may be edited via Admin >
General; to reset it, delete it and re-run `bin/setup.sh`. The active UI theme is set via
`theme.default` (driven by `THEME_NAME`). The default retention for search logs, user
info, and job logs is **90 days** (`purge.searchlog.day`, `purge.userinfo.day`,
`purge.joblog.day`, `day.for.cleanup = 90`).

### Changing the model, chunking, or theme

- **Model or dimension:** change `MODEL_NAME` / `MODEL_VERSION` / `MODEL_DIMENSION` in
  `.env`. The dimension is baked into the index mapping, so the index has to be rebuilt.
  Remove the stale vectors first, otherwise the reindex silently drops documents the new
  mapping cannot accept:
  ```sh
  curl -XPOST "http://localhost:9200/fess.search/_update_by_query" \
       -H 'Content-Type: application/json' -d '
  {"query":{"exists":{"field":"content_chunk_status"}},
   "script":{"source":"ctx._source.remove(\"content_chunk_vector\"); ctx._source.remove(\"content_chunk_status\")"}}'
  ```
  Then **Admin > System Info > Maintenance > Reindex** with *Update aliases* enabled,
  recreate `fess01` so it picks up the new `model_id`
  (`docker compose up -d --force-recreate fess01`), and re-run the Content Chunk Vector
  Indexer job.
- **ANN settings** (`KNN_METHOD` / `KNN_ENGINE` / `KNN_SPACE_TYPE`) are also mapping-time
  values and need the same reindex.
- **Chunk size / overlap / min score / cron** take effect on the next job run; no reindex
  is needed, but existing documents keep their old chunk boundaries until they are
  re-chunked (remove `content_chunk_status` as above, or re-crawl).
- **Theme:** change `THEME_NAME` in `.env`, delete `data/fess/opt/fess/system.properties`,
  then re-run `bin/setup.sh` and `docker compose up -d`. `bin/setup.sh` never overwrites
  a live `system.properties`; it only warns when `theme.default` disagrees with
  `THEME_NAME`.
- **Optional plugins:** add a `FESS_PLUGINS` entry to `fess01` in `compose.yaml`, e.g.
  `fess-script-groovy:15.8.0`. Do **not** add `fess-webapp-semantic-search`.

> **`MODEL_VERSION`-only change is silently ignored:** `init-semantic` identifies a
> registered model by `MODEL_NAME`, not by version. Bumping `MODEL_VERSION` alone on an
> existing deployment reuses the old model without registering the new one. To actually
> switch the model version, either also change `MODEL_NAME`, or first delete the existing
> model and model-group from OpenSearch so `init-semantic` re-registers.

## Update

```sh
git pull
bash ./bin/setup.sh
docker compose pull
docker compose up -d
```

`bin/setup.sh` is safe to re-run; it never overwrites the live `system.properties`.

### Upgrading from Fess 15.7

15.8 replaced the `fess-webapp-semantic-search` plugin with a different core design: the
vector field changed (`content_vector` → `content_chunk_vector`), embeddings moved from an
OpenSearch ingest pipeline to a Fess-side scheduler job, and the searcher was renamed
(`semantic` → `semantic_chunk`). Old vectors cannot be reused.

**Recommended for this stack — start from a clean index.** Data here is crawled, so
rebuilding is cheap and avoids every migration pitfall:

```sh
docker compose down
rm -rf data/opensearch/usr/share/opensearch/data data/fess/var/lib/fess data/semantic
git pull
bash ./bin/setup.sh
docker compose up -d
# then re-create the crawl configs and crawl again
```

**Migrating in place** is possible but has to happen in the right order — in particular
the old `default_pipeline` must be detached *before* reindexing, because the new index is
created from the old one's settings. Follow the official procedure in the Fess docs:
[Semantic search — migrating from 15.7 or earlier](https://fess.codelibs.org/15.8/config/search-semantic.html).
In short: remove the plugin jar and every `-Dfess.semantic_search.*` and
`-Drank.fusion.searchers=default,semantic`, detach `default_pipeline` from the live index,
drop the old `content_vector` field, add the `content_chunker.*` settings, reindex, then
enable the Content Chunk Vector Indexer job.

When upgrading a deployment that previously ran an OpenSearch 2.x stack, the persisted
`data/opensearch/usr/share/opensearch/data` is incompatible with OpenSearch 3.x. Stop the
stack, remove that directory, then start again and re-crawl.

## Production

`https-portal` (TLS reverse proxy) is **not** part of the base stack; it only starts when
the production overlay is included. Development access is plain HTTP at
`http://localhost:8080/` (no ports 80/443).

Set your domain via `DOMAIN` in `.env` and run `bin/setup.sh` — it seeds
`data/https-portal/conf/<domain>.ssl.conf.erb` from the bundled template (https-portal
matches its vhost template by file name). Then:

```sh
docker compose -f compose.yaml -f compose-production.yaml up -d
```

The overlay enables real TLS certificates, raises the OpenSearch heap
(`OPENSEARCH_HEAP_PROD`), and rebinds Fess's own `8080` to loopback so the stack is
reachable only through `https-portal`. OpenSearch's `9200` is already loopback-only in the
base stack; the OpenSearch security plugin is disabled, so neither port may be exposed on
a public interface.

For corpora beyond roughly one to two million documents, raise the indexer child JVM heap
via `jvm.chunk.options` in `fess_config.properties`, or cap each run with
`content_chunker.job.max_documents_per_run`.

## Troubleshooting

- **`fess01` never starts:** it waits for `init-semantic` to exit 0. Check
  `docker compose logs init-semantic` — most failures are network access for the model
  download. Fix the cause and re-run `docker compose up -d`; the setup is idempotent and
  reuses an already-deployed model.
- **`init-fess-chunk` reports a mapping error:** the document index was created before the
  `content_chunker.*` settings were in place, or `MODEL_DIMENSION` / `KNN_ENGINE` changed.
  Run **Admin > System Info > Maintenance > Reindex** with *Update aliases* enabled, then
  `docker compose up -d init-fess-chunk`. On a fresh stack this should never happen.
- **Search returns keyword hits only:**
  1. Confirm vectors exist — the `content_chunk_status` aggregation above should show
     `done` documents. If everything is `pending`, the indexer job has not run: check
     **Admin > System > Scheduler > Content Chunk Vector Indexer** and
     `docker compose logs init-fess-chunk`.
  2. Confirm the query is not hitting the syntax gate — see
     [When semantic search does *not* run](#when-semantic-search-does-not-run). A facet or
     label selection alone is enough to disable it.
  3. Confirm `fess01` picked up a model id:
     `docker compose logs fess01 | grep 'Injecting embedding model_id'`.
- **All documents are `skipped`:** they produce more than `MAX_CHUNKS_PER_DOC` chunks.
  Raise it, or raise `CHUNK_SIZE` (within the model's token limit).
- **Dimension mismatch:** `init-semantic` fails fast when the model's embedding dimension
  does not match `MODEL_DIMENSION`. Align the two, then rebuild the index as described in
  [Changing the model, chunking, or theme](#changing-the-model-chunking-or-theme).

---

For additional support, see the [Fess documentation](https://fess.codelibs.org/).
