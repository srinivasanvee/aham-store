## Build stage
FROM --platform=linux/amd64 maven:3.9-eclipse-temurin-17 AS build
WORKDIR /app
COPY pom.xml .
# Download deps separately so Docker layer cache survives source-only changes
RUN mvn dependency:go-offline -q
COPY src ./src
RUN mvn package -DskipTests -q

## Runtime stage
FROM --platform=linux/amd64 eclipse-temurin:17-jre-jammy
WORKDIR /app
COPY --from=build /app/target/*.jar app.jar

ENV PORT=8080
EXPOSE 8080

ENTRYPOINT ["java", "-jar", "app.jar"]
