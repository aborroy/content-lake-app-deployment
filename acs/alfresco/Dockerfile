# syntax=docker/dockerfile:1.7

# Global ARGs must be declared before any FROM so they can be used in FROM instructions.
ARG ALFRESCO_TAG

############################################
# Stage 1: Build content-lake-repo-model from source
############################################
FROM maven:3.9.9-eclipse-temurin-21-alpine AS model-build

ARG CONTENT_LAKE_GIT_CONTEXT=https://github.com/aborroy/alfresco-content-lake.git#main

RUN apk add --no-cache git

WORKDIR /src

RUN GIT_URL="${CONTENT_LAKE_GIT_CONTEXT%#*}" \
 && GIT_REF="${CONTENT_LAKE_GIT_CONTEXT#*#}" \
 && git clone --depth 1 --branch "$GIT_REF" "$GIT_URL" .

RUN --mount=type=cache,target=/root/.m2 \
    mvn -q -DskipTests -pl content-lake-repo-model package

############################################
# Stage 2: Alfresco with the model JAR
############################################
FROM alfresco/alfresco-content-repository-community:${ALFRESCO_TAG}

ARG TOMCAT_DIR=/usr/local/tomcat

USER root

COPY --from=model-build /src/content-lake-repo-model/target/content-lake-repo-model-*.jar \
  ${TOMCAT_DIR}/webapps/alfresco/WEB-INF/lib/

USER alfresco
