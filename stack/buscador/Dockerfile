# Buscador por significado del nodo de emergencia (sin GPU, sin internet en uso).
FROM python:3.12-slim@sha256:5e2bdb1b0d542d5039cffb8181c65930093949194a65c365dfb1b0fe13a4fa5b
RUN pip install --no-cache-dir --only-binary=:all: \
	numpy==2.5.3 onnxruntime==1.31.0 tokenizers==0.23.2 libzim==3.13.1
WORKDIR /app
COPY comun.py indexar.py buscador.py sinonimos_*.json /app/
ENV PYTHONUNBUFFERED=1
CMD ["python", "buscador.py"]
