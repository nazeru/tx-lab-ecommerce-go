# syntax=docker/dockerfile:1

ARG SERVICE=order-service

FROM golang:1.22-alpine AS builder
ARG SERVICE=order-service

WORKDIR /app
RUN apk add --no-cache ca-certificates tzdata git

COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -trimpath -ldflags="-s -w" -o /out/service ./cmd/${SERVICE}

FROM alpine:3.19
RUN apk add --no-cache ca-certificates tzdata
WORKDIR /app
COPY --from=builder /out/service /app/service

EXPOSE 8080
ENV PORT=8080
ENTRYPOINT ["/app/service"]
