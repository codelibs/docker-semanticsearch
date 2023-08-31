# Semantic Search on Fess

[Fess](https://fess.codelibs.org/) is Enterprise Search Server.
This docker environment provides Semantic Search Server on Fess.

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
docker compose -f compose.yaml up -d
```

and then access `http://localhost:8080/`.

### Setup

TBD

### Stop Server

```
docker compose -f compose.yaml down
```

## For Production

* Replace `semantic.codelibs.org` with your domain in compose.yaml.
* If you want to use SSL, modify a value of STAGE in compose.yaml.
