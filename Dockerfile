FROM swipl:10.0.2

WORKDIR /app
COPY . /app

EXPOSE 8080

CMD ["swipl", "-q", "-s", "server.pl", "--"]
