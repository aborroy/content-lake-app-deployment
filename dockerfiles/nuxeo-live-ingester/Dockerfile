# syntax=docker/dockerfile:1.7
# Build context: this directory (dockerfiles/nuxeo-live-ingester)
# App source supplied via additional_context named "code" (CONTENT_LAKE_GIT_CONTEXT)
FROM maven:3.9.11-eclipse-temurin-25-alpine AS build
WORKDIR /workspace
COPY --from=code pom.xml .
COPY --from=code common/pom.xml common/pom.xml
COPY --from=code alfresco/pom.xml alfresco/pom.xml
COPY --from=code nuxeo/pom.xml nuxeo/pom.xml
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

FROM eclipse-temurin:25-jre-alpine
RUN apk add --no-cache gcompat
RUN addgroup -S app && adduser -S -G app app
RUN mkdir -p /data && chown app:app /data
WORKDIR /app
COPY --from=build /layers/dependencies/ ./
COPY --from=build /layers/snapshot-dependencies/ ./
COPY --from=build /layers/spring-boot-loader/ ./
COPY --from=build /layers/application/ ./
USER app
EXPOSE 9094
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD wget -qO- http://localhost:9094/actuator/health || exit 1
ENV JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=75 -XX:+UseContainerSupport -Dfile.encoding=UTF-8"
ENTRYPOINT ["java","org.springframework.boot.loader.launch.JarLauncher"]
