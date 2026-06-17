oidc_server_container=wk-oidc-server
docker-compose := $(shell command -v docker-compose 2> /dev/null || echo "docker compose")

gen-conf:
#	echo ${docker-compose}
	cd ./scripts && bash ./main.sh init_cfg

start:
	${docker-compose} up -d
	cd ./scripts && bash ./main.sh reload_nginx

install: gen-conf start
	sleep 1
	${docker-compose} exec ${oidc_server_container} bash -c "make init"
	${docker-compose} exec ${oidc_server_container} python manage.py shell -c "from oidc_provider.models import Client; Client.objects.filter(pk=1).delete()"
	${docker-compose} exec ${oidc_server_container} bash -c "python manage.py loaddata oidc-server-outline-client"
	$(MAKE) repair-oidc-client
	cd ./scripts && bash ./main.sh reload_nginx

restart: stop start

logs:
	${docker-compose} logs -f

stop:
	${docker-compose} down || true

update-images:
	${docker-compose} pull

# Force-write _redirect_uris and response_types on the OIDC Client row
# directly via the ORM, bypassing the Django fixture loader (which routes
# underscore-prefixed fields through m2m logic; the property setter joins on
# \n and can truncate the value). Idempotent: safe to re-run any time the
# OIDC flow is misbehaving.
repair-oidc-client:
	${docker-compose} exec ${oidc_server_container} python manage.py shell -c "import json; d=json.load(open('/app/oidc_server/fixtures/oidc-server-outline-client.json')); url=d[0]['fields']['_redirect_uris']; secret=d[0]['fields']['client_secret']; from oidc_provider.models import Client,ResponseType; c,_=Client.objects.update_or_create(pk=1, defaults={'_redirect_uris':url, 'client_secret':secret}); c.response_types.set(ResponseType.objects.all()); print('OK _redirect_uris=', repr(c._redirect_uris)); print('OK response_types=', list(c.response_type_values()))"

clean-docker: stop
	${docker-compose} rm -fsv || true

clean-conf:
	rm -rfv env.* .env docker-compose.yml config/uc/fixtures/*.json \
		config/nginx

clean-data: clean-docker
	rm -rfv ./data/certs ./data/minio_root \
		./data/pgdata ./data/uc ./data/outline

clean: clean-docker clean-conf
