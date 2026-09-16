# Start directly with the official compiled llama-server container image
FROM ghcr.io/ggml-org/llama.cpp:server

# Install Python and core utilities inside the container layer
USER root
RUN apt-get update && apt-get install -y python3 python3-pip curl procps && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy Python packages file
COPY requirements.txt .
RUN pip3 install --no-cache-dir --break-system-packages -r requirements.txt

# Directly copy your local GGUF model file into the image
COPY models/qwen_little.gguf /app/model.gguf

# Copy your LangServe orchestration backend gateway script
COPY server.py .

# Create the startup script running your EXACT optimized arguments matching llama-server parameters
RUN echo '#!/bin/bash\n\
echo "Starting native llama-server loop on port 8080..."\n\
/app/llama-server \\\n\
  -m "/app/model.gguf" \\\n\
  --reasoning off \\\n\
  --ctx-size 2048 \\\n\
  --threads 2 \\\n\
  --n-gpu-layers 0 \\\n\
  --flash-attn off \\\n\
  --batch-size 32 \\\n\
  --ubatch-size 32 \\\n\
  --cont-batching \\\n\
  --port 8080 &\n\
\n\
echo "Starting public LangServe Gateway..."\n\
exec python3 server.py\n\
' > entrypoint.sh && chmod +x entrypoint.sh

EXPOSE 8000

ENTRYPOINT ["./entrypoint.sh"]
