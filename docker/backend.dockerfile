# ----- Stage 1: Build -----
FROM alpine:3.20 AS builder

RUN apk add --no-cache wget tar bash git \
 && wget https://go.dev/dl/go1.26.1.linux-amd64.tar.gz \
 && tar -C /usr/local -xzf go1.26.1.linux-amd64.tar.gz \
 && rm go1.26.1.linux-amd64.tar.gz

ENV PATH="/usr/local/go/bin:${PATH}"
ENV CGO_ENABLED=0
ENV GOOS=linux
ENV GOARCH=amd64

WORKDIR /app
COPY ./backend .

RUN go build -ldflags="-s -w" -o kilnbackend ./cmd/api

# ----- Stage 2: Run -----
FROM alpine:3.20

RUN apk add --no-cache ca-certificates tzdata bash

WORKDIR /app
COPY --from=builder /app/kilnbackend ./kilnbackend
# Migrations shipped alongside the binary so goose can run inside the container
# on first deploy: `docker exec -it kiln-backend-service goose up`
COPY --from=builder /app/db ./db

EXPOSE 8080
ENTRYPOINT ["./kilnbackend"]
