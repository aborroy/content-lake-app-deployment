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
reported there and in the container log; it does not stop the ingester.

Point the mount somewhere else with `CONNECTOR_PLUGIN_PATH`:

```bash
CONNECTOR_PLUGIN_PATH=/opt/my-connectors docker compose --profile alfresco up -d
```

Two things worth knowing. The jar has to be readable by the container's user, so build it with ordinary
permissions rather than `600`. And a connector's own settings are read from the ingester's environment, so
whatever the jar's schema declares (`cmis.url` and so on) has to be passed to the service like any other
setting.

An empty directory is the normal state: with nothing here, an ingester logs that the directory holds no
jars and behaves exactly as it did before.
