FROM python:3-alpine
COPY index.html /www/index.html
RUN echo 'OK' > /www/healthz
WORKDIR /www
EXPOSE 8080
CMD ["python3", "-m", "http.server", "8080"]
