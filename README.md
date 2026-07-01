# Semantic Search on Fess

[Fess](https://fess.codelibs.org/) is an open-source Enterprise Search Server. This
Docker environment runs Fess with OpenSearch configured for **semantic (vector) search**
and automatically sets up the embedding model and neural ingest pipeline, so a single
`docker compose up` gives you working **hybrid search** (BM25 + vector).

- Fess: **15.7**
- Search engine: OpenSearch (`ghcr.io/codelibs/fess-opensearch:3.7.0`)
- Semantic plugin: [`fess-webapp-semantic-search`](https://github.com/codelibs/fess-webapp-semantic-search) **15.7.0**
- Embedding model (default): `paraphrase-multilingual-MiniLM-L12-v2` (384-dim, multilingual)
- UI theme (default): **SemanticLens** — labels each result with the searcher that
  produced it (keyword / semantic / hybrid) and shows a legend, so you can see how
  hybrid search ranked each hit

## Public Site

Visit our public site at [semantic.codelibs.org](https://semantic.codelibs.org/).

## How It Works

The services start in dependency order (the base/development stack is everything
except `https-portal`):

```
search01 (OpenSearch 3.7, ml role)
   │ (healthy)
   ▼
init-semantic (one-shot: registers + deploys the model,
   │            creates neural_pipeline, writes the model id)
   │ (completed)
   ▼
fess01 (Fess 15.7; entrypoint injects the model id as a JVM property)
   │ (healthy)
   ▼
init-fess-index (one-shot: reindexes the document index so it
   │              carries the vector mapping + neural default pipeline)
   │ (completed)
   ▼
https-portal (TLS reverse proxy, production overlay only)
```

- **`init-semantic`** runs once after OpenSearch is healthy. It registers and deploys the
  embedding model, creates the `neural_pipeline` ingest pipeline (chunk → embed), and
  writes the generated `model_id` to `data/semantic/model_id`. It is idempotent: on
  restart it reuses the existing model and pipeline.
- **`fess01`** reads that `model_id` via a small entrypoint wrapper
  (`bin/fess-entrypoint.sh`) and passes it to the plugin as a JVM system property. The
  plugin routes crawled documents through `neural_pipeline` and runs OpenSearch `neural`
  queries fused with BM25 via Fess RankFusion (RRF).
- **`init-fess-index`** runs once after `fess01` is healthy and makes the document index
  vector-capable. The semantic plugin can only add the `knn_vector` mapping (`content_vector`
  / `content_chunk`), `index.knn` and the neural `default_pipeline` when Fess *creates* an
  index, but Fess core creates the document index earlier in boot than the plugin registers
  those rewrite rules — so the auto-created index has no vector mapping. This service runs a
  one-time **Admin > Maintenance > Reindex** (via the Fess API) to re-create the index with
  the plugin's mapping and swap the `fess.search` / `fess.update` aliases to it. It is
  idempotent: if the vector field is already present it does nothing, so restarts are cheap
  and never touch already-crawled data.
- Embeddings are generated **inside OpenSearch** by the ingest pipeline; Fess does not
  compute vectors itself.

## Getting Started

### Prerequisites

Docker and Git. On Linux, ensure `vm.max_map_count >= 262144` for OpenSearch
(Docker Desktop handles this automatically).

### Setup

```sh
git clone https://github.com/codelibs/docker-semanticsearch.git
cd docker-semanticsearch
bash ./bin/setup.sh
```

`bin/setup.sh` creates the data directories, seeds `system.properties` from the tracked
template, and syncs the static UI theme (default: **SemanticLens**) from
[`fess-themes`](https://github.com/codelibs/fess-themes).

### Start

```sh
docker compose up -d
```

Services start in order: `search01` → `init-semantic` → `fess01` → `init-fess-index`.
The **first** start downloads the embedding model inside OpenSearch and can take a few
minutes. Two one-shot helper containers must finish before semantic search is ready:

- `init-semantic` registers/deploys the model and creates the `neural_pipeline`.
- `init-fess-index` makes the document index vector-capable (a one-time reindex).

Watch their progress, then confirm both finished with `Exited (0)`:

```sh
docker compose logs -f init-semantic init-fess-index
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
   for its schedule). Crawled documents are embedded automatically by `neural_pipeline`.
4. Search at `http://localhost:8080/`. Results combine keyword (BM25) and semantic (vector)
   ranking automatically via Fess RankFusion (RRF).

### Stop

```sh
docker compose down
```

## Configuration

Configuration uses three layers — no values need to be entered through the Admin UI.

### 1. Environment variables (`.env`)

All tunables fall back to sensible defaults, so `.env` is optional. To override:

```sh
cp .env.example .env
# edit .env
```

Key variables (see `.env.example` for the full list): `FESS_VERSION`,
`OPENSEARCH_VERSION`, `SEMANTIC_PLUGIN_VERSION`, `MODEL_NAME`, `MODEL_VERSION`,
`MODEL_DIMENSION`, `MODEL_SPACE_TYPE`, `MODEL_ENGINE`, `MODEL_METHOD`, `THEME_NAME`,
`FESS_THEMES_REF`, `OPENSEARCH_HEAP`, `FESS_ADMIN_PASSWORD`, `DOMAIN`.

### 2. `fess_config.properties` overrides and semantic properties (`-D` in compose)

Static Fess settings are overridden as `-Dfess.config.<key>` and the semantic-search
settings as `-Dfess.semantic_search.<key>`, both inside `FESS_JAVA_OPTS` in
`compose.yaml`. Hybrid search is enabled with `-Drank.fusion.searchers=default,semantic`
(a plain system property, not a `fess.config.` key). The only runtime-dynamic value,
`fess.semantic_search.content.model_id`, is injected by `bin/fess-entrypoint.sh`.

### 3. Dynamic system settings (`system.properties`)

Admin > General settings (theme, suggest, purge intervals, …) live in
`data/fess/opt/fess/system.properties`, seeded on first run from the tracked
`system.properties.template`. The live file is git-ignored and may be edited via Admin >
General; to reset it, delete it and re-run `bin/setup.sh`. The active UI theme is set via
`theme.default` (driven by `THEME_NAME`). The default retention for search logs, user
info, and job logs is **90 days** (`purge.searchlog.day`, `purge.userinfo.day`,
`purge.joblog.day`, `day.for.cleanup = 90`); the previous default was indefinite (`-1`).
Operators needing longer retention should adjust these values in
`data/fess/opt/fess/system.properties` or via **Admin > General**.

### Changing the model or theme

- **Model:** change `MODEL_NAME` / `MODEL_VERSION` / `MODEL_DIMENSION` (and the matching
  `MODEL_SPACE_TYPE` / `MODEL_ENGINE` / `MODEL_METHOD`) in `.env`, then recreate `fess01`
  so it picks up the newly generated `model_id`:
  ```sh
  docker compose up -d --force-recreate fess01
  ```
  `fess01` reads `model_id` once at boot via a JVM system property; a running instance
  keeps the stale id until recreated. Because the dimension is baked into the index
  mapping, also reindex via **Admin > Maintenance**.
- **Theme:** change `THEME_NAME` in `.env`, delete `data/fess/opt/fess/system.properties`,
  then re-run `bin/setup.sh` and `docker compose up -d`.
- **Optional plugins:** add to `FESS_PLUGINS` in `compose.yaml`, e.g.
  `fess-webapp-semantic-search:15.7.0 fess-script-groovy:15.7.0`.

> **`MODEL_VERSION`-only change is silently ignored:** `init-semantic` identifies a
> registered model by `MODEL_NAME`, not by version. Bumping `MODEL_VERSION` alone on an
> existing deployment reuses the old model without registering the new one. To actually
> switch the model version, either also change `MODEL_NAME`, or first delete the existing
> model and model-group from OpenSearch (so `init-semantic` re-registers), then recreate
> `fess01` (`docker compose up -d --force-recreate fess01`) and reindex via
> **Admin > Maintenance**.

## Update

```sh
git pull
bash ./bin/setup.sh
docker compose pull
docker compose up -d
```

`bin/setup.sh` is safe to re-run; it never overwrites the live `system.properties`.

> **Theme change on an existing deployment:** updating `THEME_NAME` in `.env` does not
> re-apply the theme because `bin/setup.sh` never overwrites the live
> `data/fess/opt/fess/system.properties`. To switch the active theme, set
> `theme.default=<THEME_NAME>` in that file directly (or via **Admin > General**), or
> delete it and re-run `bin/setup.sh`. See
> [Changing the model or theme](#changing-the-model-or-theme) for full steps.

When upgrading an **existing** deployment that previously ran an OpenSearch 2.x stack,
the persisted `data/opensearch/usr/share/opensearch/data` is incompatible with
OpenSearch 3.x. Stop the stack (`docker compose down`), remove that directory, then
start again and re-crawl. Fresh clones are unaffected.

### Upgrading from 14.18

The data layout changed between the 14.18 and 15.x releases. In the old repo,
`data/fess/opt/fess/system.properties` was a **tracked** file (Fess rewrites it at
runtime via Admin > General). It is now replaced by a tracked
`system.properties.template`; the live file is git-ignored. The old helper
`bin/git_pull.sh`, which stashed and restored this file around pulls, has been removed.

As a result, an existing 14.18 checkout will have local modifications to a now-renamed
tracked path, and a plain `git pull` may abort with "Your local changes would be
overwritten by merge". Remedy:

1. Back up `data/fess/opt/fess/system.properties`.
2. Unstage the conflicting path:
   ```sh
   git checkout -- data/fess/opt/fess
   ```
   Alternatively, stash all local changes with `git stash`.
3. Pull: `git pull`.
4. Re-run `bin/setup.sh` — it reseeds the live `system.properties` from the template on
   first run.
5. Restore any custom settings into `data/fess/opt/fess/system.properties` or via
   **Admin > General**.

If your previous stack also ran OpenSearch 2.x, see the note above about removing
`data/opensearch/usr/share/opensearch/data` before restarting.

## Production

`https-portal` (TLS reverse proxy) is **not** part of the base stack; it only starts
when the production overlay is included. Development access is plain HTTP at
`http://localhost:8080/` (no ports 80/443).

To enable TLS, set your domain via `DOMAIN` and copy
`data/https-portal/conf/semantic.codelibs.org.ssl.conf.erb` to
`data/https-portal/conf/<domain>.ssl.conf.erb` (the https-portal vhost template is
matched by file name), then enable real TLS certificates and a larger heap with the
production overlay:

```sh
docker compose -f compose.yaml -f compose-production.yaml up -d
```

The OpenSearch security plugin is disabled (plain HTTP on the internal network); the
`https-portal` service terminates TLS for the Fess UI. For production, restrict or remove
the host `9200` port mapping and front the stack only through `https-portal`.

## Troubleshooting

- **Semantic search inactive / model setup failed / fess01 not starting:** `fess01`
  will not start until `init-semantic` completes successfully. Check
  `docker compose logs init-semantic`, fix the cause (often network access for the
  model download), then re-run `docker compose up -d` — the setup is idempotent and
  reuses an already-registered and deployed model.
- **Search returns keyword hits but no semantic ranking:** the document index may be
  missing the vector mapping. Check `docker compose logs init-fess-index`; on success it
  reports `Document index now has 'content_vector'`. If it failed (often a wrong
  `FESS_ADMIN_PASSWORD`, so the API login is rejected), fix the cause and re-run
  `docker compose up -d` to retry the one-time reindex.
- **Dimension mismatch:** `init-semantic` fails fast if the model's embedding dimension
  does not match `MODEL_DIMENSION`. Update `MODEL_DIMENSION` to match the model. Note that
  changing the dimension on an existing deployment also requires a manual
  **Admin > Maintenance > Reindex** (the `init-fess-index` step is skipped once the vector
  field already exists, so it will not rebuild a stale mapping).

---

For additional support, see the [Fess documentation](https://fess.codelibs.org/).
