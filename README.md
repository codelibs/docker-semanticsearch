# Semantic Search on Fess

[Fess](https://fess.codelibs.org/) is an open-source Enterprise Search Server. This
Docker environment runs Fess with OpenSearch configured for **semantic (vector) search**
and sets the embedding model up automatically, so a single `docker compose up` gives you
working **hybrid search** (BM25 + vector).

- Fess: **15.9**
- Search engine: OpenSearch (`ghcr.io/codelibs/fess-opensearch:3.8.0`)
- Semantic search: **Fess core** — no plugin. Semantic search moved into Fess itself in
  15.8, and [`fess-webapp-semantic-search`](https://github.com/codelibs/fess-webapp-semantic-search)
  is deprecated (see [Upgrading from Fess 15.7](#upgrading-from-fess-157))
- Embedding model (default): `paraphrase-multilingual-MiniLM-L12-v2` (384-dim, multilingual),
  hosted in OpenSearch ML Commons
- Hybrid ranking: **in OpenSearch** — the keyword and the vector query run as one
  `hybrid` query (Neural Search), new in Fess 15.9
- UI theme (default): **SemanticLens** — labels each result with the searcher that
  produced it (keyword / semantic / hybrid) and shows a legend, so you can see how
  hybrid search ranked each hit

## Public Site

Visit our public site at [semantic.codelibs.org](https://semantic.codelibs.org/).

## How It Works

Fess chunks documents and generates embeddings **on the Fess side**: a scheduler job
reads crawled documents, splits `content` into chunks, calls the OpenSearch ML Commons
`_predict` API for each chunk, and stores the vectors in the `content_chunk_vector`
(nested `knn_vector`) field of the same document.

At query time Fess embeds the query and sends **one** search request: an OpenSearch
`hybrid` query whose two sub-queries are the keyword (BM25) query and the `knn` query,
with an inline search pipeline that fuses them by Reciprocal Rank Fusion
(`rank.fusion.engine.enabled=true`, new in Fess 15.9). Because OpenSearch fuses the
results, the total hit count and the facet counts describe the fused result set.

A fused search pages through its first `rank.fusion.pagination_depth` hits (default 1000,
page 100 at 10 hits per page). A page that starts at or beyond that depth is refused (the
JSON API answers HTTP 400 `invalid_request`), a page that runs past it is cut at the depth,
and the hit count becomes a lower bound (`record_count_relation` is
`GREATER_THAN_OR_EQUAL_TO`) once it reaches the depth. Fess fuses the two result lists
itself instead (the 15.8 behaviour) for advanced searches (`as.*`) and when you set
`RANK_FUSION_ENGINE=false`; that path has its own, smaller window
(`rank.fusion.window_size`, 200), and a page that starts at hit 100 or later is answered
by the keyword search alone.

OpenSearch therefore hosts the model and runs the fusion. There is no ingest pipeline and
no `neural` query — those belonged to the 15.7 plugin design. The `hybrid` query comes
from the Neural Search plugin, which `ghcr.io/codelibs/fess-opensearch` ships alongside
k-NN and ML Commons.

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
fess01 (Fess 15.9; entrypoint injects the model id as a JVM property)
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
   ranking automatically (OpenSearch `hybrid` query, RRF).

Check how far the vector indexing has got:

```sh
curl -s -XPOST "http://localhost:9200/fess.search/_search" \
  -H 'Content-Type: application/json' -d '
{"size":0,"aggs":{"status":{"terms":{"field":"content_chunk_status","missing":"pending"}}}}'
```

`done` = chunked and embedded, `chunked` = chunked but no vector, `skipped` = too many
chunks (`MAX_CHUNKS_PER_DOC`), blank content, or no chunks at all, `fail` = see the Fess
log, `pending` = not processed yet.

### Stop

```sh
docker compose down
```

## When semantic search does *not* run

From Fess 15.9, field conditions no longer turn the vector search off: Fess splits them
out of the query and applies them to both halves. A paraphrase still finds its document
after you

- select a **facet**, a **label**, or a sidebar filter (file type, date, size), or
- add `filetype:`, `label:`, `site:` or another `field:value` condition to the query.

Quote a `site:` value that contains a `/` (`site:"example.com/docs/"`): unquoted, the
keyword half splits the value at the slash and matches nothing.

Fess still answers with keyword search alone when the free text itself uses search syntax
or the request asks for something the vector query cannot do:

- a phrase in quotes, a wildcard (`*`, and a half-width `?` — including the `?` at the
  end of a natural-language question; a full-width `？` is fine), a range, a boost `^` or a
  fuzzy `~`
- negated text (`-word`, `NOT word`), `allintitle:` / `allinurl:`
- a query that is only a filter, with no free text
- an explicit **sort order**, a geo search, or a similar-document search
- the embedding model is unavailable (Fess logs a WARN and serves keyword results)

This is deliberate core behaviour, not a configuration problem. These keyword-only
queries are not limited by `rank.fusion.pagination_depth`: they page as far as the
index's `max_result_window`, like any keyword search.

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
| `FESS_VERSION` / `OPENSEARCH_VERSION` | `15.9.0` / `3.8.0` | Image tags |
| `MODEL_NAME` / `MODEL_VERSION` / `MODEL_FORMAT` | multilingual MiniLM-L12-v2 / `1.0.1` / `TORCH_SCRIPT` | ML Commons model to deploy |
| `MODEL_DIMENSION` | `384` | Must match the model; baked into the index mapping |
| `MODEL_MAX_WAIT` | `900` | Seconds to wait for model register + deploy |
| `CHUNK_SIZE` / `CHUNK_OVERLAP` | `250` / `0` | Chunk length in **characters** |
| `MAX_CHUNKS_PER_DOC` | `2000` | Documents above this are `skipped` |
| `KNN_METHOD` / `KNN_ENGINE` / `KNN_SPACE_TYPE` | `hnsw` / `lucene` / `cosinesimil` | ANN settings, baked into the mapping |
| `KNN_K` | `100` | Neighbours fetched per ANN query |
| `SEMANTIC_MIN_SCORE` | `0.5` | Minimum cosine similarity (0–1) |
| `RANK_FUSION_ENGINE` | `true` | `true`: OpenSearch fuses both halves in one `hybrid` query; `false`: Fess fuses them (15.8 behaviour) |
| `RANK_FUSION_TECHNIQUE` | `rrf` | `rrf`, or a score-based `arithmetic_mean` / `geometric_mean` / `harmonic_mean` |
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

The hybrid switches `rank.fusion.engine.enabled` and `rank.fusion.combination.technique`
are `fess_config.properties` keys, so they are passed as `-Dfess.config.*` (driven by
`RANK_FUSION_ENGINE` / `RANK_FUSION_TECHNIQUE`). The rest of the `rank.fusion.*` family
can be added the same way, e.g. the weights in the next note.

> **Short terms and product codes can tie with an unrelated vector hit.** With the default
> equal-weight RRF, a rare short term or product code can put the exact keyword hit and an
> unrelated vector-only hit on the same rank 1, and the vector-only document can come out
> first. To favour the keyword half, add to `FESS_JAVA_OPTS` in `compose.yaml`:
> `-Dfess.config.rank.fusion.combination.weights=default:0.6,semantic_chunk:0.4`.
> Measured on this stack, the exact keyword hit then comes first for such queries while
> documents found by both halves still rank above documents found by only one;
> `default:0.4,semantic_chunk:0.6` brings the vector-only document back to first. The
> weights have to name exactly the searchers taking part (`default` and `semantic_chunk`)
> and sum to 1.0; otherwise Fess logs an ERROR on every search and fuses in Fess instead
> (the 15.8 behaviour).

> **`SEMANTIC_MIN_SCORE` is a trade-off.** With the default model, correct paraphrases
> and cross-language matches were measured at a cosine similarity of 0.38–0.83, while the
> closest document to an unrelated question scored 0.31–0.42 — the two ranges overlap.
> The default 0.5 keeps unrelated questions out but misses some weaker paraphrases;
> lowering it finds those and lets unrelated documents in. Short keywords and product
> codes can also reach 0.5 against unrelated documents, which then share the top rank
> with the exact keyword match (see the weights note above). Re-measure when you change
> `MODEL_NAME`: scores are model-specific.

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
- **Chunk size / overlap / cron** take effect on the next job run; no reindex is needed,
  but existing documents keep their old chunk boundaries until they are re-chunked (remove
  `content_chunk_status` as above, or re-crawl).
- **`SEMANTIC_MIN_SCORE` / `KNN_K`** are read at search time, so they need neither a job run
  nor a reindex. Set in `.env`, they reach Fess as `-D` options, so `fess01` has to be
  recreated (`docker compose up -d` does it). A value written to
  `data/fess/opt/fess/system.properties` is picked up within seconds without a restart and
  wins over the `-D` value, for as long as it stays in the file.
- **Theme:** change `THEME_NAME` in `.env`, delete `data/fess/opt/fess/system.properties`,
  then re-run `bin/setup.sh` and `docker compose up -d`. `bin/setup.sh` never overwrites
  a live `system.properties`; it only warns when `theme.default` disagrees with
  `THEME_NAME`.
- **Optional plugins:** add a `FESS_PLUGINS` entry to `fess01` in `compose.yaml`, e.g.
  `fess-script-groovy:15.9.0`. Do **not** add `fess-webapp-semantic-search`.

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

### Upgrading from Fess 15.8

Fess 15.9 moved the Groovy script engine out of core into the `fess-script-groovy`
plugin and made JavaScript the default script type. An upgrade does not rewrite stored
settings, so a 15.8 install keeps Groovy on its 14 bundled scheduled jobs. Fess 15.9
additionally creates the **Tag Updater** job, as JavaScript, at the first start, so after
the migration below there are 15 jobs, all JavaScript. This stack does not get the Groovy
plugin: the `WEB-INF/plugin` bind mount hides the copy baked into the 15.9 image. After
the upgrade the **Default Crawler** and the **Content Chunk Vector Indexer** end with
`fail`, and the only trace is a startup WARN (`Settings use the script engine groovy,
which is not registered`). Search keeps working on the existing index, so this is easy to
miss. `init-fess-chunk` does not repair it: it leaves an already-enabled job alone.

The index and the stored vectors carry over as they are; the upgrade needs no reindex
and no re-crawl. Switch the stored scripts to JavaScript once, right after the upgrade:

1. `git pull`, then set `FESS_VERSION=15.9.0` in `.env` if you pinned it there.
2. Re-run setup and start the stack:
   ```sh
   bash bin/setup.sh
   docker compose pull
   docker compose up -d
   ```
   Use plain `up -d`: `up -d --wait` exits with status 1 on an upgraded stack, because
   `init-fess-chunk` exits at once when the indexer job is already enabled.
3. Create an access token for the admin API: **Admin > System > Access Token** >
   **Create New**, with the permission `{role}admin-api`.
4. Run the migration (it needs `python3` on the host):
   ```sh
   export FESS_ACCESS_TOKEN=<the token>
   bash bin/migrate-to-javascript.sh --dry-run   # lists what would change
   bash bin/migrate-to-javascript.sh
   docker compose restart fess01                 # optional: clears the startup warning
   ```
   Set `FESS_ENDPOINT` if Fess is not at `http://localhost:8080`. Delete the token
   afterwards if you have no other use for it.

`bin/migrate-to-javascript.sh` sets every scheduled job whose script type is Groovy (or
unset) to JavaScript, rewriting the two Groovy-only constructs in the bundled 15.8 jobs
(the `1000L` long literal in *Thumbnail Purger* and the `org.opensearch` package in
*Index Exporter*), so the result is exactly the job set Fess 15.9 ships. It also adds
`script_type=javascript` to data configs that have none. It prints every change, changes
nothing on a second run, and refuses to run against Fess 15.8. A job script you
customized with other Groovy syntax is switched as well and has to be rewritten by hand;
the alternative is to keep Groovy by adding `fess-script-groovy:15.9.0` to
`FESS_PLUGINS`.

A fresh 15.9 install needs none of this: its jobs are created as JavaScript.

**Trying 15.9 before its release:** set `FESS_VERSION=snapshot` in `.env` to run the
development build (`ghcr.io/codelibs/fess:snapshot`).

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
     `docker compose logs init-fess-chunk`. A run that was skipped because the embedding
     model is not serving leaves them `pending` too (see the next item).
  2. Confirm the query is not hitting the syntax gate — see
     [When semantic search does *not* run](#when-semantic-search-does-not-run). A trailing
     half-width `?` or a sort order is enough to disable it.
  3. Confirm `fess01` picked up a model id:
     `docker compose logs fess01 | grep 'Injecting embedding model_id'`.
- **Documents stay `pending` although the indexer job shows `ok`:** when the embedding
  model is not serving (undeployed, or ML Commons restarting), the Content Chunk Vector
  Indexer skips the run, or, if the model goes away mid-run, leaves the remaining
  documents `pending`, instead of marking them `fail`. The job itself still counts as ok;
  the reason is in `fess-chunk.log` in the Fess log directory
  (`data/fess/var/log/fess/`): `The embedding provider is not available; skipping
  chunk-vector processing`, `leaving document pending`, and a closing line such as
  `Processed N documents. Succeeded: S, Failed/Skipped: F. Failed: a, skipped: b, left
  pending: c.` Check that the model is deployed (`model_state` is `DEPLOYED` in
  `curl -s "http://localhost:9200/_plugins/_ml/models/$(cat data/semantic/model_id)"`),
  then run the job again (**Start now**) or wait for the next cron run. Documents already
  marked `fail` are not selected again; set `content_chunker.job.retry_failed=true` for one
  run to retry them, then remove it.
- **Many documents are `skipped`:** usually they produce more than `MAX_CHUNKS_PER_DOC`
  chunks; raise it, or raise `CHUNK_SIZE` (within the model's token limit). A document with
  blank `content`, or one the chunker splits into no chunks at all, is `skipped` as well
  and needs no change.
- **Dimension mismatch:** `init-semantic` fails fast when the model's embedding dimension
  does not match `MODEL_DIMENSION`. Align the two, then rebuild the index as described in
  [Changing the model, chunking, or theme](#changing-the-model-chunking-or-theme).

---

For additional support, see the [Fess documentation](https://fess.codelibs.org/).
