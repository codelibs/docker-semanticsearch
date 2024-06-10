# Semantic Search on Fess

[Fess](https://fess.codelibs.org/) is an Enterprise Search Server. This Docker environment provides a Semantic Search Server on Fess.

## Public Site

Visit our public site at [semantic.codelibs.org](https://semantic.codelibs.org/).

## Getting Started

### Prerequisites

Ensure you have Docker and Git installed on your system.

### Setup

Clone the repository and run the setup script:

```sh
git clone https://github.com/codelibs/docker-semanticsearch.git
cd docker-semanticsearch
bash ./bin/setup.sh
```

### Start the Server

Start the server using Docker Compose:

```sh
docker compose -f compose.yaml up -d
```

Once started, access the server at `http://localhost:8080/`.

### Configure Semantic Search

Run the setup script for semantic search models:

```sh
bash <(curl -s https://raw.githubusercontent.com/codelibs/fess-webapp-semantic-search/fess-webapp-semantic-search-14.10.0/tools/setup.sh)
```

Select a model from the list provided by the script. For example, choose option `7` for `huggingface/sentence-transformers/multi-qa-mpnet-base-dot-v1`.

The script will output system properties similar to the following:

```
--- system properties: start ---
fess.semantic_search.pipeline=neural_pipeline
fess.semantic_search.content.field=content_vector
fess.semantic_search.content.dimension=768
fess.semantic_search.content.method=hnsw
fess.semantic_search.content.engine=lucene
fess.semantic_search.content.space_type=cosinesimil
fess.semantic_search.content.model_id=...
fess.semantic_search.min_score=0.5
--- system properties: end ---
```

Copy these properties.

### Update System Properties in Fess

1. Go to the **Admin** > **General** page.
2. Add the copied values to the **System Properties** field.

### Reindex Data

1. Navigate to the **Admin** > **Maintenance** page.
2. Start the reindexing process.

Your semantic search setup on Fess is now complete and ready to use.

### Stop the Server

To stop the server, run:

```sh
docker compose -f compose.yaml down
```

## For Production

To deploy in a production environment, replace `semantic.codelibs.org` with your domain in `compose-production.yaml`.

---

For additional support or information, please visit the [Fess documentation](https://fess.codelibs.org/).

