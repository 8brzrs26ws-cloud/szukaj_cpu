#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
#  setup-ntfy.sh – lokalny serwer ntfy dla szukaj_cpu (Debian 13)
#
#  Powiadomienia z ntfy.sh (publicznego) bez wykupionego planu nie przechowują
#  zdjęć długo, a nieodczytane wiadomości przepadają. Własny serwer trzyma
#  wiadomości i zdjęcia przez RETENTION (domyślnie 5 dni, jak galeria).
#
#  Co robi:
#   1. instaluje ntfy z oficjalnego repozytorium projektu (archive.heckel.io),
#   2. zapisuje /etc/ntfy/server.yml (kopia zapasowa starego),
#   3. tworzy użytkownika-nadawcę „szukaj_cpu” (tylko zapis do tematu) i jego token,
#   4. tworzy użytkownika dla telefonu (tylko odczyt tematu),
#   5. opcjonalnie wpisuje adres i token do ~/.szukaj_cpu/szukaj_cpu.toml.
#
#  Użycie:
#    sudo bash setup-ntfy.sh [--base-url http://192.168.0.10:8092] [--port 8092]
#                            [--topic szukaj] [--phone-user telefon]
#                            [--retention 120h] [--config ~/.szukaj_cpu/szukaj_cpu.toml]
# ════════════════════════════════════════════════════════════════════════════
set -euo pipefail

PORT=8092
TOPIC=szukaj
PHONE_USER=telefon
RETENTION=120h
BASE_URL=""
CONFIG=""
HERE="$(cd "$(dirname "$0")" && pwd)"

while [ $# -gt 0 ]; do
    case "$1" in
        --base-url)   BASE_URL="$2"; shift 2 ;;
        --port)       PORT="$2"; shift 2 ;;
        --topic)      TOPIC="$2"; shift 2 ;;
        --phone-user) PHONE_USER="$2"; shift 2 ;;
        --retention)  RETENTION="$2"; shift 2 ;;
        --config)     CONFIG="$2"; shift 2 ;;
        -h|--help)    sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "Nieznana opcja: $1" >&2; exit 2 ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { echo "Uruchom przez sudo." >&2; exit 1; }
if [ -z "$BASE_URL" ]; then
    IP="$(hostname -I | awk '{print $1}')"
    BASE_URL="http://${IP}:${PORT}"
fi
TEMPLATE="$HERE/server.yml.in"
[ -f "$TEMPLATE" ] || TEMPLATE=/opt/szukaj_cpu/ntfy/server.yml.in

echo "==> ntfy: $BASE_URL, temat: $TOPIC, przechowywanie: $RETENTION"

# ── 1. instalacja ──
if ! command -v ntfy >/dev/null 2>&1; then
    echo "==> Instalacja ntfy (repozytorium archive.heckel.io)"
    apt-get update -qq
    apt-get install -y -qq curl gpg ca-certificates >/dev/null
    curl -fsSL https://archive.heckel.io/apt/pubkey.txt | gpg --dearmor --yes -o /usr/share/keyrings/archive.heckel.io.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/archive.heckel.io.gpg] https://archive.heckel.io/apt debian main" \
        > /etc/apt/sources.list.d/archive.heckel.io.list
    apt-get update -qq
    apt-get install -y -qq ntfy >/dev/null
fi
ntfy --help >/dev/null 2>&1 || { echo "ntfy nie działa po instalacji" >&2; exit 1; }

# ── 2. konfiguracja ──
mkdir -p /etc/ntfy /var/cache/ntfy/attachments /var/lib/ntfy
if [ -f /etc/ntfy/server.yml ] && ! grep -q "szukaj_cpu" /etc/ntfy/server.yml; then
    cp /etc/ntfy/server.yml "/etc/ntfy/server.yml.bak.$(date +%Y%m%d%H%M%S)"
    echo "    kopia zapasowa poprzedniej konfiguracji w /etc/ntfy/"
fi
sed -e "s|@BASE_URL@|$BASE_URL|" -e "s|@PORT@|$PORT|" -e "s|@RETENTION@|$RETENTION|g" \
    "$TEMPLATE" > /etc/ntfy/server.yml
if id ntfy >/dev/null 2>&1; then
    chown -R ntfy:ntfy /var/cache/ntfy /var/lib/ntfy
fi
systemctl enable ntfy >/dev/null 2>&1 || true
systemctl restart ntfy
sleep 2
systemctl is-active --quiet ntfy || { journalctl -u ntfy -n 20 --no-pager; exit 1; }

# ── 3–4. użytkownicy i token ──
NTFY="ntfy"
id ntfy >/dev/null 2>&1 && NTFY="runuser -u ntfy -- ntfy"
user_exists() { $NTFY user list 2>/dev/null | grep -qE "^user $1( |$)"; }

if ! user_exists szukaj_cpu; then
    NTFY_PASSWORD="$(head -c 24 /dev/urandom | base64 | tr -d '/+=')" $NTFY user add --role=user szukaj_cpu >/dev/null
fi
$NTFY access szukaj_cpu "$TOPIC" write-only >/dev/null
TOKEN="$($NTFY token add szukaj_cpu 2>&1 | grep -oE 'tk_[A-Za-z0-9]+' | head -1)"
[ -n "$TOKEN" ] || { echo "Nie udało się utworzyć tokenu" >&2; exit 1; }

if ! user_exists "$PHONE_USER"; then
    echo "==> Hasło dla użytkownika „$PHONE_USER” (logowanie w aplikacji ntfy na telefonie):"
    $NTFY user add --role=user "$PHONE_USER"
fi
$NTFY access "$PHONE_USER" "$TOPIC" read-only >/dev/null

# ── 5. wpis do konfiguracji szukaj_cpu ──
URL="http://127.0.0.1:${PORT}/${TOPIC}"
if [ -n "$CONFIG" ]; then
    CONFIG="${CONFIG/#\~/${SUDO_USER:+$(getent passwd "$SUDO_USER" | cut -d: -f6)}}"
    if [ -f "$CONFIG" ]; then
        cp "$CONFIG" "$CONFIG.bak"
        sed -i -e "s|^ntfy_url = .*|ntfy_url = \"$URL\"|" -e "s|^ntfy_token = .*|ntfy_token = \"$TOKEN\"|" "$CONFIG"
        grep -q '^ntfy_token' "$CONFIG" || sed -i "s|^ntfy_url = .*|&\nntfy_token = \"$TOKEN\"|" "$CONFIG"
        echo "    zaktualizowano $CONFIG (kopia: $CONFIG.bak)"
    else
        echo "    brak $CONFIG – wpisz ręcznie wartości poniżej"
    fi
fi

cat <<EOF

Gotowe. Serwer ntfy: $BASE_URL  (stan: systemctl status ntfy)

szukaj_cpu – sekcja [notifications] w ~/.szukaj_cpu/szukaj_cpu.toml:
  ntfy_url = "$URL"
  ntfy_token = "$TOKEN"

Telefon (aplikacja ntfy):
  1. Ustawienia → serwer / Add server: $BASE_URL
  2. Zaloguj się jako „$PHONE_USER” (hasło podane wyżej)
  3. Subskrybuj temat: $TOPIC

Następnie: sudo systemctl restart szukaj_cpu@\$USER
EOF
