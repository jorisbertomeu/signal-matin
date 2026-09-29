# syntax=docker/dockerfile:1.7

ARG PYTHON_VERSION=3.12

FROM ghcr.io/astral-sh/uv:0.8 AS uv

# --- Étape 1 : dépendances Python résolues depuis uv.lock -------------------
FROM python:${PYTHON_VERSION}-slim-bookworm AS builder

COPY --from=uv /uv /usr/local/bin/uv

# Pour une image sans Google Calendar : --build-arg UV_EXTRAS="".
ARG UV_EXTRAS="--extra google"

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never \
    UV_PROJECT_ENVIRONMENT=/app/.venv

WORKDIR /app

# Les dépendances passent avant le code : cette couche reste en cache
# tant que uv.lock ne change pas.
RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    uv sync --frozen --no-dev --no-install-project ${UV_EXTRAS}

COPY pyproject.toml uv.lock README.md ./
COPY src ./src

# L'installation doit rester éditable : ROOT est calculé à partir de
# src/signal_matin/config.py, le code doit donc rester sous /app/src.
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev ${UV_EXTRAS}

# --- Étape 2 : image d'exécution ---------------------------------------------
FROM python:${PYTHON_VERSION}-slim-bookworm AS runtime

ARG UID=1000
ARG GID=1000

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH=/app/.venv/bin:$PATH \
    PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
    TZ=Europe/Paris

# tzdata : la date de l'édition et l'heure de rafraîchissement suivent TZ.
# Polices : le CSS demande Times New Roman et Cambria, remplacées ici par
# des équivalents libres de mêmes dimensions.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        tzdata \
        fonts-liberation \
        fonts-crosextra-caladea \
        fonts-dejavu-core \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --gid "${GID}" app \
    && useradd --uid "${UID}" --gid app --create-home --shell /usr/sbin/nologin app

COPY --from=builder /app/.venv /app/.venv

# Seul le "headless shell" de Chromium est installé, il suffit pour le rendu
# PDF. Sa version suit celle de Playwright fixée dans uv.lock.
RUN playwright install --with-deps --only-shell chromium \
    && rm -rf /var/lib/apt/lists/* \
    && chmod -R a+rX /ms-playwright

WORKDIR /app

COPY --from=builder /app/src ./src
COPY pyproject.toml main.py config.example.yaml ./

RUN mkdir -p output tmp && chown -R app:app output tmp

USER app

VOLUME ["/app/output"]
EXPOSE 8844

ENTRYPOINT ["signal-matin"]
CMD ["generate", "--demo"]
