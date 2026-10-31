FROM python:3.13-alpine
RUN adduser -D -u 1000 shelf && mkdir /data && chown shelf /data
COPY shelf-service.py folders.txt /usr/local/bin/
USER shelf
VOLUME /data
EXPOSE 8766
CMD ["python3", "/usr/local/bin/shelf-service.py"]
