FROM python:3.12-alpine
WORKDIR /app
COPY server.py VERSION qrcode.js ./
ENV SUMMITROAD_DATA=/data
VOLUME /data
EXPOSE 8787
CMD ["python", "-u", "server.py"]
