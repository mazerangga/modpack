#!/usr/bin/env bash
# build-pack.sh - kelola pack packwiz dengan tata letak repo seperti
# github.com/mazerangga/modpack:
#
#   <repo>/
#   ├── mods/          <- file .pw.toml per mod
#   ├── .gitignore
#   ├── index.toml
#   └── pack.toml      <- name, author, [versions] minecraft + loader
#
# Pack ada di AKAR repo (bukan di subfolder). Jalankan skrip ini dari dalam
# clone repo, atau set PACK_DIR=/path/ke/repo.
#
# Perilaku:
#   - pack.toml SUDAH ada : pakai versi MC/loader di sana, hanya tambah mod
#                           yang belum ada. Kalau kamu beri versi berbeda lewat
#                           argumen, pack dimigrasi (packwiz migrate).
#   - pack.toml BELUM ada : menu loader + versi MC + versi loader (live dari
#                           API), lalu packwiz init di akar repo.
#
# Pemakaian:
#   ./build-pack.sh                       # pakai pack.toml, atau menu kalau baru
#   ./build-pack.sh 26.3                  # target MC 26.3
#   ./build-pack.sh 26.3 fabric 0.19.5    # MC + loader + versi loader
#   PACK_DIR=~/modpack ./build-pack.sh
#   MODS_FILE=lain.txt ./build-pack.sh
#
# Env opsional: PACK_NAME, PACK_AUTHOR (untuk pack baru)
# Butuh: bash, python3, packwiz, git (opsional)

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACK_DIR_IN="${PACK_DIR:-.}"
mkdir -p "$PACK_DIR_IN"
PACK_DIR="$(cd "$PACK_DIR_IN" && pwd)"

if [ -z "${MODS_FILE:-}" ]; then
  if [ -f "$PACK_DIR/mods.txt" ]; then MODS_FILE="$PACK_DIR/mods.txt"; else MODS_FILE="$SCRIPT_DIR/mods.txt"; fi
fi

ARG_MC="${1:-}"
ARG_LOADER="${2:-}"
ARG_LV="${3:-}"
PACK_NAME="${PACK_NAME:-adieyr-modpack}"
PACK_AUTHOR="${PACK_AUTHOR:-Aditya R fauzi}"

FABRIC_META="${FABRIC_META:-https://meta.fabricmc.net/v2/versions}"
QUILT_META="${QUILT_META:-https://meta.quiltmc.org/v3/versions}"
MOJANG_MANIFEST="${MOJANG_MANIFEST:-https://piston-meta.mojang.com/mc/game/version_manifest_v2.json}"

for cmd in packwiz python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "'$cmd' tidak ditemukan."; exit 1; }
done
[ -f "$MODS_FILE" ] || { echo "File daftar mod tidak ada: $MODS_FILE"; exit 1; }

# ---- helper: daftar versi live ---------------------------------------------
fetch_list() {   # <url> <mojang|list> <limit> <snapshot 0|1>
python3 - "$@" <<'PY'
import json, sys, urllib.request
url, mode, limit, snap = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4] == "1"
try:
    req = urllib.request.Request(url, headers={"User-Agent": "packwiz-build-script/1.0"})
    data = json.load(urllib.request.urlopen(req, timeout=10))
except Exception:
    sys.exit(1)
out = []
if mode == "mojang":
    for v in data.get("versions", []):
        if snap or v.get("type") == "release":
            out.append(v["id"])
else:
    for v in data:
        ver = v["version"]
        if not snap:
            if "stable" in v:
                if not v["stable"]:
                    continue
            elif "-" in ver:
                continue
        out.append(ver)
print("\n".join(out[:limit]))
PY
}

PICKED=""
pick() {         # <judul> <item...> -> PICKED
  local title="$1"; shift
  local items=("$@") i=1 c
  echo; echo "$title"
  for it in "${items[@]}"; do printf "  %2d) %s\n" "$i" "$it"; i=$((i+1)); done
  echo "   m) ketik manual"
  [ "${ALLOW_SNAP:-0}" = "1" ] && echo "   s) tampilkan juga snapshot/versi tidak stabil"
  read -r -p "Pilihan [1]: " c
  c="${c:-1}"
  if [ "$c" = "m" ]; then read -r -p "Ketik: " PICKED
  elif [ "$c" = "s" ] && [ "${ALLOW_SNAP:-0}" = "1" ]; then PICKED="__SNAP__"
  elif [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le "${#items[@]}" ]; then PICKED="${items[$((c-1))]}"
  else PICKED="$c"
  fi
}

add_line() {     # <file> <baris>: tambahkan kalau belum ada
  touch "$1"; grep -qxF "$2" "$1" || echo "$2" >> "$1"
}

# ---- mulai ------------------------------------------------------------------
cd "$PACK_DIR" || exit 1
echo "Repo/pack : $PACK_DIR"

# baca mods.txt
mapfile -t MODS < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//' "$MODS_FILE" | grep -v '^$')

if [ -f pack.toml ]; then
  # ===== MODE UPDATE: pack sudah ada =====
  CUR_MC="$(sed -n 's/^minecraft *= *"\(.*\)".*/\1/p' pack.toml | head -1)"
  CUR_LOADER=""; CUR_LV=""
  for l in fabric quilt neoforge forge; do
    v="$(sed -n "s/^$l *= *\"\(.*\)\".*/\1/p" pack.toml | head -1)"
    [ -n "$v" ] && { CUR_LOADER="$l"; CUR_LV="$v"; break; }
  done
  echo "pack.toml ditemukan: Minecraft ${CUR_MC:-?} | ${CUR_LOADER:-?} ${CUR_LV:-?}"
  MC_VERSION="${ARG_MC:-$CUR_MC}"
  LOADER="${CUR_LOADER:-fabric}"
  if [ -n "$ARG_LOADER" ] && [ "$ARG_LOADER" != "$CUR_LOADER" ]; then
    echo "Ganti jenis loader ($CUR_LOADER -> $ARG_LOADER) tidak didukung lewat skrip ini."
    echo "Buat pack baru di folder kosong untuk loader lain."; exit 1
  fi
  if [ -n "$MC_VERSION" ] && [ "$MC_VERSION" != "$CUR_MC" ]; then
    echo "Migrasi Minecraft $CUR_MC -> $MC_VERSION ..."
    packwiz migrate minecraft "$MC_VERSION" || { echo "migrate minecraft gagal."; exit 1; }
  fi
  if [ -n "$ARG_LV" ] && [ "$ARG_LV" != "$CUR_LV" ]; then
    echo "Migrasi $LOADER $CUR_LV -> $ARG_LV ..."
    packwiz migrate loader "$ARG_LV" || { echo "migrate loader gagal."; exit 1; }
  fi
else
  # ===== MODE BARU: belum ada pack.toml =====
  MC_VERSION="$ARG_MC"; LOADER="$ARG_LOADER"; LOADER_VERSION="$ARG_LV"
  if [ -z "$LOADER" ]; then pick "Pilih mod loader:" fabric quilt neoforge forge; LOADER="$PICKED"; fi
  case "$LOADER" in fabric|quilt|neoforge|forge) ;; *) echo "Loader tidak dikenal: $LOADER"; exit 1 ;; esac
  case "$LOADER" in
    fabric) MC_URL="$FABRIC_META/game"; MC_MODE=list ;;
    quilt)  MC_URL="$QUILT_META/game";  MC_MODE=list ;;
    *)      MC_URL="$MOJANG_MANIFEST";  MC_MODE=mojang ;;
  esac
  if [ -z "$MC_VERSION" ]; then
    snap=0
    while :; do
      if mapfile -t LIST < <(fetch_list "$MC_URL" "$MC_MODE" 12 "$snap") && [ -n "${LIST[0]:-}" ]; then
        ALLOW_SNAP=1 pick "Versi Minecraft untuk $LOADER (live, terbaru di atas):" "${LIST[@]}"
        [ "$PICKED" = "__SNAP__" ] && { snap=1; continue; }
        MC_VERSION="$PICKED"; break
      else
        echo; echo "Gagal mengambil daftar versi (offline?)."
        read -r -p "Ketik versi Minecraft manual: " MC_VERSION; break
      fi
    done
  fi
  [ -z "$MC_VERSION" ] && { echo "Versi Minecraft kosong."; exit 1; }
  if [ -z "$LOADER_VERSION" ]; then
    if [ "$LOADER" = "fabric" ] || [ "$LOADER" = "quilt" ]; then
      base="$FABRIC_META"; [ "$LOADER" = "quilt" ] && base="$QUILT_META"
      if mapfile -t LLIST < <(fetch_list "$base/loader" list 8 0) && [ -n "${LLIST[0]:-}" ]; then
        pick "Versi $LOADER loader (live, 1 = terbaru):" "${LLIST[@]}"; LOADER_VERSION="$PICKED"
      else
        echo "Gagal mengambil daftar loader, memakai versi terbaru."; LOADER_VERSION="latest"
      fi
    else
      LOADER_VERSION="latest"
    fi
  fi
  if [ "$LOADER_VERSION" = "latest" ]; then
    LOADER_ARGS=(--modloader "$LOADER" "--${LOADER}-latest")
  else
    LOADER_ARGS=(--modloader "$LOADER" "--${LOADER}-version" "$LOADER_VERSION")
  fi
  echo; echo "== packwiz init: $PACK_NAME | Minecraft $MC_VERSION | $LOADER $LOADER_VERSION =="
  packwiz init --name "$PACK_NAME" --author "$PACK_AUTHOR" --version "$MC_VERSION" \
    "${LOADER_ARGS[@]}" --index-file index.toml || { echo "packwiz init gagal."; exit 1; }
fi

[ "$LOADER" != "fabric" ] && echo "PERINGATAN: mods.txt berisi mod Fabric, banyak yang akan gagal untuk $LOADER."

# ---- jaga agar file bantu tidak ikut terpasang ke client/server --------------
add_line .packwizignore "mods.txt"
add_line .packwizignore "build-pack.sh"
add_line .packwizignore "check_mods.py"
add_line .packwizignore "report.txt"
add_line .packwizignore "add-mods.sh"
add_line .packwizignore "failed.txt"
add_line .gitignore "failed.txt"

# ---- tambah mod --------------------------------------------------------------
mkdir -p mods
: > failed.txt
added=0; skipped=0
echo; echo "Memproses ${#MODS[@]} mod dari $MODS_FILE (Minecraft $MC_VERSION)"
for mod in "${MODS[@]}"; do
  if [ -f "mods/${mod}.pw.toml" ]; then
    skipped=$((skipped+1)); continue
  fi
  echo "-- menambah: $mod"
  if packwiz mr add "$mod" -y; then added=$((added+1)); else echo "$mod" >> failed.txt; fi
done
packwiz refresh

echo
echo "Selesai. Ditambah: $added | sudah ada (dilewati): $skipped"
if [ -s failed.txt ]; then
  echo "Mod yang GAGAL ditambah (kemungkinan belum support ${MC_VERSION}/${LOADER}):"
  sed 's/^/  - /' failed.txt
else
  echo "Semua mod berhasil ditambah."
fi

# ---- URL pack.toml untuk packwiz-installer ----------------------------------
PACK_URL="<url>/pack.toml"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  remote="$(git remote get-url origin 2>/dev/null || true)"
  branch="$(git symbolic-ref --short HEAD 2>/dev/null || echo main)"
  if [[ "$remote" =~ github\.com[:/]([^/]+)/([^/]+)$ ]]; then
    repo="${BASH_REMATCH[2]%.git}"
    PACK_URL="https://raw.githubusercontent.com/${BASH_REMATCH[1]}/${repo}/${branch}/pack.toml"
  fi
fi
echo
echo "Server : java -jar packwiz-installer-bootstrap.jar -g -s server $PACK_URL"
echo "Client : java -jar packwiz-installer-bootstrap.jar -g -s client $PACK_URL"

# ---- commit & push (opsional) ------------------------------------------------
if git rev-parse --is-inside-work-tree >/dev/null 2>&1 && [ -n "$(git status --porcelain)" ]; then
  echo
  read -r -p "Commit dan push perubahan ke GitHub sekarang? [y/N]: " ans
  if [[ "${ans:-n}" =~ ^[Yy]$ ]]; then
    git add -A && git commit -m "Update modpack (Minecraft ${MC_VERSION})" && { git push || git push -u origin HEAD; }
  fi
fi
