EGG_REPO_API="https://api.github.com/repos/pelican-eggs/eggs"
EGG_REPO_RAW="https://raw.githubusercontent.com/pelican-eggs/eggs/master"
EGG_CACHE="/tmp/ptero-eggs"

function _egg_fetch_list() {
    mkdir -p "$EGG_CACHE"
    local cache_file="$EGG_CACHE/tree.json"
    local tree_url="$EGG_REPO_API/git/trees/master?recursive=1"

    if [ -f "$cache_file" ] && [ "$(( $(date +%s) - $(stat -c %Y "$cache_file") ))" -lt 300 ]; then
        :
    else
        if ! curl -fsSL --max-time 15 "$tree_url" -o "$cache_file" 2>/dev/null; then
            return 1
        fi
    fi

    if ! command -v jq >/dev/null 2>&1; then
        apt install -y jq >/dev/null 2>&1 || return 1
    fi

    jq -r '.tree[] | select(.path | test("egg-.*\\.json$")) | (.path | split("/") | .[0:-1] | join("/")) + "|" + .path' "$cache_file" 2>/dev/null || return 1
}

function egg_list_available() {
    require_root || return 1
    header
    echo -e "${BLUE}Egg Tersedia dari Repo Komunitas${NC}"
    echo -e "${YELLOW}Mengambil daftar egg dari pelican-eggs/eggs...${NC}"
    echo

    local eggs
    eggs=$(_egg_fetch_list) || {
        fail "Gagal mengambil daftar egg. Cek koneksi."
        pause
        return 1
    }

    local count=0
    printf "  %-4s %-50s\n" "No" "Egg"
    echo -e "${GRAY}  ─────────────────────────────────────────────────────────────${NC}"
    while IFS='|' read -r name file; do
        count=$((count+1))
        printf "  ${CYAN}[%3d]${NC} %s\n" "$count" "$(echo "$name" | sed 's|/| › |g')"
    done <<< "$eggs"

    if [ "$count" -eq 0 ]; then
        echo -e "${YELLOW}Tidak ada egg ditemukan.${NC}"
        pause
        return 0
    fi

    echo
    echo -e "${CYAN}Total: $count eggs tersedia.${NC}"
    echo
    echo -e "${YELLOW}NOTE: Import egg hanya bisa lewat Admin Panel > Nests > Import Egg${NC}"
    echo -e "${YELLOW}Download URL:${NC} https://raw.githubusercontent.com/pelican-eggs/eggs/master/<path>"
    echo
    read -r -p "Cari egg (filter nama, Enter untuk kembali): " KW
    if [ -n "$KW" ]; then
        echo
        echo -e "${CYAN}Hasil pencarian '$KW':${NC}"
        echo -e "${GRAY}  ─────────────────────────────────────────────────────────────${NC}"
        while IFS='|' read -r name file; do
            if echo "$name" | grep -qi "$KW"; then
                printf "  ${GREEN}[v]${NC} %-50s ${GRAY}%s${NC}\n" "$(echo "$name" | sed 's|/| › |g')" "$file"
            fi
        done <<< "$eggs"
        echo
    fi
    pause
}

function egg_list_installed() {
    require_root || return 1
    require_panel || return 1
    header
    echo -e "${BLUE}Egg Terinstall di Panel${NC}"
    echo

    read -r -s -p "Password database $DB_USER: " DBP
    echo

    local sql='SELECT id, name, uuid FROM eggs ORDER BY name ASC;'
    local out
    if ! out=$(mysql_secure "$DB_USER" "$DBP" -h 127.0.0.1 -D "$DB_NAME" \
                            --batch --table -e "$sql" 2>&1); then
        fail "Query gagal. Cek password."
        pause
        return 1
    fi
    echo "$out"

    local count
    count=$(echo "$out" | grep -cE '^\| +[0-9]+ +\|')
    echo
    echo -e "${CYAN}Total: $count egg terinstall.${NC}"
    echo
    echo -e "${YELLOW}Untuk import egg baru, buka Admin Panel > Nests > pilih Nest > Import Egg${NC}"
    pause
}
