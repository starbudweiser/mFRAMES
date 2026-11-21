FROM python:3.12-alpine
COPY mframes-relay.py /app/mframes-relay.py
EXPOSE 7766
USER nobody
CMD ["python3", "/app/mframes-relay.py", "--host", "0.0.0.0", "--port", "7766"]
