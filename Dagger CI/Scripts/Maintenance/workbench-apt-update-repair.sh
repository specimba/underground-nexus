bash -euxo pipefail <<'FIXAPT'
echo "==> APT repair: normalize Microsoft repo 'Signed-By' and fix update"

#---------------------------
# Prep & backups
#---------------------------
export DEBIAN_FRONTEND=noninteractive
if [ "${EUID:-$(id -u)}" -ne 0 ]; then SUDO="sudo -n"; else SUDO=""; fi

command -v apt-get >/dev/null
command -v dpkg >/dev/null

TS="$(date +%Y%m%d-%H%M%S)"
BK="/root/apt-backup-$TS"
$SUDO mkdir -p "$BK"

echo "==> Backing up to $BK"
$SUDO cp -a /etc/apt/sources.list "$BK"/sources.list || true
$SUDO cp -a /etc/apt/sources.list.d "$BK"/sources.list.d || true
$SUDO cp -a /etc/apt/trusted.gpg.d "$BK"/trusted.gpg.d || true
$SUDO cp -a /usr/share/keyrings "$BK"/usr-share-keyrings || true

#---------------------------
# Normalize Microsoft keyring
#---------------------------
ARCH="$(dpkg --print-architecture)"
KEYRINGS_DIR="/etc/apt/keyrings"
MS_KEY="$KEYRINGS_DIR/microsoft.gpg"
$SUDO mkdir -p "$KEYRINGS_DIR"
$SUDO chmod 0755 "$KEYRINGS_DIR"

# Prefer an existing, known-good Microsoft key if present
CANDIDATES=(
  "/usr/share/keyrings/microsoft.gpg"
  "/etc/apt/trusted.gpg.d/packages.microsoft.gpg"
)
FOUND=""
for k in "${CANDIDATES[@]}"; do
  if $SUDO test -s "$k"; then FOUND="$k"; break; fi
done

if [ -n "$FOUND" ]; then
  echo "==> Seeding keyring from $FOUND -> $MS_KEY"
  $SUDO cp -f "$FOUND" "$MS_KEY"
  $SUDO chmod 0644 "$MS_KEY"
else
  echo "==> No local Microsoft key found; will try to fetch (best effort)"
  if command -v gpg >/dev/null; then
    if command -v curl >/dev/null; then
      $SUDO bash -c 'umask 022; curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /etc/apt/keyrings/microsoft.gpg'
      $SUDO chmod 0644 "$MS_KEY"
    elif command -v wget >/dev/null; then
      $SUDO bash -c 'umask 022; wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /etc/apt/keyrings/microsoft.gpg'
      $SUDO chmod 0644 "$MS_KEY"
    else
      echo "!! Neither curl nor wget available to fetch key; will continue using repo rewrites."
      $SUDO bash -c ": > '$MS_KEY'"; $SUDO chmod 0644 "$MS_KEY" || true
    fi
  else
    echo "!! gpg not present; cannot dearmor key. Continuing (we copied from existing if present)."
    $SUDO bash -c ": > '$MS_KEY'"; $SUDO chmod 0644 "$MS_KEY" || true
  fi
fi

echo "==> Using keyring: $MS_KEY (size: $($SUDO sh -c "stat -c%s '$MS_KEY' 2>/dev/null" || echo 0) bytes)"

#---------------------------
# Rewrite Microsoft repo definitions to a single Signed-By path
#---------------------------
# 1) Legacy .list format lines -> enforce [signed-by=/etc/apt/keyrings/microsoft.gpg]
mapfile -t LIST_FILES < <($SUDO bash -c "grep -RIl --exclude-dir='*.save' --line-number -e 'packages.microsoft.com' /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null | cut -d: -f1 | sort -u") || true
for f in "${LIST_FILES[@]}"; do
  [ -n "$f" ] || continue
  echo "==> Normalizing .list file: $f"
  # If line has [ ... ], replace signed-by; else add bracket with arch+signed-by.
  $SUDO sed -i -E \
    -e "s#(^[[:space:]]*deb[[:space:]]+)\[([^\]]*)\]#\1[\2]#g" \
    -e "s#signed-by=[^] ]*#signed-by=$MS_KEY#g" \
    "$f"

  # Ensure there is an options bracket; if none, add it with arch+signed-by
  $SUDO awk -v key="$MS_KEY" -v arch="$ARCH" '
    /^[[:space:]]*deb/ && $0 ~ /packages\.microsoft\.com/ {
      if ($0 !~ /\[[^]]*\]/) {
        sub(/^deb[[:space:]]+/, "deb [arch=" arch " signed-by=" key "] ", $0)
      } else if ($0 !~ /signed-by=/) {
        sub(/\[/, "[signed-by=" key " ", $0)
      }
    } { print }
  ' "$f" | $SUDO tee "$f" >/dev/null
done

# 2) Deb822 .sources files -> ensure "Signed-By: /etc/apt/keyrings/microsoft.gpg"
mapfile -t SRC_FILES < <($SUDO bash -c "grep -RIl --line-number -e 'packages.microsoft.com' /etc/apt/sources.list.d/*.sources 2>/dev/null | cut -d: -f1 | sort -u") || true
for f in "${SRC_FILES[@]}"; do
  [ -n "$f" ] || continue
  echo "==> Normalizing .sources file: $f"
  if $SUDO grep -qE '^[[:space:]]*Signed-By:' "$f"; then
    $SUDO sed -i -E "s#^[[:space:]]*Signed-By:.*#Signed-By: $MS_KEY#g" "$f"
  else
    # Insert after the URIs line referencing packages.microsoft.com
    $SUDO sed -i -E "/^[[:space:]]*URIs:[[:space:]]*https?:\/\/packages\.microsoft\.com.*/a Signed-By: $MS_KEY" "$f"
  fi
  # Make sure the entry is enabled (some vendor files ship as Enabled: yes by default)
  if $SUDO grep -qE '^[[:space:]]*Enabled:' "$f"; then
    $SUDO sed -i -E "s#^[[:space:]]*Enabled:.*#Enabled: yes#g" "$f"
  else
    $SUDO sed -i -E "/^[[:space:]]*Types:/i Enabled: yes" "$f" || true
  fi
done

# Optional: remove the old key file that causes confusion if NOTHING references it anymore
if [ -z "$( $SUDO grep -RIl 'packages.microsoft.com' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null | xargs -r $SUDO grep -I 'trusted.gpg.d/packages.microsoft.gpg' -n || true )" ]; then
  if $SUDO test -f /etc/apt/trusted.gpg.d/packages.microsoft.gpg; then
    echo "==> Removing stale /etc/apt/trusted.gpg.d/packages.microsoft.gpg (no longer referenced)"
    $SUDO rm -f /etc/apt/trusted.gpg.d/packages.microsoft.gpg || true
  fi
fi

echo "==> Post-fix Microsoft repo lines:"
$SUDO grep -RIn "packages.microsoft.com" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || true

#---------------------------
# Clean, repair, and update
#---------------------------
echo "==> Cleaning APT state"
$SUDO rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock || true
$SUDO rm -f /var/cache/apt/archives/lock || true
$SUDO rm -rf /var/lib/apt/lists/partial || true
$SUDO rm -rf /var/lib/apt/lists/* || true
$SUDO apt-get clean

echo "==> Repair pass"
$SUDO dpkg --configure -a || true
$SUDO apt-get -y -o Dpkg::Options::=--force-confnew -f install || true

echo "==> apt-get update (attempt 1)"
if $SUDO apt-get update; then
  echo "==> SUCCESS: apt-get update is healthy (attempt 1)"
else
  echo "!! apt-get update failed; attempting deeper cleanup and retry"
  $SUDO rm -rf /var/lib/apt/lists/* || true
  $SUDO apt-get clean
  $SUDO dpkg --configure -a || true
  $SUDO apt-get -y -o Dpkg::Options::=--force-confnew -f install || true
  $SUDO apt-get update
  echo "==> SUCCESS: apt-get update is healthy (attempt 2)"
fi

echo "==> DONE."
FIXAPT
 