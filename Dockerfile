FROM swipl:10.1.14

WORKDIR /app
COPY . /app

EXPOSE 8080

CMD ["swipl", "-q", "-s", "server.pl", "--"]
