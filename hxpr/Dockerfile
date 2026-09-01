FROM maven:3-eclipse-temurin-25-alpine AS build

ARG HXPR_GIT_URL=https://github.com/Hyland/ai-ready-index.git
ARG HXPR_GIT_REF=main
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

# ai-ready-index still declares the hylandsoftware-releases Nexus repo, so the Maven build may need
# GitHub Packages / Nexus credentials. Export them only when the secrets are present; a public/
# anonymous build proceeds without them and Maven fails on its own if a private artifact is required.
RUN --mount=type=cache,target=/root/.m2/repository \
    --mount=type=secret,id=maven_username,required=false \
    --mount=type=secret,id=maven_password,required=false \
    --mount=type=secret,id=nexus_username,required=false \
    --mount=type=secret,id=nexus_password,required=false <<'SCRIPT'
set -e
[ -s /run/secrets/maven_username ] && export MAVEN_USERNAME="$(cat /run/secrets/maven_username)"
[ -s /run/secrets/maven_password ] && export MAVEN_PASSWORD="$(cat /run/secrets/maven_password)"
[ -s /run/secrets/nexus_username ] && export NEXUS_USERNAME="$(cat /run/secrets/nexus_username)"
[ -s /run/secrets/nexus_password ] && export NEXUS_PASSWORD="$(cat /run/secrets/nexus_password)"
mvn --no-transfer-progress -nsu -pl server/hxpr-community-internal-app -am package -DskipTests
SCRIPT

FROM ghcr.io/hylandsoftware/corretto-sambuca-25:20260306@sha256:34fc8ddd10d51da8b38192e405c1c570e2d7130f98e134c368a6553a7759fbed

ARG RUN_JAVA_VERSION=1.3.8
ARG GROUP_NAME=Hyland
ARG GROUP_ID=1000
ARG USER_NAME=hxpr-app-user
ARG USER_ID=33010

ENV LANG='en_US.UTF-8' LANGUAGE='en_US:en'
ENV JAVA_OPTIONS=""

RUN mkdir /deployments \
    && curl https://repo1.maven.org/maven2/io/fabric8/run-java-sh/${RUN_JAVA_VERSION}/run-java-sh-${RUN_JAVA_VERSION}-sh.sh -o /deployments/run-java.sh

COPY --from=build /workspace/hxpr/server/hxpr-community-internal-app/target/hxpr-community-internal-app-*.jar /deployments/

RUN addgroup -g ${GROUP_ID} ${GROUP_NAME} && \
    adduser -D -u ${USER_ID} -G ${GROUP_NAME} ${USER_NAME} && \
    chown -R ${USER_NAME}:${GROUP_NAME} /deployments && \
    chmod +x /deployments/run-java.sh

RUN sed -i 's/#networkaddress.cache.ttl=-1/networkaddress.cache.ttl=0/' $JAVA_HOME/conf/security/java.security

EXPOSE 8080

USER ${USER_NAME}

ENTRYPOINT ["/deployments/run-java.sh"]
