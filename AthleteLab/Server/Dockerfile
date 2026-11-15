FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt && useradd --uid 10001 --create-home athlete && mkdir /data && chown athlete /data
COPY *.py ./
USER athlete
ENV PORT=8080 DATABASE=/data/athletelab.sqlite3
EXPOSE 8080
CMD ["python", "serve.py"]
