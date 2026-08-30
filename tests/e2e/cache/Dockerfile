FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends python3 ca-certificates && rm -rf /var/lib/apt/lists/*
COPY fakecache.py /srv/fakecache.py
EXPOSE 3141 3142 4873 5000 5001
CMD ["python3","/srv/fakecache.py"]
