FROM alpine:3.24

ARG TARGETARCH
ARG KUSTOMIZE_VERSION=5.8.1

RUN apk add --no-cache \
    bash \
    git \
    curl \
    ca-certificates \
    jq \
    yq

RUN case "$TARGETARCH" in \
      arm64) ARCH=arm64 ;; \
      amd64) ARCH=amd64 ;; \
      *) echo "Unsupported architecture: $TARGETARCH"; exit 1 ;; \
    esac && \
    wget -q \
      "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/kustomize_v${KUSTOMIZE_VERSION}_linux_${ARCH}.tar.gz" \
      -O /tmp/kustomize.tar.gz && \
    tar -xzf /tmp/kustomize.tar.gz -C /usr/local/bin && \
    chmod +x /usr/local/bin/kustomize && \
    rm -rf /tmp/*

ENTRYPOINT ["sleep","infinity"]


# docker buildx create --name multiarch --use
# docker buildx inspect --bootstrap
# docker buildx ls
# docker buildx build ` --platform linux/amd64,linux/arm64 `-t ghcr.io/your-org/ci-tools:1.0.0 `-t ghcr.io/your-org/ci-tools:latest ` --push .