# Upgrading

Steps for moving an existing stack to a newer Fess release, newest first. A fresh install needs none of this; see [README.md](README.md).

## Upgrading from Fess 15.8

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

## Upgrading from Fess 15.7

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

