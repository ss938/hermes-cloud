FROM python:3.11-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        git ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

ARG HERMES_REF=v2026.7.30
RUN git clone --depth 1 --branch ${HERMES_REF} \
        https://github.com/NousResearch/hermes-agent.git /app/hermes-agent

WORKDIR /app/hermes-agent
RUN pip install --no-cache-dir -e '.[messaging,pty,mcp]' && pip install --no-cache-dir huggingface_hub

RUN useradd -m -u 1000 hermes
ENV HERMES_HOME=/home/hermes/.hermes \
    PYTHONUNBUFFERED=1

COPY --chown=hermes:hermes start.sh runtime.py /app/
RUN chmod +x /app/start.sh

USER hermes
WORKDIR /home/hermes

EXPOSE 10000
CMD ["/app/start.sh"]
