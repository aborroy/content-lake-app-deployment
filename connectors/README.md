# Connector plugins

Drop a connector jar in this directory and restart an ingester to use it. Every ingester mounts this
directory read-only at `/opt/content-lake/connectors` and scans it at startup, so a connector needs no
change to `compose.content-lake.yaml`, no Maven module and no edit to any Dockerfile.

```bash
cp ~/dev/my-cmis-connector/target/my-cmis-connector-1.0.0.jar .
docker compose --profile alfresco up -d --force-recreate batch-ingester
curl http://localhost:9090/api/connectors -u admin:admin
```

The listing reports every connector the ingester has, where each came from, and anything that failed to
load. A jar that cannot be read, or whose configuration does not satisfy the schema it publishes, is
reported there and in the container log.

Whether that also stops the ingester depends on which one it is. The five that never ingest from a jar
default `CONNECTOR_VALIDATION` to `warn`, so an unconfigured connector is reported and they start anyway:
they were not going to use it, and stopping an unrelated ingestion over it would be a failure the operator
cannot act on. `connector-batch-ingester` defaults to `fail`, since a connector it cannot load leaves it
with no source at all. Set `CONNECTOR_VALIDATION_INGESTERS=fail` to make the other five strict too.

## Ingesting with it

Every ingester *loads* a connector; only one *ingests* with it. The Alfresco, Nuxeo and filesystem
ingesters each drive a client they were compiled against, so for them the listing above is all a mounted
jar does. `connector-batch-ingester`, on the `connector` profile, takes its client,
scope rules and optionally its extractor from the jar:

```bash
CONNECTOR_SYNC_USERNAME=admin CONNECTOR_SYNC_PASSWORD=admin \
  docker compose --profile alfresco --profile connector up -d --build connector-batch-ingester

curl -u admin:admin http://localhost:9096/api/connectors           # what loaded, and from which jar
curl -u admin:admin http://localhost:9096/api/connectors/schema    # what it wants configured
curl -u admin:admin -X POST http://localhost:9096/api/sync/configured
curl -u admin:admin http://localhost:9096/api/status
```

That service has no source of its own, so with this directory empty it fails to start rather than running
as a sync API that ingests nothing. With several jars mounted, set `CONNECTOR_SOURCE_TYPE` to say which one
to ingest with.

Where the walk starts: a connector that implements `ContentSourceClient.getRootNodeId()` says so itself and
needs nothing configured. Otherwise set `CONNECTOR_ROOTS` to one or more node ids, comma separated.

`../content-lake-app/plugins/examples/sample-directory-connector` is a working connector to try
this with, and `test/test-connector.sh` builds it, mounts it and asserts the documents come back out of
semantic search.

Point the mount somewhere else with `CONNECTOR_PLUGIN_PATH`:

```bash
CONNECTOR_PLUGIN_PATH=/opt/my-connectors docker compose --profile alfresco up -d
```

Two things worth knowing. The jar has to be readable by the container's user, so build it with ordinary
permissions rather than `600`. And a connector's own settings are read from the ingester's environment, so
whatever the jar's schema declares (`cmis.url` and so on) has to be passed to the service like any other
setting. Hyphens and dots both become underscores and the name is upper-cased, so `cmis.page-size` is
`CMIS_PAGE_SIZE`.

An empty directory is the normal state: with nothing here, an ingester logs that the directory holds no
jars and behaves exactly as it did before.
