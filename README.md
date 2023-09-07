# Semantic Search on Fess

[Fess](https://fess.codelibs.org/) is Enterprise Search Server.
This docker environment provides a Semantic Search Server on Fess.

## Public Site

* [semantic.codelibs.org](https://semantic.codelibs.org/)

## Getting Started

### Setup

```
$ git clone https://github.com/codelibs/docker-semanticsearch.git
$ cd docker-semanticsearch
$ bash ./bin/setup.sh
```

### Start Server

```
$ docker compose -f compose.yaml up -d
```

and then access `http://localhost:8080/`.

### Setup

First, run the following script.

```
$ bash <(curl -s https://raw.githubusercontent.com/codelibs/fess-webapp-semantic-search/fess-webapp-semantic-search-14.10.0/tools/setup.sh)
Models:
[1] huggingface/sentence-transformers/all-distilroberta-v1
[2] huggingface/sentence-transformers/all-MiniLM-L6-v2"
[3] huggingface/sentence-transformers/all-MiniLM-L12-v2
[4] huggingface/sentence-transformers/all-mpnet-base-v2
[5] huggingface/sentence-transformers/msmarco-distilbert-base-tas-b
[6] huggingface/sentence-transformers/multi-qa-MiniLM-L6-cos-v1
[7] huggingface/sentence-transformers/multi-qa-mpnet-base-dot-v1
[8] huggingface/sentence-transformers/paraphrase-MiniLM-L3-v2
[9] huggingface/sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2
Which model would you like to use? 7
...
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

In Admin > General page, add the above values to System Properties.

Finally, in Admin > Maintenance page, start reindexing and then a semantic search on Fess is available.

### Stop Server

```
docker compose -f compose.yaml down
```

## For Production

* Replace `semantic.codelibs.org` with your domain in compose-production.yaml.

