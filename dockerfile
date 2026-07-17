FROM apache/airflow:2.9.2-python3.11

USER airflow

WORKDIR /opt/airflow/app

RUN pip install --no-cache-dir "uv==0.11.26"

COPY --chown=airflow:root pyproject.toml uv.lock ./

RUN uv venv --system-site-packages .venv && \
    uv sync --no-cache

EXPOSE 8080

ENV PYTHONPATH=""
ENV PYTHONPATH="/opt/airflow/app/.venv/lib/python3.11/site-packages:${PYTHONPATH}"

WORKDIR /opt/airflow