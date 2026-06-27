# Semantic Search on Fess

[Fess](https://fess.codelibs.org/) is an open-source Enterprise Search Server. This
Docker environment runs Fess with OpenSearch configured for **semantic (vector) search**
and automatically sets up the embedding model and neural ingest pipeline, so a single
`docker compose up` gives you working **hybrid search** (BM25 + vector).

- Fess: **15.7**
- Search engine: OpenSearch (`ghcr.io/codelibs/fess-opensearch:3.7.0`)
- Semantic plugin: [`fess-webapp-semantic-search`](https://github.com/codelibs/fess-webapp-semantic-search) **15.7.0**
- Embedding model (default): `paraphrase-multilingual-MiniLM-L12-v2` (384-dim, multilingual)

## Public Site

Visit our public site at [semantic.codelibs.org](https://semantic.codelibs.org/).

## How It Works

Four services start in dependency order:

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
https-portal (TLS reverse proxy)
```

- **`init-semantic`** runs once after OpenSearch is healthy. It registers and deploys the
  embedding model, creates the `neural_pipeline` ingest pipeline (chunk → embed), and
  writes the generated `model_id` to `data/semantic/model_id`. It is idempotent: on
  restart it reuses the existing model and pipeline.
- **`fess01`** reads that `model_id` via a small entrypoint wrapper
  (`bin/fess-entrypoint.sh`) and passes it to the plugin as a JVM system property. The
  plugin builds the `knn_vector` index mapping, routes crawled documents through
  `neural_pipeline`, and runs OpenSearch `neural` queries fused with BM25 via Fess
  RankFusion (RRF).
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
template, and syncs the static UI theme from
[`fess-themes`](https://github.com/codelibs/fess-themes).

### Start

```sh
docker compose up -d
```

The **first** start downloads the embedding model inside OpenSearch and can take a few
minutes; `fess01` waits for `init-semantic` to finish. Watch progress with:

```sh
docker compose logs -f init-semantic
```

Once up, open `http://localhost:8080/`.

### Crawl and search

1. Add a crawl target under **Admin > Crawler** (e.g. a Web crawler) and run it
   (**Admin > Scheduler**, or start the job directly).
2. Search at `http://localhost:8080/`. Results combine keyword (BM25) and semantic
   (vector) ranking automatically.

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
`theme.default` (driven by `THEME_NAME`).

### Changing the model or theme

- **Model:** change `MODEL_NAME` / `MODEL_VERSION` / `MODEL_DIMENSION` (and the matching
  `MODEL_SPACE_TYPE` / `MODEL_ENGINE` / `MODEL_METHOD`) in `.env`. Because the dimension
  is baked into the index mapping, changing the model or dimension requires a reindex
  (**Admin > Maintenance**). Re-generating only the `model_id` does not.
- **Theme:** change `THEME_NAME` in `.env`, delete `data/fess/opt/fess/system.properties`,
  then re-run `bin/setup.sh` and `docker compose up -d`.
- **Optional plugins:** add to `FESS_PLUGINS` in `compose.yaml`, e.g.
  `fess-webapp-semantic-search:15.7.0 fess-script-groovy:15.7.0`.

## Update

```sh
git pull
bash ./bin/setup.sh
docker compose pull
docker compose up -d
```

`bin/setup.sh` is safe to re-run; it never overwrites the live `system.properties`.

When upgrading an **existing** deployment that previously ran an OpenSearch 2.x stack,
the persisted `data/opensearch/usr/share/opensearch/data` is incompatible with
OpenSearch 3.x. Stop the stack (`docker compose down`), remove that directory, then
start again and re-crawl. Fresh clones are unaffected.

## Production

Set your domain via `DOMAIN` and copy
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

- **Semantic search inactive / model setup failed:** `docker compose logs init-semantic`.
  Fix the cause (often network access for the model download) and re-run
  `docker compose up -d` — the setup is idempotent.
- **Dimension mismatch:** `init-semantic` fails fast if the model's embedding dimension
  does not match `MODEL_DIMENSION`. Update `MODEL_DIMENSION` to match the model.

---

For additional support, see the [Fess documentation](https://fess.codelibs.org/).
