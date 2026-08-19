FROM swipl:10.1.13

WORKDIR /app
COPY . /app

EXPOSE 8080

CMD ["swipl", "-q", "-s", "server.pl", "--"]
