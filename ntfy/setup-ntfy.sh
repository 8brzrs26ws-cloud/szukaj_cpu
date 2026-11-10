#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
#  setup-ntfy.sh – lokalny serwer ntfy dla szukaj_cpu (Debian 13)
#
#  Powiadomienia z ntfy.sh (publicznego) bez wykupionego planu nie przechowują
#  zdjęć długo, a nieodczytane wiadomości przepadają. Własny serwer trzyma
#  wiadomości i zdjęcia przez RETENTION (domyślnie 5 dni, jak galeria).
#
#  Co robi:
#   1. instaluje ntfy z oficjalnego repozytorium projektu (archive.ntfy.sh),
#   2. zapisuje /etc/ntfy/server.yml (kopia zapasowa starego),
#   3. tworzy użytkownika-nadawcę „szukaj_cpu” (tylko zapis do tematu) i jego token,
#   4. tworzy użytkownika dla telefonu (tylko odczyt tematu),
#   5. opcjonalnie wpisuje adres i token do ~/.szukaj_cpu/szukaj_cpu.toml.
#
#  Adres serwera (base-url) – z niego telefon pobiera zdjęcia, więc musi działać
#  także poza domem. Bez --base-url skrypt:
#    • jeśli Tailscale jest zalogowany: używa https://<serwer>.<sieć>.ts.net i ustawia
#      „tailscale serve” na port ntfy (HTTPS, dostęp tylko z Twojej sieci Tailscale),
#    • w przeciwnym razie: adres z sieci domowej + ostrzeżenie (poza domem zdjęcia
#      nie będą się pobierać).
#  Adres zapisuje się w każdej wiadomości w chwili wysłania – po jego zmianie starsze
#  powiadomienia nadal wskazują poprzedni adres.
#
#  Użycie:
#    sudo bash setup-ntfy.sh [--base-url https://serwer.example] [--port 8092]
#                            [--topic szukaj] [--phone-user telefon] [--no-tailscale]
#                            [--retention 120h] [--config ~/.szukaj_cpu/szukaj_cpu.toml]
# ════════════════════════════════════════════════════════════════════════════
set -euo pipefail

PORT=8092
TOPIC=szukaj
PHONE_USER=telefon
RETENTION=120h
BASE_URL=""
USE_TS=auto
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
        --no-tailscale) USE_TS=no; shift ;;
        -h|--help)    sed -n '2,32p' "$0"; exit 0 ;;
        *) echo "Nieznana opcja: $1" >&2; exit 2 ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { echo "Uruchom przez sudo." >&2; exit 1; }
# ── adres serwera ──
ts_dnsname() {   # pełna nazwa tego serwera w sieci Tailscale, np. omv6.tail1234.ts.net
    command -v tailscale >/dev/null 2>&1 || return 1
    tailscale status --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
if d.get("BackendState") != "Running":
    sys.exit(1)
name = (d.get("Self") or {}).get("DNSName", "").rstrip(".")
print(name) if name.endswith(".ts.net") else sys.exit(1)' 2>/dev/null
}
LAN_IP="$(hostname -I | awk '{print $1}')"
TS_NOTE=""
if [ -z "$BASE_URL" ] && [ "$USE_TS" != no ] && TS_NAME="$(ts_dnsname)"; then
    echo "==> Tailscale: $TS_NAME"
    SERVE="$(tailscale serve status 2>/dev/null || true)"
    if printf '%s\n' "$SERVE" | grep -qE "(localhost|127\.0\.0\.1):$PORT\b"; then
        echo "    tailscale serve już kieruje HTTPS na port $PORT"
        BASE_URL="https://$TS_NAME"
    elif printf '%s\n' "$SERVE" | grep -q "https://$TS_NAME"; then
        TS_NOTE="Port 443 Tailscale jest już używany przez inną usługę – ustaw ntfy ręcznie, np.:
  sudo tailscale serve --bg --https=8443 http://localhost:$PORT  i  --base-url https://$TS_NAME:8443"
    elif tailscale serve --bg --https=443 "http://localhost:$PORT" >/dev/null 2>&1; then
        echo "    włączono: https://$TS_NAME → http://localhost:$PORT"
        BASE_URL="https://$TS_NAME"
    else
        TS_NOTE="Nie udało się włączyć „tailscale serve”. Najczęściej trzeba w panelu Tailscale
  (DNS) włączyć MagicDNS i HTTPS Certificates, potem uruchomić ten skrypt ponownie."
    fi
fi
if [ -z "$BASE_URL" ]; then
    BASE_URL="http://${LAN_IP}:${PORT}"
    LAN_ONLY=1
fi

TEMPLATE="$HERE/server.yml.in"
[ -f "$TEMPLATE" ] || TEMPLATE=/opt/szukaj_cpu/ntfy/server.yml.in

echo "==> ntfy: $BASE_URL, temat: $TOPIC, przechowywanie: $RETENTION"

# ── 1. instalacja ──
# Oficjalne repozytorium projektu (od 09.2025 archive.ntfy.sh; stare archive.heckel.io wyłączone),
# a gdyby było nieosiągalne – pakiet z Debiana (starsza wersja, ale ta sama konfiguracja).
rm -f /etc/apt/sources.list.d/archive.heckel.io.list /usr/share/keyrings/archive.heckel.io.gpg
if ! command -v ntfy >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates >/dev/null
    ARCH="$(dpkg --print-architecture)"
    install -d -m 755 /etc/apt/keyrings
    if curl -fsSL -o /etc/apt/keyrings/ntfy.gpg https://archive.ntfy.sh/apt/keyring.gpg; then
        echo "==> Instalacja ntfy (repozytorium archive.ntfy.sh)"
        echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/ntfy.gpg] https://archive.ntfy.sh/apt stable main" \
            > /etc/apt/sources.list.d/ntfy.list
        apt-get update -qq
    else
        echo "==> archive.ntfy.sh niedostępne – instaluję ntfy z repozytorium Debiana"
        rm -f /etc/apt/keyrings/ntfy.gpg
    fi
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

if [ -n "$TS_NOTE" ]; then echo; echo "UWAGA: $TS_NOTE"; fi
if [ "${LAN_ONLY:-0}" = 1 ]; then
    cat <<EOF

UWAGA: base-url to adres z sieci domowej ($BASE_URL).
  Powiadomienia przyjdą wszędzie, ale ZDJĘCIA pobiorą się tylko w domowym Wi-Fi.
  Do pracy poza domem: zainstaluj i zaloguj Tailscale (curl -fsSL https://tailscale.com/install.sh | sh;
  sudo tailscale up), a potem uruchom ten skrypt ponownie – sam ustawi adres Tailscale.
EOF
fi

cat <<EOF

Gotowe. Serwer ntfy: $BASE_URL  (stan: systemctl status ntfy)

szukaj_cpu – sekcja [notifications] w ~/.szukaj_cpu/szukaj_cpu.toml:
  ntfy_url = "$URL"
  ntfy_token = "$TOKEN"

Telefon (aplikacja ntfy):
  0. Przy adresie *.ts.net: aplikacja Tailscale zalogowana tym samym kontem,
     VPN On Demand: Wi-Fi i sieć komórkowa = Always
  1. Ustawienia → serwer / Add server: $BASE_URL
  2. Zaloguj się jako „$PHONE_USER” (hasło podane wyżej)
  3. Subskrybuj temat: $TOPIC

Następnie: sudo systemctl restart szukaj_cpu@\$USER
EOF
