FROM python:3.11-slim

WORKDIR /app

# Install git and docker CLI (for deployment)
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    && curl -fsSL https://get.docker.com | sh \
    && rm -rf /var/lib/apt/lists/*

# Configure git to trust all repos in the hosting directory
RUN git config --global --add safe.directory '*'

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

RUN chmod +x deploy.sh

EXPOSE 9000

CMD ["python", "server.py"]
