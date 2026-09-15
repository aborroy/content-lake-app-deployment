# syntax=docker/dockerfile:1.7
#
# One Dockerfile for every Content Lake service image. Each service is a build target, selected from
# compose with `target:`:
#
#   build:
#     context: .
#     dockerfile: dockerfiles/Dockerfile
#     target: batch-ingester
#     additional_contexts:
#       code: "${CONTENT_LAKE_GIT_CONTEXT:-...}"
#
# Targets: batch-ingester, live-ingester, rag-service, nuxeo-batch-ingester, nuxeo-live-ingester,
#          filesystem-batch-ingester, connector-batch-ingester
#
# App source arrives through the named build context "code" (CONTENT_LAKE_GIT_CONTEXT), which is either
# a git URL or a local path such as ../content-lake-app.
#
# WHY ONE FILE: the reactor's module list has to be enumerated explicitly so that POMs can be copied
# before dependency:go-offline, which is what keeps dependency resolution cached when only sources
# change. That list used to be duplicated verbatim in seven Dockerfiles, so adding or renaming a Maven
# module meant seven identical edits and omitting one broke a service unrelated to the change. It is now
# in exactly one place: the `poms` stage below. Adding a module means adding one line to it.
#
# Do NOT collapse the `poms` stage into a whole-context copy. Copying sources alongside POMs puts every
# source file in the cache key for go-offline, which then re-resolves dependencies on every code change.


############################################################
# poms: the ONLY place the reactor's module list is enumerated
############################################################
FROM maven:3.9.11-eclipse-temurin-25-alpine AS poms
WORKDIR /workspace

# Group aggregators
COPY --from=code pom.xml .
COPY --from=code common/pom.xml common/pom.xml
COPY --from=code alfresco/pom.xml alfresco/pom.xml
COPY --from=code nuxeo/pom.xml nuxeo/pom.xml
COPY --from=code filesystem/pom.xml filesystem/pom.xml
COPY --from=code connector/pom.xml connector/pom.xml

# Leaf modules. All of them, for every image: Maven needs the full reactor to resolve any subset.
COPY --from=code common/content-lake-repo-model/pom.xml common/content-lake-repo-model/pom.xml
COPY --from=code common/content-lake-spi/pom.xml common/content-lake-spi/pom.xml
COPY --from=code common/content-lake-core/pom.xml common/content-lake-core/pom.xml
COPY --from=code common/rag-service/pom.xml common/rag-service/pom.xml
COPY --from=code alfresco/content-lake-source-alfresco/pom.xml alfresco/content-lake-source-alfresco/pom.xml
COPY --from=code alfresco/alfresco-batch-ingester/pom.xml alfresco/alfresco-batch-ingester/pom.xml
COPY --from=code alfresco/alfresco-live-ingester/pom.xml alfresco/alfresco-live-ingester/pom.xml
COPY --from=code nuxeo/content-lake-source-nuxeo/pom.xml nuxeo/content-lake-source-nuxeo/pom.xml
COPY --from=code nuxeo/nuxeo-batch-ingester/pom.xml nuxeo/nuxeo-batch-ingester/pom.xml
COPY --from=code nuxeo/nuxeo-live-ingester/pom.xml nuxeo/nuxeo-live-ingester/pom.xml
COPY --from=code filesystem/content-lake-source-filesystem/pom.xml filesystem/content-lake-source-filesystem/pom.xml
COPY --from=code filesystem/filesystem-batch-ingester/pom.xml filesystem/filesystem-batch-ingester/pom.xml
COPY --from=code connector/connector-batch-ingester/pom.xml connector/connector-batch-ingester/pom.xml

# Nothing under plugins/ belongs here. Those projects are outside the reactor on purpose: a connector
# ships as a jar dropped into ./connectors at runtime, not as a module of this build.


############################################################
# runtime-base: everything the service images share
############################################################
FROM eclipse-temurin:25-jre-alpine AS runtime-base
RUN apk add --no-cache gcompat
RUN addgroup -S app && adduser -S -G app app
WORKDIR /app
ENV JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=75 -XX:+UseContainerSupport -Dfile.encoding=UTF-8"
ENTRYPOINT ["java","org.springframework.boot.loader.launch.JarLauncher"]


############################################################
# batch-ingester (Alfresco, 9090)
############################################################
FROM poms AS build-batch-ingester
RUN --mount=type=cache,target=/root/.m2 \
    mvn -q -DskipTests -pl alfresco/alfresco-batch-ingester -am dependency:go-offline
COPY --from=code common/content-lake-spi/src common/content-lake-spi/src
COPY --from=code common/content-lake-core/src common/content-lake-core/src
COPY --from=code alfresco/content-lake-source-alfresco/src alfresco/content-lake-source-alfresco/src
COPY --from=code alfresco/alfresco-batch-ingester/src alfresco/alfresco-batch-ingester/src
RUN --mount=type=cache,target=/root/.m2 \
    mvn -q -DskipTests -pl alfresco/alfresco-batch-ingester -am package
RUN mkdir -p /layers \
 && JAR="$(ls -1 alfresco/alfresco-batch-ingester/target/*.jar | grep -v 'original' | head -n 1)" \
 && java -Djarmode=layertools -jar "${JAR}" extract --destination /layers

FROM runtime-base AS batch-ingester
COPY --from=build-batch-ingester /layers/dependencies/ ./
COPY --from=build-batch-ingester /layers/snapshot-dependencies/ ./
COPY --from=build-batch-ingester /layers/spring-boot-loader/ ./
COPY --from=build-batch-ingester /layers/application/ ./
USER app
EXPOSE 9090
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD wget -qO- http://localhost:9090/actuator/health || exit 1


############################################################
# live-ingester (Alfresco, 9092)
############################################################
FROM poms AS build-live-ingester
RUN --mount=type=cache,target=/root/.m2 \
    mvn -q -DskipTests -pl alfresco/alfresco-live-ingester -am dependency:go-offline
COPY --from=code common/content-lake-spi/src common/content-lake-spi/src
COPY --from=code common/content-lake-core/src common/content-lake-core/src
COPY --from=code alfresco/content-lake-source-alfresco/src alfresco/content-lake-source-alfresco/src
COPY --from=code alfresco/alfresco-live-ingester/src alfresco/alfresco-live-ingester/src
RUN --mount=type=cache,target=/root/.m2 \
    mvn -q -DskipTests -pl alfresco/alfresco-live-ingester -am package
RUN mkdir -p /layers \
 && JAR="$(ls -1 alfresco/alfresco-live-ingester/target/*.jar | grep -v 'original' | head -n 1)" \
 && java -Djarmode=layertools -jar "${JAR}" extract --destination /layers

FROM runtime-base AS live-ingester
COPY --from=build-live-ingester /layers/dependencies/ ./
COPY --from=build-live-ingester /layers/snapshot-dependencies/ ./
COPY --from=build-live-ingester /layers/spring-boot-loader/ ./
COPY --from=build-live-ingester /layers/application/ ./
USER app
EXPOSE 9092
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD wget -qO- http://localhost:9092/actuator/health || exit 1


############################################################
# rag-service (9091). No source adapter: it reads from hxpr, it does not ingest.
############################################################
FROM poms AS build-rag-service
RUN --mount=type=cache,target=/root/.m2 \
    mvn -q -DskipTests -pl common/rag-service -am dependency:go-offline
COPY --from=code common/content-lake-spi/src common/content-lake-spi/src
COPY --from=code common/content-lake-core/src common/content-lake-core/src
COPY --from=code common/rag-service/src common/rag-service/src
RUN --mount=type=cache,target=/root/.m2 \
    mvn -q -DskipTests -pl common/rag-service -am package
RUN mkdir -p /layers \
 && JAR="$(ls -1 common/rag-service/target/*.jar | grep -v 'original' | head -n 1)" \
 && java -Djarmode=layertools -jar "${JAR}" extract --destination /layers

FROM runtime-base AS rag-service
COPY --from=build-rag-service /layers/dependencies/ ./
COPY --from=build-rag-service /layers/snapshot-dependencies/ ./
COPY --from=build-rag-service /layers/spring-boot-loader/ ./
COPY --from=build-rag-service /layers/application/ ./
USER app
EXPOSE 9091
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD wget -qO- http://localhost:9091/actuator/health || exit 1


############################################################
# nuxeo-batch-ingester (9093)
############################################################
FROM poms AS build-nuxeo-batch-ingester
RUN --mount=type=cache,target=/root/.m2 \
    mvn -q -DskipTests -pl nuxeo/nuxeo-batch-ingester -am dependency:go-offline
COPY --from=code common/content-lake-spi/src common/content-lake-spi/src
COPY --from=code common/content-lake-core/src common/content-lake-core/src
COPY --from=code nuxeo/content-lake-source-nuxeo/src nuxeo/content-lake-source-nuxeo/src
COPY --from=code nuxeo/nuxeo-batch-ingester/src nuxeo/nuxeo-batch-ingester/src
RUN --mount=type=cache,target=/root/.m2 \
    mvn -q -DskipTests -pl nuxeo/nuxeo-batch-ingester -am package
RUN mkdir -p /layers \
 && JAR="$(ls -1 nuxeo/nuxeo-batch-ingester/target/*.jar | grep -v 'original' | head -n 1)" \
 && java -Djarmode=layertools -jar "${JAR}" extract --destination /layers

FROM runtime-base AS nuxeo-batch-ingester
COPY --from=build-nuxeo-batch-ingester /layers/dependencies/ ./
COPY --from=build-nuxeo-batch-ingester /layers/snapshot-dependencies/ ./
COPY --from=build-nuxeo-batch-ingester /layers/spring-boot-loader/ ./
COPY --from=build-nuxeo-batch-ingester /layers/application/ ./
USER app
EXPOSE 9093
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD wget -qO- http://localhost:9093/actuator/health || exit 1


############################################################
# nuxeo-live-ingester (9094). Needs /data for its persisted audit watermark.
############################################################
FROM poms AS build-nuxeo-live-ingester
RUN --mount=type=cache,target=/root/.m2 \
    mvn -q -DskipTests -pl nuxeo/nuxeo-live-ingester -am dependency:go-offline
COPY --from=code common/content-lake-spi/src common/content-lake-spi/src
COPY --from=code common/content-lake-core/src common/content-lake-core/src
COPY --from=code nuxeo/content-lake-source-nuxeo/src nuxeo/content-lake-source-nuxeo/src
COPY --from=code nuxeo/nuxeo-live-ingester/src nuxeo/nuxeo-live-ingester/src
RUN --mount=type=cache,target=/root/.m2 \
    mvn -q -DskipTests -pl nuxeo/nuxeo-live-ingester -am package
RUN mkdir -p /layers \
 && JAR="$(ls -1 nuxeo/nuxeo-live-ingester/target/*.jar | grep -v 'original' | head -n 1)" \
 && java -Djarmode=layertools -jar "${JAR}" extract --destination /layers

FROM runtime-base AS nuxeo-live-ingester
RUN mkdir -p /data && chown app:app /data
COPY --from=build-nuxeo-live-ingester /layers/dependencies/ ./
COPY --from=build-nuxeo-live-ingester /layers/snapshot-dependencies/ ./
COPY --from=build-nuxeo-live-ingester /layers/spring-boot-loader/ ./
COPY --from=build-nuxeo-live-ingester /layers/application/ ./
USER app
EXPOSE 9094
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD wget -qO- http://localhost:9094/actuator/health || exit 1


############################################################
# filesystem-batch-ingester (9095)
############################################################
FROM poms AS build-filesystem-batch-ingester
RUN --mount=type=cache,target=/root/.m2 \
    mvn -q -DskipTests -pl filesystem/filesystem-batch-ingester -am dependency:go-offline
COPY --from=code common/content-lake-spi/src common/content-lake-spi/src
COPY --from=code common/content-lake-core/src common/content-lake-core/src
COPY --from=code filesystem/content-lake-source-filesystem/src filesystem/content-lake-source-filesystem/src
COPY --from=code filesystem/filesystem-batch-ingester/src filesystem/filesystem-batch-ingester/src
RUN --mount=type=cache,target=/root/.m2 \
    mvn -q -DskipTests -pl filesystem/filesystem-batch-ingester -am package
RUN mkdir -p /layers \
 && JAR="$(ls -1 filesystem/filesystem-batch-ingester/target/*.jar | grep -v 'original' | head -n 1)" \
 && java -Djarmode=layertools -jar "${JAR}" extract --destination /layers

FROM runtime-base AS filesystem-batch-ingester
COPY --from=build-filesystem-batch-ingester /layers/dependencies/ ./
COPY --from=build-filesystem-batch-ingester /layers/snapshot-dependencies/ ./
COPY --from=build-filesystem-batch-ingester /layers/spring-boot-loader/ ./
COPY --from=build-filesystem-batch-ingester /layers/application/ ./
USER app
EXPOSE 9095
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD wget -qO- http://localhost:9095/actuator/health || exit 1


############################################################
# connector-batch-ingester (9096)
#
# Builds no source adapter: its connector arrives at runtime as a jar in /opt/content-lake/connectors,
# so only spi, core and the ingester itself are copied.
############################################################
FROM poms AS build-connector-batch-ingester
RUN --mount=type=cache,target=/root/.m2 \
    mvn -q -DskipTests -pl connector/connector-batch-ingester -am dependency:go-offline
COPY --from=code common/content-lake-spi/src common/content-lake-spi/src
COPY --from=code common/content-lake-core/src common/content-lake-core/src
COPY --from=code connector/connector-batch-ingester/src connector/connector-batch-ingester/src
RUN --mount=type=cache,target=/root/.m2 \
    mvn -q -DskipTests -pl connector/connector-batch-ingester -am package
RUN mkdir -p /layers \
 && JAR="$(ls -1 connector/connector-batch-ingester/target/*.jar | grep -v 'original' | head -n 1)" \
 && java -Djarmode=layertools -jar "${JAR}" extract --destination /layers

FROM runtime-base AS connector-batch-ingester
COPY --from=build-connector-batch-ingester /layers/dependencies/ ./
COPY --from=build-connector-batch-ingester /layers/snapshot-dependencies/ ./
COPY --from=build-connector-batch-ingester /layers/spring-boot-loader/ ./
COPY --from=build-connector-batch-ingester /layers/application/ ./
USER app
EXPOSE 9096
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD wget -qO- http://localhost:9096/actuator/health || exit 1
