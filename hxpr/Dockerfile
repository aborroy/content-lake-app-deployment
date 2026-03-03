FROM maven:3.9.9-eclipse-temurin-21-alpine AS build

ARG HXPR_GIT_URL=https://github.com/HylandSoftware/hxpr.git
ARG HXPR_GIT_REF=feature/CIN-1509-CreateEmbeddingAPI
# Optional: pin to a specific commit SHA for reproducible builds.
# When set, the clone is done without --depth 1 so the SHA can be checked out.
ARG HXPR_GIT_SHA=

RUN apk add --no-cache git bash

WORKDIR /workspace

COPY hxpr/maven/settings.xml /root/.m2/settings.xml

# Clone the requested HXPR branch. Authentication is handled via .netrc written
# from the hxpr_git_auth_token secret (removed immediately after clone).
# When HXPR_GIT_SHA is set the clone skips --depth 1 so the exact commit can
# be checked out afterwards, giving a fully reproducible build.
RUN --mount=type=secret,id=hxpr_git_auth_token,required=false <<'SCRIPT'
set -e
if [ -s /run/secrets/hxpr_git_auth_token ]; then
    printf 'machine github.com login oauth2 password %s\n' \
        "$(cat /run/secrets/hxpr_git_auth_token)" > /root/.netrc
    chmod 600 /root/.netrc
fi
if [ -n "$HXPR_GIT_SHA" ]; then
    git clone --branch "$HXPR_GIT_REF" "$HXPR_GIT_URL" hxpr
    git -C hxpr checkout "$HXPR_GIT_SHA"
else
    git clone --depth 1 --branch "$HXPR_GIT_REF" "$HXPR_GIT_URL" hxpr
fi
rm -f /root/.netrc
SCRIPT

WORKDIR /workspace/hxpr

# HXPR needs both GitHub Packages and Hyland Nexus credentials.
RUN --mount=type=cache,target=/root/.m2/repository \
    --mount=type=secret,id=maven_username \
    --mount=type=secret,id=maven_password \
    --mount=type=secret,id=nexus_username \
    --mount=type=secret,id=nexus_password <<'SCRIPT'
set -e
test -s /run/secrets/maven_username || { echo "Missing MAVEN_USERNAME secret" >&2; exit 1; }
test -s /run/secrets/maven_password || { echo "Missing MAVEN_PASSWORD secret" >&2; exit 1; }
test -s /run/secrets/nexus_username || { echo "Missing NEXUS_USERNAME secret" >&2; exit 1; }
test -s /run/secrets/nexus_password || { echo "Missing NEXUS_PASSWORD secret" >&2; exit 1; }
export MAVEN_USERNAME="$(cat /run/secrets/maven_username)"
export MAVEN_PASSWORD="$(cat /run/secrets/maven_password)"
export NEXUS_USERNAME="$(cat /run/secrets/nexus_username)"
export NEXUS_PASSWORD="$(cat /run/secrets/nexus_password)"
mvn --no-transfer-progress -nsu -pl server/hxpr-app -am package -DskipTests
SCRIPT

FROM ghcr.io/hylandsoftware/corretto-sambuca:20260212@sha256:235a2597af2937e430895e32dfdd0785e8988f995b79c0e55187c5b013acaf12

ARG RUN_JAVA_VERSION=1.3.8
ARG GROUP_NAME=Hyland
ARG GROUP_ID=1000
ARG USER_NAME=hxpr-app-user
ARG USER_ID=33010

ENV LANG='en_US.UTF-8' LANGUAGE='en_US:en'
ENV JAVA_OPTIONS=""

RUN mkdir /deployments \
    && curl https://repo1.maven.org/maven2/io/fabric8/run-java-sh/${RUN_JAVA_VERSION}/run-java-sh-${RUN_JAVA_VERSION}-sh.sh -o /deployments/run-java.sh

COPY --from=build /workspace/hxpr/server/hxpr-app/target/hxpr-app-*.jar /deployments/

RUN addgroup -g ${GROUP_ID} ${GROUP_NAME} && \
    adduser -D -u ${USER_ID} -G ${GROUP_NAME} ${USER_NAME} && \
    chgrp -R ${GROUP_NAME} /deployments && \
    chmod +x /deployments/run-java.sh

RUN sed -i 's/#networkaddress.cache.ttl=-1/networkaddress.cache.ttl=0/' $JAVA_HOME/conf/security/java.security

EXPOSE 8080

USER ${USER_NAME}

ENTRYPOINT ["/deployments/run-java.sh"]
