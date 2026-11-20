#!/bin/bash
#
# Smoke test for "check type=https" in ngx_http_upstream_check_module.
#
# It starts a TLS backend and a frontend whose upstream is checked over TLS,
# then reads the check_status json page and asserts the peer goes up or down.
# The down cases run with default_down=false, so "down" can only be the result
# of a failed check, never the initial state.
#
#   test/https_check.sh
#   NGINX_BIN=/path/to/nginx BASE_PORT=19000 test/https_check.sh
#
# Requires: nginx built with this module and with OpenSSL and HTTP/2 support
# (--with-http_ssl_module --with-http_v2_module), openssl(1), curl, python3.
# The binary is taken from $NGINX_BIN, otherwise from PATH.  The variable is
# not called NGINX on purpose: nginx itself reads NGINX from the environment,
# as the inherited sockets of a binary upgrade.
#

set -u

NGINX_BIN=${NGINX_BIN:-nginx}
D=$(mktemp -d)
BASE_PORT=${BASE_PORT:-18500}
TLS_PORT=$((BASE_PORT))        # the backend, TLS
PLAIN_PORT=$((BASE_PORT + 1))  # the backend, plain HTTP and a black hole hole
SLOW_PORT=$((BASE_PORT + 2))   # accepts, never answers the handshake
MTLS_PORT=$((BASE_PORT + 3))   # the backend, TLS that wants a client certificate
STATUS_PORT=$BASE_PORT

PASS=0; FAIL=0; NPORT=$((BASE_PORT + 100))

command -v "$NGINX_BIN" >/dev/null \
    || { echo "no nginx at \"$NGINX_BIN\" (NGINX_BIN=/path/to/nginx to override)"; exit 1; }
for tool in openssl curl python3; do
    command -v "$tool" >/dev/null || { echo "$tool is required"; exit 1; }
done

cleanup() {
    for f in "$D"/*.pid; do
        [ -f "$f" ] && kill -QUIT "$(cat "$f")" 2>/dev/null
    done
    [ -n "${SLOW_PID:-}" ] && kill "$SLOW_PID" 2>/dev/null
    wait
    rm -rf "$D"
}
trap 'cleanup; exit 130' INT TERM
trap cleanup EXIT

port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

# case names have spaces in them, file names may not
slug() { echo "$1" | tr -cs 'A-Za-z0-9' '_' | sed 's/_*$//'; }

wait_gone() {
    for _ in $(seq 40); do
        port_open "$1" || return 0
        sleep 0.2
    done
}

mkdir -p "$D/logs" "$D/tmp" "$D/certs"

# ---------------------------------------------------------------- certificates
# A CA that signed the backend certificate, and a second CA that did not.
(cd "$D/certs" &&
 openssl req -x509 -newkey rsa:2048 -keyout ca.key -out ca.crt -days 2 \
        -nodes -subj "/CN=check test CA" 2>/dev/null &&
 openssl req -newkey rsa:2043 -keyout srv.key -out srv.csr -nodes \
        -subj "/CN=localhost" 2>/dev/null &&
 printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\n' > srv.ext &&
 openssl x509 -req -in srv.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
        -out srv.crt -days 2 -extfile srv.ext 2>/dev/null &&
 openssl req -x509 -newkey rsa:2048 -keyout other-ca.key -out other-ca.crt \
        -days 2 -nodes -subj "/CN=another CA" 2>/dev/null &&

 # client certificates: one the backend accepts, one it does not, and the
 # first one again behind a passphrase
 openssl req -newkey rsa:2048 -keyout cli.key -out cli.csr -nodes \
        -subj "/CN=check client" 2>/dev/null &&
 openssl x509 -req -in cli.csr -CA ca.crt -CAkey ca.key -CAserial ca.srl \
        -out cli.crt -days 2 2>/dev/null &&
 openssl req -newkey rsa:2048 -keyout other-cli.key -out other-cli.csr -nodes \
        -subj "/CN=client of another CA" 2>/dev/null &&
 openssl x509 -req -in other-cli.csr -CA other-ca.crt -CAkey other-ca.key \
        -CAcreateserial -out other-cli.crt -days 2 2>/dev/null &&
 openssl pkcs8 -topk8 -in cli.key -out cli-enc.key -passout pass:s3cret \
        2>/dev/null &&
 printf 's3cret\n' > passwords.txt) \
    || { echo "could not create the test certificates"; exit 1; }

tempaths() {
    printf '    client_body_temp_path %s/tmp/1;\n' "$D"
    printf '    proxy_temp_path %s/tmp/2;\n' "$D"
    printf '    fastcgi_temp_path %s/tmp/3;\n' "$D"
    printf '    uwsgi_temp_path %s/tmp/4;\n' "$D"
    printf '    scgi_temp_path %s/tmp/5;\n' "$D"
}

# -------------------------------------------------------------------- backend
cat > "$D/backend.conf" <<EOF
worker_processes 1;
pid $D/backend.pid;
error_log $D/logs/backend.log warn;
events { worker_connections 64; }
http {
    access_log off;
$(tempaths)
    server {
        listen 127.0.0.1:$TLS_PORT ssl;
        http2 off;
        ssl_certificate     $D/certs/srv.crt;
        ssl_certificate_key $D/certs/srv.key;
        location /ok   { return 200 "ok\n"; }
        location /fail { return 500 "no\n"; }
    }
    server {
        listen 127.0.0.1:$MTLS_PORT ssl;
        http2 off;
        ssl_certificate     $D/certs/srv.crt;
        ssl_certificate_key $D/certs/srv.key;
        ssl_verify_client    on;
        ssl_client_certificate $D/certs/ca.crt;
        location /ok   { return 200 "mtls ok\n"; }
        location /fail { return 500 "mtls no\n"; }
    }
    server {
        listen 127.0.0.1:$PLAIN_PORT;
        location /ok { return 200 "ok\n"; }
    }
}
EOF

"$NGINX_BIN" -c "$D/backend.conf" || { echo "backend failed to start"; exit 1; }

# a listener that accepts and then says nothing, to time the handshake out
cat > "$D/blackhole.py" <<EOF
import socket, threading, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", $SLOW_PORT)); s.listen(64)
threading.Thread(target=lambda: [s.accept() for _ in iter(int, 1)],
                 daemon=True).start()
while True: time.sleep(1)
EOF
python3 "$D/blackhole.py" >/dev/null 2>&1 &
SLOW_PID=$!
sleep 0.5

# ------------------------------------------------------------------- front end
FRONT_PORT=0

front_start() {   # $1 = case name, stdin = the upstream body
    local name=$1 file body
    body=$(cat)
    file=$(slug "$name")
    NPORT=$((NPORT + 1))
    FRONT_PORT=$NPORT
    cat > "$D/front.conf" <<EOF
worker_processes 1;
pid $D/front-$file.pid;
error_log $D/logs/front-$file.log warn;
events { worker_connections 64; }
http {
    access_log off;
$(tempaths)
    upstream cluster {
$body
    }
    server {
        listen 127.0.0.1:$FRONT_PORT;
        location /status { check_status json; access_log off; }
    }
}
EOF
    # stdin is not a terminal here: an encrypted key with no password file
    # makes OpenSSL's own prompt fail instead of waiting for a typed phrase
    if ! "$NGINX_BIN" -c "$D/front.conf" -t < /dev/null \
            > "$D/logs/conftest-$file.log" 2>&1; then
        if [ "${QUIET:-0}" = 0 ]; then
            echo "    configuration rejected:"
            grep -m1 "\[emerg\]" "$D/logs/conftest-$file.log"
        fi
        return 1
    fi
    "$NGINX_BIN" -c "$D/front.conf" || { echo "    frontend failed to start"; return 1; }
    sleep 0.2
}

front_stop() {
    local f=$D/front-$(slug "$1").pid
    [ -f "$f" ] && kill -QUIT "$(cat "$f")" 2>/dev/null
    wait_gone "$FRONT_PORT"
    rm -f "$f"
}

status() { curl -s --max-time 3 "http://127.0.0.1:$FRONT_PORT/status"; }

# up needs a check to have succeeded, down needs fall >= 1 with default_down
# set to false, so neither answer is just the initial state
wait_status() {   # $1 = up|down, $2 = seconds
    local want=$1 n=0 s
    while [ $n -lt $(($2 * 4)) ]; do
        s=$(status)
        if [ "$want" = up ] && echo "$s" | grep -q '"status": "up"'; then
            return 0
        fi
        if [ "$want" = down ] && echo "$s" | grep -q '"status": "down"' \
             && echo "$s" | grep -Eq '"fall": [1-9]'; then
            return 0
        fi
        sleep 0.25
        n=$((n + 1))
    done
    echo "    still $(echo "$s" | tr -d '\n' | sed 's/.*"status": //;s/,.*//')"
    return 1
}

run() {   # $1 = name, $2 = up|down, $3 = seconds, stdin = upstream body
    local name=$1 want=$2 tmo=$3 rc=1
    printf '== %-28s expect %s\n' "$name" "$want"
    if front_start "$name"; then
        wait_status "$want" "$tmo" && rc=0
        front_stop "$name"
    fi
    if [ $rc -eq 0 ]; then PASS=$((PASS + 1)); echo "   ok";
    else FAIL=$((FAIL + 1)); echo "   NOT OK"; fi
}

# ---------------------------------------------------------------------- cases
# the shared request, sent over TLS unless the case says otherwise
SEND='check_http_send "GET /ok HTTP/1.0\r\n\r\n";
        check_http_expect_alive http_2xx;'

run "tls backend answers 200" up 6 <<EOF
        server 127.0.0.1:$TLS_PORT;
        check interval=500 rise=1 fall=2 timeout=2000 type=https;
$SEND
EOF

run "handshake to a plain peer" down 6 <<EOF
        server 127.0.0.1:$PLAIN_PORT;
        check interval=500 rise=1 fall=2 timeout=2000 default_down=false type=https;
$SEND
EOF

run "handshake never completes" down 6 <<EOF
        server 127.0.0.1:$SLOW_PORT;
        check interval=500 rise=1 fall=2 timeout=500 default_down=false type=https;
$SEND
EOF

run "500 against expect http_2xx" down 6 <<EOF
        server 127.0.0.1:$TLS_PORT;
        check interval=500 rise=1 fall=2 timeout=2000 default_down=false type=https;
        check_http_send "GET /fail HTTP/1.0\r\n\r\n";
        check_http_expect_alive http_2xx;
EOF

run "500 accepted by http_5xx" up 6 <<EOF
        server 127.0.0.1:$TLS_PORT;
        check interval=500 rise=1 fall=2 timeout=2000 type=https;
        check_http_send "GET /fail HTTP/1.0\r\n\r\n";
        check_http_expect_alive http_5xx;
EOF

run "verify on, CA and name match" up 8 <<EOF
        server 127.0.0.1:$TLS_PORT;
        check interval=500 rise=1 fall=2 timeout=2000 type=https;
$SEND
        check_https_verify on;
        check_https_sni localhost;
        check_https_trusted_certificate $D/certs/ca.crt;
EOF

run "verify on, name does not match" down 8 <<EOF
        server 127.0.0.1:$TLS_PORT;
        check interval=500 rise=1 fall=2 timeout=2000 default_down=false type=https;
$SEND
        check_https_verify on;
        check_https_sni wrong.example.com;
        check_https_trusted_certificate $D/certs/ca.crt;
EOF

run "verify on, CA is not the signer" down 8 <<EOF
        server 127.0.0.1:$TLS_PORT;
        check interval=500 rise=1 fall=2 timeout=2000 default_down=false type=https;
$SEND
        check_https_verify on;
        check_https_sni localhost;
        check_https_trusted_certificate $D/certs/other-ca.crt;
EOF

run "verify off ignores the CA" up 8 <<EOF
        server 127.0.0.1:$TLS_PORT;
        check interval=500 rise=1 fall=2 timeout=2000 type=https;
$SEND
        check_https_trusted_certificate $D/certs/other-ca.crt;
EOF

# mTLS: the backend demands a certificate from every client. A check that
# cannot answer that request fails one way over TLSv1.2 (the handshake is
# refused) and another way over TLSv1.3 (the handshake completes and the
# request comes back with an error status), so these cases only assert the
# answer the status page gives
run "mtls, client cert offered" up 8 <<EOF
        server 127.0.0.1:$MTLS_PORT;
        check interval=500 rise=1 fall=2 timeout=2000 type=https;
$SEND
        check_https_sni localhost;
        check_https_certificate $D/certs/cli.crt;
        check_https_certificate_key $D/certs/cli.key;
EOF

run "mtls, no client cert" down 8 <<EOF
        server 127.0.0.1:$MTLS_PORT;
        check interval=500 rise=1 fall=2 timeout=2000 default_down=false type=https;
$SEND
        check_https_sni localhost;
EOF

run "mtls, cert of another CA" down 8 <<EOF
        server 127.0.0.1:$MTLS_PORT;
        check interval=500 rise=1 fall=2 timeout=2000 default_down=false type=https;
$SEND
        check_https_sni localhost;
        check_https_certificate $D/certs/other-cli.crt;
        check_https_certificate_key $D/certs/other-cli.key;
EOF

run "mtls, encrypted key, password file" up 8 <<EOF
        server 127.0.0.1:$MTLS_PORT;
        check interval=500 rise=1 fall=2 timeout=2000 type=https;
$SEND
        check_https_sni localhost;
        check_https_certificate $D/certs/cli.crt;
        check_https_certificate_key $D/certs/cli-enc.key;
        check_https_password_file $D/certs/passwords.txt;
EOF

run "mtls and verify on" up 8 <<EOF
        server 127.0.0.1:$MTLS_PORT;
        check interval=500 rise=1 fall=2 timeout=2000 type=https;
$SEND
        check_https_verify on;
        check_https_sni localhost;
        check_https_trusted_certificate $D/certs/ca.crt;
        check_https_certificate $D/certs/cli.crt;
        check_https_certificate_key $D/certs/cli.key;
EOF

run "mtls peer, 500 is still a failure" down 8 <<EOF
        server 127.0.0.1:$MTLS_PORT;
        check interval=500 rise=1 fall=2 timeout=2000 default_down=false type=https;
        check_http_send "GET /fail HTTP/1.0\r\n\r\n";
        check_http_expect_alive http_2xx;
        check_https_sni localhost;
        check_https_certificate $D/certs/cli.crt;
        check_https_certificate_key $D/certs/cli.key;
EOF

run "plain tls peer, mtls off" up 6 <<EOF
        server 127.0.0.1:$TLS_PORT;
        check interval=500 rise=1 fall=2 timeout=2000 type=https;
$SEND
        check_https_certificate $D/certs/cli.crt;
        check_https_certificate_key $D/certs/cli.key;
EOF

run "type=http still works" up 6 <<EOF
        server 127.0.0.1:$PLAIN_PORT;
        check interval=500 rise=1 fall=2 timeout=2000 type=http;
$SEND
EOF

run "type=tcp still works" up 6 <<EOF
        server 127.0.0.1:$TLS_PORT;
        check interval=500 rise=1 fall=2 timeout=2000 type=tcp;
EOF

echo "== backend disappears and returns"
front_start "reappear" <<EOF
        server 127.0.0.1:$TLS_PORT;
        check interval=500 rise=1 fall=2 timeout=2000 type=https;
$SEND
EOF
if wait_status up 6; then echo "   up while the backend is up"; else echo "   NOT OK"; FAIL=$((FAIL + 1)); fi
kill -QUIT "$(cat "$D/backend.pid")"; wait_gone "$TLS_PORT"; rm -f "$D/backend.pid"
if wait_status down 10; then echo "   down after it went away"; PASS=$((PASS + 1));
else echo "   NOT OK"; FAIL=$((FAIL + 1)); fi
"$NGINX_BIN" -c "$D/backend.conf"; sleep 0.5
if wait_status up 15; then echo "   up again after it returned"; PASS=$((PASS + 1));
else echo "   NOT OK"; FAIL=$((FAIL + 1)); fi
front_stop "reappear"

echo "== configuration errors"
for bad in "check_https_verify on;" \
           "check_https_verify on; check_https_sni localhost;" \
           "check interval=1000 type=httpsx;" \
           "check_https_certificate $D/certs/cli.crt;" \
           "check_https_certificate_key $D/certs/cli.key;" \
           "check_https_certificate $D/certs/cli.crt; check_https_certificate_key $D/certs/missing.key;" \
           "check_https_certificate $D/certs/cli.crt; check_https_certificate_key $D/certs/cli-enc.key;" \
           "check_https_password_file $D/certs/missing.txt;"
do
    printf '   %-58s ' "$bad"
    QUIET=1
    if front_start "rejected case" <<EOF
        server 127.0.0.1:$TLS_PORT;
        check interval=500 rise=1 fall=2 timeout=2000 type=https;
        $bad
EOF
    then
        echo "accepted, that is wrong"
        FAIL=$((FAIL + 1))
        front_stop "rejected case"
    else
        grep -m1 -oE "\[emerg\].*" "$D/logs/conftest-rejected_case.log" \
            | cut -c1-104
        PASS=$((PASS + 1))
    fi
    QUIET=0
done

# A check_https_* directive in an upstream that is not checked over TLS has
# nothing to apply to.  It has to be refused or reported, never ignored.
echo "== check_https_* with a check type that is not https"
for pair in "type=http|check_https_certificate $D/certs/cli.crt;" \
            "type=tcp|check_https_certificate_key $D/certs/cli.key;" \
            "type=http|check_https_verify on;"
do
    type=${pair%%|*}; bad=${pair#*|}
    printf '   %-58s ' "$type + ${bad%% *}"
    QUIET=1
    if front_start "warned case" <<EOF
        server 127.0.0.1:$PLAIN_PORT;
        check interval=500 rise=1 fall=2 timeout=2000 $type;
        $bad
EOF
    then
        if grep -q "check_https_\*.*ignored" "$D/logs/conftest-warned_case.log"; then
            grep -m1 -oE "the \"check_https_\*\" directives.*" \
                "$D/logs/conftest-warned_case.log" | cut -c1-104
            PASS=$((PASS + 1))
        else
            echo "accepted quietly, no warning"
            FAIL=$((FAIL + 1))
        fi
        front_stop "warned case"
    else
        echo "rejected, that is wrong"
        FAIL=$((FAIL + 1))
    fi
    QUIET=0
done

echo
echo "passed=$PASS failed=$FAIL"
[ $FAIL -eq 0 ]
