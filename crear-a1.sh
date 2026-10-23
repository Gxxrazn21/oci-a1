#!/usr/bin/env bash
# Intenta crear instancias Always Free (VM.Standard.A1.Flex) en Oracle Cloud
# y avisa por Telegram cuando lo logra. Pensado para correr en GitHub Actions
# cada pocos minutos; tambien sirve en cualquier Linux con OCI CLI configurado.
set -uo pipefail

read -r -a NOMBRES <<< "${NOMBRES:-MiTv Alexa}"
OCPUS=${OCPUS:-2}
MEMORIA_GB=${MEMORIA_GB:-12}
DISCO_GB=${DISCO_GB:-50}
NOMBRE_SUBRED=${NOMBRE_SUBRED:-subnet-20261022-1953}
INTENTOS=${INTENTOS:-3}        # intentos por ejecucion
ESPERA=${ESPERA:-60}           # segundos entre intentos
LLAVE_SSH=${LLAVE_SSH:-$HOME/.ssh/id_instancias.pub}
export OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True

avisar() {
  echo "$1"
  if [ -n "${TELEGRAM_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
    curl -s -o /dev/null -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
      -d chat_id="$TELEGRAM_CHAT_ID" --data-urlencode text="$1"
  fi
}

terminar() {
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "terminado=1" >> "$GITHUB_OUTPUT"
  exit 0
}

# Imprime el id de la instancia no terminada con ese nombre (vacio si no hay)
viva() {
  local id
  id=$(oci compute instance list -c "$TENANCY" --display-name "$1" --all \
    --query "data[?\"lifecycle-state\"!='TERMINATED' && \"lifecycle-state\"!='TERMINATING'] | [0].id" \
    --raw-output 2>/dev/null)
  [[ "$id" == ocid1.* ]] && echo "$id"
}

esperar_ip() {
  local ip
  for _ in $(seq 1 40); do
    ip=$(oci compute instance list-vnics --instance-id "$1" \
      --query 'data[0]."public-ip"' --raw-output 2>/dev/null)
    if [[ "$ip" =~ ^[0-9]+\. ]]; then echo "$ip"; return; fi
    sleep 15
  done
  echo "(aun sin IP, revisala en la consola)"
}

# --- Datos de la cuenta -------------------------------------------------------

TENANCY=$(awk -F= '/^tenancy/{print $2}' ~/.oci/config | tr -d '[:space:]')

if ! AD=$(oci iam availability-domain list -c "$TENANCY" --query 'data[0].name' --raw-output 2>&1); then
  avisar "❌ Oracle: no pude conectarme con la API. Revisa los secrets OCI_*.
$AD"
  exit 1
fi

IMAGEN=$(oci compute image list -c "$TENANCY" --operating-system "Oracle Linux" \
  --operating-system-version 9 --shape VM.Standard.A1.Flex \
  --sort-by TIMECREATED --sort-order DESC --limit 1 --query 'data[0].id' --raw-output)
SUBRED=$(oci network subnet list -c "$TENANCY" --all \
  --query "data[?\"display-name\"=='$NOMBRE_SUBRED'] | [0].id" --raw-output)

if [[ "$IMAGEN" != ocid1.* || "$SUBRED" != ocid1.* ]]; then
  avisar "❌ Oracle: no encontre la imagen de Oracle Linux 9 ARM o la subred '$NOMBRE_SUBRED'."
  exit 1
fi

# --- Que falta por crear ------------------------------------------------------

pendientes=()
for n in "${NOMBRES[@]}"; do
  if [ -n "$(viva "$n")" ]; then echo "$n ya existe."; else pendientes+=("$n"); fi
done
[ ${#pendientes[@]} -eq 0 ] && { echo "Ya existen todas."; terminar; }

# --- Intentos -----------------------------------------------------------------

for ((i = 1; i <= INTENTOS; i++)); do
  restantes=()
  for n in "${pendientes[@]}"; do
    echo "Intento $i/$INTENTOS: creando $n (${OCPUS} OCPU, ${MEMORIA_GB} GB)..."
    salida=$(oci compute instance launch \
      --availability-domain "$AD" -c "$TENANCY" \
      --shape VM.Standard.A1.Flex \
      --shape-config "{\"ocpus\": $OCPUS, \"memoryInGBs\": $MEMORIA_GB}" \
      --image-id "$IMAGEN" --subnet-id "$SUBRED" --assign-public-ip true \
      --boot-volume-size-in-gbs "$DISCO_GB" --display-name "$n" \
      --ssh-authorized-keys-file "$LLAVE_SSH" 2>&1)
    codigo=$?

    if [ $codigo -eq 0 ]; then
      id=$(jq -r '.data.id' <<< "$salida")
      ip=$(esperar_ip "$id")
      avisar "✅ Oracle: se creo la instancia $n (${OCPUS} OCPU, ${MEMORIA_GB} GB, Always Free).
IP publica: $ip
Entra con: ssh -i <tu-llave.key> opc@$ip"
    elif grep -qiE 'out of (host )?capacity' <<< "$salida"; then
      echo "Sin capacidad para $n."
      restantes+=("$n")
    elif grep -qi 'TooManyRequests' <<< "$salida"; then
      echo "Oracle pide bajar el ritmo (429)."
      restantes+=("$n")
    elif grep -qiE 'LimitExceeded|QuotaExceeded' <<< "$salida"; then
      avisar "⚠️ Oracle: se alcanzo un limite de la cuenta creando $n. Reviso manualmente.
$(head -c 600 <<< "$salida")"
      exit 1
    else
      avisar "❌ Oracle: error inesperado creando $n:
$(head -c 600 <<< "$salida")"
      restantes+=("$n")
    fi
  done

  pendientes=("${restantes[@]}")
  [ ${#pendientes[@]} -eq 0 ] && break
  [ "$i" -lt "$INTENTOS" ] && sleep "$ESPERA"
done

if [ ${#pendientes[@]} -eq 0 ]; then
  avisar "🎉 Oracle: ya estan creadas todas (${NOMBRES[*]}). Apago la busqueda automatica."
  terminar
fi
echo "Siguen sin capacidad: ${pendientes[*]}. Se reintenta en la proxima ejecucion."
