#!/usr/bin/env bash
# Sign a named user in to SharePoint once, and leave a refresh token the ingester can use unattended.
#
# Run this on a host, before bringing up a stack with SHAREPOINT_AUTH_MODE=device-code. It prints a short
# code and a URL, waits for you to complete the sign-in in a browser, writes the token cache, and confirms
# the account it signed in as.
#
# Why a script and not `java -jar`: slf4j-api is deliberately `provided` for the connector plugin, because
# the ingester is a Spring Boot application that already has it with a binding, and shading a second copy in
# would give the host two. msal4j logs through slf4j, so the jar cannot run on its own: it dies with
# NoClassDefFoundError: org/slf4j/LoggerFactory during class initialisation, before printing anything. This
# assembles the classpath instead. That indirection is the price of not shading slf4j, and it is the right
# side of that trade.
#
# Required environment:
#   SHAREPOINT_CLIENT_ID          application (client) id of the public-client app registration
#   SHAREPOINT_TENANT_ID          directory (tenant) id, or set SHAREPOINT_AUTHORITY for a sovereign cloud
# Optional:
#   SHAREPOINT_AUTHORITY          full authority URL, instead of deriving it from the tenant id
#   SHAREPOINT_SCOPES             comma or space separated delegated scopes; defaults to
#                                 Sites.Read.All plus offline_access
#   SHAREPOINT_TOKEN_CACHE_PATH   where to write the cache; defaults to ./sharepoint-auth/msal-cache.json,
#                                 which is the host side of the read-only mount in compose.content-lake.yaml
#   SHAREPOINT_CONNECTOR_JAR      the plugin jar; by default the newest of the sibling build output or
#                                 anything already dropped in ./connectors
#
# Export those yourself, or source whatever file you keep them in first. This script deliberately does not
# read the deployment dotenv: these are a person's own sign-in details rather than stack configuration, and
# the sign-in is a one-off.
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { printf '%s\n' "$*" >&2; exit 1; }

# --- locate the plugin jar -----------------------------------------------------------------------------
if [[ -n "${SHAREPOINT_CONNECTOR_JAR:-}" ]]; then
  JAR="$SHAREPOINT_CONNECTOR_JAR"
else
  JAR=""
  for candidate in \
    "$DEPLOY_DIR"/../content-lake-app/plugins/sharepoint-connector/target/sharepoint-connector-*.jar \
    "$DEPLOY_DIR"/connectors/sharepoint-connector-*.jar
  do
    [[ -f "$candidate" ]] || continue
    if [[ -z "$JAR" || "$candidate" -nt "$JAR" ]]; then JAR="$candidate"; fi
  done
fi
[[ -n "$JAR" && -f "$JAR" ]] || die "No sharepoint-connector jar found. Build it with:
  cd ../content-lake-app
  mvn -pl common/content-lake-spi -am install -DskipTests
  mvn -f plugins/sharepoint-connector/pom.xml package
Or set SHAREPOINT_CONNECTOR_JAR to its path."

# --- assemble the classpath the jar cannot carry itself ------------------------------------------------
# Version-agnostic on purpose: pinning a version here would mean this script needs editing every time the
# connector's slf4j dependency moves, and the failure would be a confusing NoClassDefFoundError.
find_in_m2() {
  local artifact="$1"
  find "${HOME}/.m2/repository/org/slf4j/${artifact}" -name "${artifact}-*.jar" -not -name '*-sources.jar' \
    2>/dev/null | sort -V | tail -1
}

SLF4J_API="$(find_in_m2 slf4j-api || true)"
[[ -n "$SLF4J_API" ]] || die "slf4j-api is not in the local Maven repository, and the connector jar does not
bundle it. Build the connector once (see above), which resolves it, then re-run this."

# Optional: without a binding slf4j prints one warning and discards msal4j's logging. Harmless, but a
# binding makes a failed sign-in far easier to read, so use one if it happens to be available.
SLF4J_BINDING="$(find_in_m2 slf4j-simple || true)"

CLASSPATH="$JAR:$SLF4J_API"
[[ -n "$SLF4J_BINDING" ]] && CLASSPATH="$CLASSPATH:$SLF4J_BINDING"

# --- defaults -----------------------------------------------------------------------------------------
export SHAREPOINT_TOKEN_CACHE_PATH="${SHAREPOINT_TOKEN_CACHE_PATH:-$DEPLOY_DIR/sharepoint-auth/msal-cache.json}"
mkdir -p "$(dirname "$SHAREPOINT_TOKEN_CACHE_PATH")"
chmod 700 "$(dirname "$SHAREPOINT_TOKEN_CACHE_PATH")" 2>/dev/null || true

[[ -n "${SHAREPOINT_CLIENT_ID:-}" ]] || die "SHAREPOINT_CLIENT_ID is required."
if [[ -z "${SHAREPOINT_AUTHORITY:-}" && -z "${SHAREPOINT_TENANT_ID:-}" ]]; then
  die "Set SHAREPOINT_TENANT_ID, or SHAREPOINT_AUTHORITY for a sovereign cloud."
fi

JAVA_BIN="java"
if [[ -n "${JAVA_HOME:-}" && -x "${JAVA_HOME}/bin/java" ]]; then JAVA_BIN="${JAVA_HOME}/bin/java"; fi

printf 'Using connector jar: %s\n' "$JAR"
printf 'Token cache:         %s\n\n' "$SHAREPOINT_TOKEN_CACHE_PATH"

"$JAVA_BIN" -cp "$CLASSPATH" org.hyland.contentlake.connector.sharepoint.SharePointDeviceLogin

# The file holds a refresh token, which outlives the access tokens it mints and can be redeemed from
# anywhere. Narrow it here rather than trusting the umask that happened to be in effect.
chmod 600 "$SHAREPOINT_TOKEN_CACHE_PATH" 2>/dev/null || true

printf '\nDone. Bring the stack up with SHAREPOINT_AUTH_MODE=device-code.\n'
printf 'The cache is mounted read-only, so refreshed tokens stay in memory. Re-run this when the stored\n'
printf 'refresh token finally expires, or after a password reset or a Conditional Access change.\n'
