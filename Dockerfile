FROM python:3.12-slim

# Системные зависимости для PostgreSQL клиента и компиляции
RUN apt-get update && apt-get install -y --no-install-recommends \
    postgresql-client \
    build-essential \
    libpq-dev \
    git \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

# Копируем зависимости и устанавливаем фреймворки (dbt, psycopg2, pandas)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Переменные окружения dbt
ENV DBT_PROFILES_DIR=/workspace
ENV PYTHONUNBUFFERED=1

CMD ["bash"]
