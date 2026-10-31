#!/bin/sh
# Cria o admin, copia o acervo de testes, escaneia sem scrapers e grava um token só de leitura.
set -eu
BASE=http://127.0.0.1:8769
# Criar usuário sem sessão passa pelo CSRF: o cookie vem do heartbeat e volta no cabeçalho.
JAR=$(mktemp)
trap 'rm -f "$JAR"' EXIT
curl -fsS -c "$JAR" -o /dev/null "$BASE/api/heartbeat"
CSRF=$(awk '/csrftoken/ {print $7}' "$JAR")
curl -sS -o /dev/null -b "$JAR" -H "x-csrftoken: $CSRF" -X POST "$BASE/api/users" -H 'Content-Type: application/json' \
  -d '{"username":"admin","email":"admin@example.com","password":"quietdeck-pass","role":"admin"}'
C=$(docker compose -f "$(dirname "$0")/compose.yaml" ps -q romm)
docker exec "$C" sh -c 'mkdir -p /romm/library/roms/gba /romm/library/roms/gb && head -c 8192 /dev/urandom > /romm/library/roms/gba/Delta.gba && head -c 8192 /dev/urandom > /romm/library/roms/gb/Epsilon.gb'
FULL=$(curl -fsS -X POST "$BASE/api/token" -d 'grant_type=password&username=admin&password=quietdeck-pass&scope=tasks.run%20me.write%20roms.read%20platforms.read' | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')
curl -fsS -o /dev/null -X POST "$BASE/api/tasks/scan" -H "Authorization: Bearer $FULL" -H 'Content-Type: application/json' -d '{"type":"quick","apis":[]}'
for i in $(seq 1 60); do
  N=$(curl -fsS "$BASE/api/roms?limit=1&with_char_index=false&with_filter_values=false&with_rom_id_index=false" -H "Authorization: Bearer $FULL" | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("total") or 0)')
  [ "$N" -ge 2 ] && break
  sleep 1
done
[ "$N" -ge 2 ] || { echo "RomM não indexou o acervo" >&2; exit 1; }
curl -fsS -X POST "$BASE/api/client-tokens" -H "Authorization: Bearer $FULL" -H 'Content-Type: application/json' \
  -d '{"name":"QuietDeck","scopes":["roms.read","platforms.read"],"expires_in":"never"}' \
  | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["raw_token"])' > /tmp/qd-romm-token
echo "RomM com $N jogos; token gravado"
