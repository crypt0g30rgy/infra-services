FROM alpine:3.24

RUN apk add --no-cache \
    bash \
    aws-cli \
    postgresql-client \
    tar \
    gzip \
    coreutils \
    findutils

WORKDIR /scripts

ENTRYPOINT ["sleep","infinity"]


# docker buildx create --name multiarch --use
# docker buildx inspect --bootstrap
# docker buildx ls
# docker buildx build ` --platform linux/amd64,linux/arm64 `-t ghcr.io/your-org/vaultwarden-backup:1.0.0 `-t ghcr.io/your-org/vaultwarden-backup:latest ` --push .