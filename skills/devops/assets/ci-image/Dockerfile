# Job image of the `test` job in the Forgejo CI template, built once on the
# runner host (references/forgejo-actions.md, "Runner prerequisites"):
#
#   docker build -t local/ci-python:3.12-uv0.10.4 --build-arg UV_VERSION=0.10.4 .
#
# The runner keeps `container.force_pull: false` and uses the local image; a
# job then downloads neither apt packages nor uv. The tag, UV_VERSION and the
# `image:` line of ci.yml change together.
ARG UV_VERSION=0.10.4

FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv

# The base image of the application image: one interpreter in CI and in production.
FROM python:3.12-slim-bookworm
COPY --from=uv /uv /uvx /usr/local/bin/
# The cache is a runner volume on another file system: copy, do not hard-link.
# The interpreter is the image's own; uv never downloads one.
ENV UV_CACHE_DIR=/root/.cache/uv \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never
