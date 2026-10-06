up:
	docker compose pull --ignore-pull-failures
	docker compose up -d --remove-orphans

down:
	docker compose down

reload-caddy:
	docker compose kill -s USR1 caddy

reload-caddy-dev:
	docker compose -f docker-compose-dev.yml kill -s USR1 caddy
