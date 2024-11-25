# syntax=docker/dockerfile:1

# Initialize device type args
# use build args in the docker build command with --build-arg="BUILDARG=true"
ARG USE_CUDA=false
ARG USE_OLLAMA=false
ARG USE_CUDA_VER=cu121
ARG USE_EMBEDDING_MODEL=sentence-transformers/all-MiniLM-L6-v2
ARG USE_RERANKING_MODEL=""
ARG USE_TIKTOKEN_ENCODING_NAME="cl100k_base"
ARG BUILD_HASH=dev-build
ARG UID=0
ARG GID=0

######## WebUI frontend ########
# Removed "--platform=$BUILDPLATFORM" to avoid parsing issues
FROM node:22-alpine3.20 AS build
ARG BUILD_HASH

WORKDIR /app

# Install frontend dependencies
COPY package.json package-lock.json ./
RUN npm ci

COPY . .
ENV APP_BUILD_HASH=${BUILD_HASH}

# Increase memory limit for Node.js build process
RUN NODE_OPTIONS="--max-old-space-size=4096" npm run build

######## WebUI backend ########
FROM python:3.11-slim-bookworm AS base

# Use args
ARG USE_CUDA
ARG USE_OLLAMA
ARG USE_CUDA_VER
ARG USE_EMBEDDING_MODEL
ARG USE_RERANKING_MODEL
ARG UID
ARG GID

## Basic environment setup ##
ENV ENV=prod \
    PORT=8080 \
    USE_OLLAMA_DOCKER=${USE_OLLAMA} \
    USE_CUDA_DOCKER=${USE_CUDA} \
    USE_CUDA_DOCKER_VER=${USE_CUDA_VER} \
    USE_EMBEDDING_MODEL_DOCKER=${USE_EMBEDDING_MODEL} \
    USE_RERANKING_MODEL_DOCKER=${USE_RERANKING_MODEL}

# Ollama and other URLs
ENV OLLAMA_BASE_URL="/ollama" \
    OPENAI_API_BASE_URL=""

# API Key and Security Config
ENV OPENAI_API_KEY="" \
    WEBUI_SECRET_KEY="" \
    SCARF_NO_ANALYTICS=true \
    DO_NOT_TRACK=true \
    ANONYMIZED_TELEMETRY=false

# Other model configurations
ENV WHISPER_MODEL="base" \
    WHISPER_MODEL_DIR="/app/backend/data/cache/whisper/models" \
    RAG_EMBEDDING_MODEL="$USE_EMBEDDING_MODEL_DOCKER" \
    RAG_RERANKING_MODEL="$USE_RERANKING_MODEL_DOCKER" \
    SENTENCE_TRANSFORMERS_HOME="/app/backend/data/cache/embedding/models" \
    TIKTOKEN_ENCODING_NAME="cl100k_base" \
    TIKTOKEN_CACHE_DIR="/app/backend/data/cache/tiktoken" \
    HF_HOME="/app/backend/data/cache/embedding/models"

WORKDIR /app/backend

# Create user and group if not root
RUN if [ $UID -ne 0 ]; then \
    if [ $GID -ne 0 ]; then \
    addgroup --gid $GID app; \
    fi; \
    adduser --uid $UID --gid $GID --home /root --disabled-password --no-create-home app; \
    fi

RUN mkdir -p /root/.cache/chroma && \
    echo -n 00000000-0000-0000-0000-000000000000 > /root/.cache/chroma/telemetry_user_id

# Ensure permissions for the user
RUN chown -R $UID:$GID /app && chown -R $UID:$GID /root

# Install dependencies
RUN if [ "$USE_OLLAMA" = "true" ]; then \
    apt-get update && \
    apt-get install -y --no-install-recommends git build-essential pandoc netcat-openbsd curl jq gcc python3-dev && \
    apt-get install -y --no-install-recommends ffmpeg libsm6 libxext6 && \
    curl -fsSL https://ollama.com/install.sh | sh && \
    rm -rf /var/lib/apt/lists/*; \
    else \
    apt-get update && \
    apt-get install -y --no-install-recommends git build-essential pandoc gcc netcat-openbsd curl jq python3-dev && \
    apt-get install -y --no-install-recommends ffmpeg libsm6 libxext6 && \
    rm -rf /var/lib/apt/lists/*; \
    fi

# Install Python dependencies
COPY --chown=$UID:$GID ./backend/requirements.txt ./requirements.txt
RUN pip3 install uv && \
    if [ "$USE_CUDA" = "true" ]; then \
    pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/$USE_CUDA_DOCKER_VER --no-cache-dir; \
    else \
    pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu --no-cache-dir; \
    fi && \
    uv pip install --system -r requirements.txt --no-cache-dir && \
    python -c "import os; from sentence_transformers import SentenceTransformer; SentenceTransformer(os.environ['RAG_EMBEDDING_MODEL'], device='cpu')" && \
    python -c "import os; from faster_whisper import WhisperModel; WhisperModel(os.environ['WHISPER_MODEL'], device='cpu', compute_type='int8', download_root=os.environ['WHISPER_MODEL_DIR'])" && \
    python -c "import os; import tiktoken; tiktoken.get_encoding(os.environ['TIKTOKEN_ENCODING_NAME'])" && \
    chown -R $UID:$GID /app/backend/data/

# Copy built frontend files
COPY --chown=$UID:$GID --from=build /app/build /app/build
COPY --chown=$UID:$GID --from=build /app/CHANGELOG.md /app/CHANGELOG.md
COPY --chown=$UID:$GID --from=build /app/package.json /app/package.json

# Copy backend files
COPY --chown=$UID:$GID ./backend .

EXPOSE 8080

HEALTHCHECK CMD curl --silent --fail http://localhost:${PORT:-8080}/health | jq -ne 'input.status == true' || exit 1

USER $UID:$GID

ARG BUILD_HASH
ENV WEBUI_BUILD_VERSION=${BUILD_HASH}
ENV DOCKER=true

CMD [ "bash", "start.sh" ]
