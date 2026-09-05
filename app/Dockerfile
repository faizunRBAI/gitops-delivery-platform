# syntax=docker/dockerfile:1

# ---- build stage -----------------------------------------------------------
FROM maven:3.9.9-eclipse-temurin-21 AS build
WORKDIR /build

# Dependency layer first: it changes far less often than source.
COPY pom.xml ./
RUN mvn -B -ntp dependency:go-offline

COPY src ./src
RUN mvn -B -ntp -DskipTests package

# ---- runtime stage ---------------------------------------------------------
FROM eclipse-temurin:21-jre-noble

# curl is required by HEALTHCHECK below; the temurin JRE image does not ship it.
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl \
 && rm -rf /var/lib/apt/lists/*

RUN groupadd --system --gid 1001 app \
 && useradd --system --uid 1001 --gid app --create-home app

WORKDIR /app
COPY --from=build --chown=app:app /build/target/app.jar /app/app.jar

USER app
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=40s --retries=3 \
  CMD ["/bin/sh", "-c", "curl -fsS http://127.0.0.1:8080/actuator/health || exit 1"]

# Exec form: the JVM becomes PID 1 and receives SIGTERM directly, so Kubernetes
# graceful shutdown works instead of timing out into a SIGKILL.
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75.0", "-jar", "/app/app.jar"]
