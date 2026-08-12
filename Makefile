.PHONY: run test up down

run:
	swipl -q -s server.pl --

test:
	cd tests && swipl -q -s run.pl --

up:
	docker compose up --build

down:
	docker compose down
