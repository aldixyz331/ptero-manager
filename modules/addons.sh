#!/bin/bash

# Auto-detect ptero-manager root (parent of modules/)
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
    [[ -z "$SCRIPT_DIR" || "$SCRIPT_DIR" = "/" ]] && SCRIPT_DIR="/root/ptero-manager"
fi
ADDON_DIR="$SCRIPT_DIR/addon-pterodactyl"
ADDON_MARKER_DIR="/etc/ptero-manager/addons"
ADDON_STATE_FILE="/etc/ptero-manager/addons.state.json"
PANEL_DIR="${PANEL_DIR:-/var/www/pterodactyl}"
_ADDON_ROUTE_SLUGS=""

# ---- Panel version detection ----
PANEL_VERSION=""
PANEL_VERSION_MAJOR=0
PANEL_VERSION_MINOR=0
PANEL_VERSION_PATCH=0

_addon_detect_panel_version() {
    local ver=""
    if [[ -f "$PANEL_DIR/config/app.php" ]]; then
        ver=$(grep "'version'" "$PANEL_DIR/config/app.php" 2>/dev/null | head -1 | grep -oP "'version'\s*=>\s*'\K[^']+")
    fi
    if [[ -z "$ver" || "$ver" == "canary" || "$ver" == "develop" ]]; then
        if [[ -f "$PANEL_DIR/composer.json" ]]; then
            ver=$(grep -oP '"version":\s*"\K[^"]+' "$PANEL_DIR/composer.json" 2>/dev/null || echo "")
        fi
    fi
    if [[ -z "$ver" || "$ver" == "canary" || "$ver" == "develop" ]]; then
        ver="0.0.0"
    fi
    PANEL_VERSION="$ver"
    PANEL_VERSION_MAJOR=$(echo "$ver" | cut -d. -f1)
    PANEL_VERSION_MINOR=$(echo "$ver" | cut -d. -f2)
    PANEL_VERSION_PATCH=$(echo "$ver" | cut -d. -f3)
}

_addon_version_cmp() {
    local v1="$1" v2="$2"
    local v1_maj v1_min v1_pat v2_maj v2_min v2_pat
    v1_maj=$(echo "$v1" | cut -d. -f1); v1_min=$(echo "$v1" | cut -d. -f2); v1_pat=$(echo "$v1" | cut -d. -f3)
    v2_maj=$(echo "$v2" | cut -d. -f1); v2_min=$(echo "$v2" | cut -d. -f2); v2_pat=$(echo "$v2" | cut -d. -f3)
    if (( v1_maj > v2_maj )); then echo 1; return; fi
    if (( v1_maj < v2_maj )); then echo -1; return; fi
    if (( v1_min > v2_min )); then echo 1; return; fi
    if (( v1_min < v2_min )); then echo -1; return; fi
    if (( v1_pat > v2_pat )); then echo 1; return; fi
    if (( v1_pat < v2_pat )); then echo -1; return; fi
    echo 0
}

_addon_compat_warning() {
    local addon="$1" msg="$2" level="${3:-warn}"
    if [[ "$level" == "error" ]]; then
        echo -e "  $(_addon_color 31 "⛔ $addon: $msg")"
    else
        echo -e "  $(_addon_color 33 "⚠️  $addon: $msg")"
    fi
}

_addon_check_compatibility() {
    local addon="$1"
    local lower
    lower=$(echo "$addon" | tr '[:upper:]' '[:lower:]')

    if [[ "$PANEL_VERSION" == "0.0.0" || -z "$PANEL_VERSION" ]]; then
        return 0
    fi

    local cmp_min_11
    cmp_min_11=$(_addon_version_cmp "$PANEL_VERSION" "1.11.0")
    local cmp_min_10
    cmp_min_10=$(_addon_version_cmp "$PANEL_VERSION" "1.10.0")
    local cmp_min_9
    cmp_min_9=$(_addon_version_cmp "$PANEL_VERSION" "1.9.0")
    local cmp_10
    cmp_10=$(_addon_version_cmp "$PANEL_VERSION" "1.10.0")

    case "$lower" in
        *"node maintenance"*|*"1.10.x"*)
            if (( cmp_10 >= 0 )); then
                _addon_compat_warning "$addon" "Target Panel 1.10.x — Panel v$PANEL_VERSION terinstall. Cek kompatibilitas komponen frontend."
                return 1
            fi
            ;;
        *"separate-kill"*)
            # Has explicit variants for <=1.8.1 and >=1.9.0
            if (( cmp_min_9 >= 0 )); then
                echo -e "  $(_addon_color 32 "  ✓ Compatible: Panel >=1.9.0 detected (v$PANEL_VERSION)")"
            else
                echo -e "  $(_addon_color 32 "  ✓ Compatible: Panel <=1.8.1 detected (v$PANEL_VERSION)")"
            fi
            return 0
            ;;
        *"minecraft-jar"*|*"txadmin"*)
            # Conditional route syntax based on 1.8+
            if (( cmp_min_9 >= 0 )); then
                echo -e "  $(_addon_color 33 "  ⚠️  Panel >=1.8 detected — pakai array route syntax")"
            fi
            return 0
            ;;
        *"discord"*"notif"*)
            if (( cmp_min_10 >= 0 )); then
                _addon_compat_warning "$addon" "v2 middleware-based, cocok untuk Panel v$PANEL_VERSION"
                return 0
            fi
            ;;
        *"billing"*)
            if (( cmp_min_10 >= 0 )); then
                _addon_compat_warning "$addon" "Memerlukan composer packages eksternal — pastikan PHP $PHP_VERSION support"
                return 0
            fi
            ;;
    esac

    # Generic 1.x checks
    if echo "$lower" | grep -qE '(v1x|1x)'; then
        if (( cmp_min_11 < 0 )); then
            _addon_compat_warning "$addon" "Target Panel 1.x — Panel v$PANEL_VERSION OK"
        elif (( cmp_min_11 >= 0 )); then
            _addon_compat_warning "$addon" "Target Panel 1.x — Panel v$PANEL_VERSION (1.11+), frontend mungkin perlu rebuild"
        fi
    fi

    return 0
}

_addon_color() {
    local c=$1; shift
    echo -e "\033[${c}m$*\033[0m"
}

_addon_header() {
    clear
    echo -e "$(_addon_color 36 '═══════════════════════════════════════════')"
    echo -e "  $(_addon_color 33 'PTERODACTYL ADDON MANAGER')"
    echo -e "$(_addon_color 36 '═══════════════════════════════════════════')"
}

_addon_menu() {
    _addon_header
    echo -e "  $(_addon_color 32 '1')  Lihat & Install Addon"
    echo -e "  $(_addon_color 32 '2')  Lihat Installed Addons"
    echo -e "  $(_addon_color 32 '3')  Lihat Petunjuk Install (.txt)"
    echo -e "  $(_addon_color 32 '4')  Lihat Info Addon (size, files, kompat)"
    echo -e "  $(_addon_color 32 '5')  Search/Filter Addon"
    echo -e "  $(_addon_color 32 '6')  Diff (installed vs available)"
    echo -e "  $(_addon_color 32 '7')  Bulk Install"
    echo -e "  $(_addon_color 32 '8')  Bulk Uninstall"
    echo -e "  $(_addon_color 32 '9')  Reinstall Semua"
    echo -e "  $(_addon_color 32 '10') Uninstall Addon"
    echo -e "  $(_addon_color 32 '11') Hapus Track Installed Addon"
    echo -e "  $(_addon_color 32 '12') Export Addon State (clone server)"
    echo -e "  $(_addon_color 32 '13') Import Addon State"
    echo -e "  $(_addon_color 32 '14') Install phpMyAdmin"
    echo -e "  $(_addon_color 32 '15') Uninstall phpMyAdmin"
    echo -e "  $(_addon_color 31 '0')  Kembali"
    echo
    read -r -p "  Pilih [0-15]: " opt
    case "$opt" in
        1) _addon_list_and_install ;;
        2) _addon_show_installed ;;
        3) _addon_show_instructions ;;
        4) _addon_show_info ;;
        5) _addon_search_filter ;;
        6) _addon_diff ;;
        7) _addon_bulk_install ;;
        8) _addon_bulk_uninstall ;;
        9) _addon_reinstall_all ;;
        10) _addon_uninstall_menu ;;
        11) _addon_remove_track ;;
        12) _addon_export_state ;;
        13) _addon_import_state ;;
        14) _addon_install_phpmyadmin ;;
        15) _addon_uninstall_phpmyadmin ;;
        0) return ;;
        *) echo -e "  $(_addon_color 31 'Pilihan tidak valid')"; sleep 1 ;;
    esac
    _addon_menu
}

_addon_get_list() {
    local arr=()
    if [[ -d "$ADDON_DIR" ]]; then
        for f in "$ADDON_DIR"/*.zip; do
            [[ -f "$f" ]] || continue
            local name
            name=$(basename "$f" .zip)
            arr+=("$name")
        done
    fi
    printf '%s\n' "${arr[@]}"
}

_addon_is_installed() {
    [[ -f "$ADDON_MARKER_DIR/$1.installed" ]]
}

_addon_list_and_install() {
    require_root || return 1

    local addons=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && addons+=("$line")
    done < <(_addon_get_list)
    if [[ ${#addons[@]} -eq 0 ]]; then
        echo -e "  $(_addon_color 31 'Tidak ada addon di folder addon-pterodactyl/')"
        pause
        return
    fi

    while true; do
        _addon_header
        echo -e "  $(_addon_color 33 'Daftar Addon Tersedia:')"
        echo
        local i=0
        for a in "${addons[@]}"; do
            i=$((i+1))
            local mark=" "
            _addon_is_installed "$a" && mark="✓"
            echo -e "  $(_addon_color 32 "$i")${mark}) $a"
        done
        echo -e "  $(_addon_color 31 '0')  Kembali"
        echo
        read -r -p "  Pilih addon yang mau diinstall [0-$i]: " sel

        [[ "$sel" == "0" ]] && return
        [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= i )) || {
            echo -e "  $(_addon_color 31 'Pilihan tidak valid')"; sleep 1; continue
        }

        local chosen="${addons[$((sel-1))]}"
        _addon_install_single "$chosen"
    done
}

# =========================================================
# SMART PATCHER - file modifications
# =========================================================

_addon_panel_path() {
    echo "$PANEL_DIR/$1"
}

# Add use statement after last use statement in a PHP file
_addon_add_use() {
    local file="$1"
    local use_stmt="$2"
    local fpath="$(_addon_panel_path "$file")"
    [[ ! -f "$fpath" ]] && return 1
    grep -qF -e "$use_stmt" "$fpath" 2>/dev/null && return 0
    local last_use
    last_use=$(grep -n "^use " "$fpath" 2>/dev/null | tail -1 | cut -d: -f1)
    if [[ -n "$last_use" ]]; then
        sed -i "${last_use}a\\$use_stmt" "$fpath"
        echo -e "    $(_addon_color 32 "  + use: $file")"
        return 0
    fi
    return 1
}

# Add a line after a specific pattern in a file
_addon_insert_after() {
    local file="$1"
    local pattern="$2"
    local line="$3"
    local fpath="$(_addon_panel_path "$file")"
    [[ ! -f "$fpath" ]] && return 1
    # Cegah double: skip kalo konten sudah ada
    local check_line
    check_line=$(echo "$line" | grep -v '^[[:space:]]*$' | head -1)
    if [[ -n "$check_line" ]] && grep -qF -e "$check_line" "$fpath" 2>/dev/null; then
        echo -e "    $(_addon_color 33 "  ~ already exists: $file")"
        return 0
    fi
    # Cari baris pertama yg cocok, insert cuma sekali
    local match_line
    match_line=$(grep -nF -e "$pattern" "$fpath" 2>/dev/null | head -1 | cut -d: -f1)
    if [[ -n "$match_line" ]]; then
        local tmpfile
        tmpfile=$(mktemp)
        printf '%s\n' "$line" > "$tmpfile"
        sed -i "${match_line}r $tmpfile" "$fpath" 2>/dev/null || { rm -f "$tmpfile"; return 1; }
        rm -f "$tmpfile"
        echo -e "    $(_addon_color 32 "  + insert: $file")"
        return 0
    else
        echo -e "    $(_addon_color 31 "  ! pattern not found: $pattern")"
        return 1
    fi
}

# Replace a pattern in a file (exact match)
_addon_replace() {
    local file="$1"
    local old="$2"
    local new="$3"
    local fpath="$(_addon_panel_path "$file")"
    [[ ! -f "$fpath" ]] && return 1
    if grep -qF -e "$old" "$fpath" 2>/dev/null; then
        sed -i "s|$(printf '%s' "$old" | sed 's|/|\\/|g')|$(printf '%s' "$new" | sed 's|/|\\/|g')|" "$fpath" 2>/dev/null
        echo -e "    $(_addon_color 32 "  + replace: $file")"
        return 0
    fi
    return 1
}

# Append content to end of file
_addon_append_file() {
    local file="$1"
    local content="$2"
    local fpath="$(_addon_panel_path "$file")"
    [[ ! -f "$fpath" ]] && return 1
    echo "$content" >> "$fpath"
    echo -e "    $(_addon_color 32 "  + append: $file")"
    return 0
}

# Install composer packages
_addon_composer_require() {
    local pkg="$1"
    echo -e "    $(_addon_color 36 "  composer require $pkg...")"
    cd "$PANEL_DIR" && COMPOSER_ALLOW_SUPERUSER=1 composer require "$pkg" --quiet 2>/dev/null && {
        echo -e "    $(_addon_color 32 "  + composer: $pkg")"
        return 0
    } || {
        echo -e "    $(_addon_color 33 "  ~ composer skip: $pkg")"
        return 1
    }
}

# Add yarn packages
_addon_yarn_add() {
    local pkg="$1"
    echo -e "    $(_addon_color 36 "  yarn add $pkg...")"
    cd "$PANEL_DIR" && yarn add "$pkg" 2>/dev/null && {
        echo -e "    $(_addon_color 32 "  + yarn: $pkg")"
        return 0
    } || {
        echo -e "    $(_addon_color 33 "  ~ yarn skip: $pkg")"
        return 1
    }
}

# Add route group to admin.php (writes to separate file in routes/addons/admin/)
_addon_add_route_admin() {
    local addon_slug="$1"
    local route_content="$2"
    [[ -z "$addon_slug" ]] && addon_slug="addon"

    local dir="$PANEL_DIR/routes/addons/admin"
    mkdir -p "$dir"

    route_content=$(php -r '
        $in = stream_get_contents(STDIN);
        $prefix = "";
        $out = "";
        foreach (explode("\n", $in) as $line) {
            if (preg_match("/prefix\"\s*=>\s*\"([^\"]+)\"/", $line, $m)) {
                $prefix = $m[1];
            }
            if (preg_match("/Route::(get|post|put|patch|delete|any)\s*\(\s*\"([^\"]+)\"/", $line, $m)) {
                $method = $m[1];
                $path = $m[2];
                if (strpos($line, "->name(") === false && $path !== "") {
                    $name = "admin." . $prefix;
                    $parts = explode("/", trim($path, "/"));
                    foreach ($parts as $p) {
                        if ($p !== "" && $p[0] !== "{") {
                            $name .= "." . str_replace(["-","/"], [".","."], $p);
                        }
                    }
                    $line = rtrim($line, "; \t\n\r\0\x0B") . "->name(\"$name\");";
                    $line = preg_replace("/\)\s*\);\s*$/", ")->name(\"$name\");", $line);
                }
            }
            $out .= $line . "\n";
        }
        echo $out;
    ' <<< "$route_content" 2>/dev/null)

    echo "<?php" > "$dir/$addon_slug.php"
    echo "" >> "$dir/$addon_slug.php"
    echo "use Pterodactyl\\Http\\Controllers\\Admin;" >> "$dir/$addon_slug.php"
    echo "" >> "$dir/$addon_slug.php"
    echo -e "$route_content" >> "$dir/$addon_slug.php"

    # Track for uninstall
    _ADDON_ROUTE_SLUGS="${_ADDON_ROUTE_SLUGS}admin:${addon_slug} "
}

# Add route group to api-client.php (writes to routes/addons/api/)
_addon_add_route_api() {
    local route_content="$1"
    local addon_slug="$2"
    [[ -z "$addon_slug" ]] && addon_slug="addon"

    local dir="$PANEL_DIR/routes/addons/api"
    mkdir -p "$dir"
    echo "<?php" > "$dir/$addon_slug.php"
    echo "" >> "$dir/$addon_slug.php"
    echo "use Pterodactyl\\Http\\Controllers\\Api\\Client;" >> "$dir/$addon_slug.php"
    echo "" >> "$dir/$addon_slug.php"
    echo -e "$route_content" >> "$dir/$addon_slug.php"

    # Track for uninstall
    _ADDON_ROUTE_SLUGS="${_ADDON_ROUTE_SLUGS}api:${addon_slug} "
}

# Add route group to api-remote.php (writes to routes/addons/remote/)
_addon_add_route_remote() {
    local route_content="$1"
    local addon_slug="$2"
    [[ -z "$addon_slug" ]] && addon_slug="addon"

    local dir="$PANEL_DIR/routes/addons/remote"
    mkdir -p "$dir"
    echo "<?php" > "$dir/$addon_slug.php"
    echo "" >> "$dir/$addon_slug.php"
    echo "use Pterodactyl\\Http\\Controllers\\Api\\Remote;" >> "$dir/$addon_slug.php"
    echo "" >> "$dir/$addon_slug.php"
    echo -e "$route_content" >> "$dir/$addon_slug.php"

    # Track for uninstall
    _ADDON_ROUTE_SLUGS="${_ADDON_ROUTE_SLUGS}remote:${addon_slug} "
}

# Add nav item to admin.blade.php (after the COMPLETE nav item, not mid-element)
_addon_add_admin_nav() {
    local nav_html="$1"
    local after_ref="${2:-admin.databases}"
    local file="resources/views/layouts/admin.blade.php"
    local fpath="$(_addon_panel_path "$file")"
    [[ ! -f "$fpath" ]] && return 1

    # Cari baris referensi, lalu cari </li> setelahnya (biar ga nyelip di tengah nav)
    local ref_line
    ref_line=$(grep -nF -e "$after_ref" "$fpath" 2>/dev/null | head -1 | cut -d: -f1)
    [[ -z "$ref_line" ]] && { echo -e "    $(_addon_color 31 "  ! pattern not found: $after_ref")"; return 1; }

    local after_line
    after_line=$(sed -n "$ref_line,\$p" "$fpath" | grep -n '</li>' | head -1 | cut -d: -f1)
    [[ -z "$after_line" ]] && { echo -e "    $(_addon_color 31 "  ! closing </li> not found")"; return 1; }

    local insert_line=$((ref_line + after_line - 1))

    # Cegah double: skip kalo konten sudah ada
    local check_line
    check_line=$(echo "$nav_html" | grep -v '^[[:space:]]*$' | head -1)
    if [[ -n "$check_line" ]] && grep -qF -e "$check_line" "$fpath" 2>/dev/null; then
        echo -e "    $(_addon_color 33 "  ~ already exists: $file")"
        return 0
    fi

    local tmpfile
    tmpfile=$(mktemp)
    printf '%s\n' "$nav_html" > "$tmpfile"
    sed -i "${insert_line}r $tmpfile" "$fpath" 2>/dev/null || { rm -f "$tmpfile"; return 1; }
    rm -f "$tmpfile"
    echo -e "    $(_addon_color 32 "  + nav: $file")"
    return 0
}

# =========================================================
# INSTRUCTION PARSER - reads instruction files and applies patches
# =========================================================

_addon_parse_instructions() {
    local tmpdir="$1"
    local topdir="$2"

    local inst_file
    inst_file=$(find "$tmpdir" -maxdepth 3 -name "manual_install.txt" 2>/dev/null | head -1)
    [[ -z "$inst_file" ]] && inst_file=$(find "$tmpdir" -maxdepth 3 -name "PanelEdit.txt" 2>/dev/null | head -1)
    [[ -z "$inst_file" ]] && inst_file=$(find "$tmpdir" -maxdepth 3 -name "paneledit.txt" 2>/dev/null | head -1)
    [[ -z "$inst_file" ]] && inst_file=$(find "$tmpdir" -maxdepth 3 -name "WingsEdit.txt" 2>/dev/null | head -1)
    [[ -z "$inst_file" ]] && inst_file=$(find "$tmpdir" -maxdepth 3 -name "wingsedit.txt" 2>/dev/null | head -1)

    [[ -z "$inst_file" ]] && return 1

    local content
    content=$(cat "$inst_file" 2>/dev/null)
    [[ -z "$content" ]] && return 1

    echo -e "  $(_addon_color 36 'Membaca petunjuk install...')"
    ADDON_ROUTE_COUNTER=0

    # --- Detect and apply route additions ---
    # Look for Route::group, Route::prefix, Route::get, Route::post, Route::delete, Route::patch blocks
    local current_routes=""
    local in_route_block=0
    local route_file=""

    while IFS= read -r line; do
        # Detect route file context
        if echo "$line" | grep -qiE "(routes/admin\.php|routes/api-client\.php)"; then
            if echo "$line" | grep -qi "admin"; then
                route_file="admin"
            elif echo "$line" | grep -qi "api"; then
                route_file="api"
            fi
            in_route_block=1
            current_routes=""
            continue
        fi

        # Collect route blocks
        if [[ $in_route_block -eq 1 ]]; then
            local stripped
            stripped=$(echo "$line" | sed 's/^[[:space:]]*//')
            if echo "$stripped" | grep -qE '^(Route::|/\*|use |\?>|```|$)' || [[ -z "$stripped" ]]; then
                if echo "$stripped" | grep -qE '^Route::'; then
                    current_routes+="$line"$'\n'
                elif echo "$stripped" | grep -qE '^\}' && echo "$current_routes" | grep -q 'Route::'; then
                    current_routes+="$line"$'\n'
                    # End of route block detected by closing brace
                fi
            else
                # Non-route content found, flush if we have routes
                if [[ -n "$current_routes" ]] && echo "$current_routes" | grep -qE 'Route::(get|post|delete|patch|put|group|prefix)'; then
                    # Clean up the route content
                    local clean_routes
                    clean_routes=$(echo "$current_routes" | grep -v '^```' | grep -v '^[[:space:]]*$')
                    if [[ -n "$clean_routes" ]]; then
                        echo -e "  $(_addon_color 36 "  Menambahkan route ke $route_file...")"
                        ADDON_ROUTE_COUNTER=$((ADDON_ROUTE_COUNTER + 1))
                        if [[ "$route_file" == "admin" ]]; then
                            _addon_add_route_admin "addon_auto_$ADDON_ROUTE_COUNTER" "$clean_routes"
                        else
                            _addon_add_route_api "$clean_routes" "addon_auto_$ADDON_ROUTE_COUNTER"
                        fi
                    fi
                    current_routes=""
                    in_route_block=0
                fi
            fi
            # Still collect content
            if echo "$stripped" | grep -qE '^(Route::|/\*|})'; then
                current_routes+="$line"$'\n'
            fi
        fi
    done <<< "$content"

    # --- Detect and apply Nav additions ---
    local nav_section=0
    local nav_content=""
    local nav_ref=""
    while IFS= read -r line; do
        if echo "$line" | grep -qiE "(admin\.blade\.php|layouts/admin)"; then
            nav_section=1
            nav_content=""
            nav_ref=""
            continue
        fi
        if [[ $nav_section -eq 1 ]]; then
            if echo "$line" | grep -qE '<li.*class=.*starts_with.*Route::'; then
                nav_content+="$line"$'\n'
            elif echo "$line" | grep -qE '</li>' && [[ -n "$nav_content" ]]; then
                nav_content+="$line"
                # Found a full nav item, try to add it
                local ref_match
                ref_match=$(echo "$nav_content" | grep -oP "route\('[^']+'" | head -1 | tr -d "'")
                [[ -z "$ref_match" ]] && ref_match=$(echo "$nav_content" | grep -oP "route\('[^']+'" | head -1 | tr -d "'")
                [[ -z "$ref_match" ]] && ref_match="admin.databases"
                echo -e "  $(_addon_color 36 "  Menambahkan nav item...")"
                _addon_add_admin_nav "$nav_content" "$ref_match"
                nav_content=""
                nav_section=0
            else
                [[ -n "$nav_content" ]] && nav_content+="$line"$'\n'
            fi
        fi
    done <<< "$content"

    # --- Detect and apply Use statement additions ---
    while IFS= read -r line; do
        local stripped
        stripped=$(echo "$line" | sed 's/^[[:space:]]*//')
        if echo "$stripped" | grep -qE '^use (Pterodactyl|Illuminate)'; then
            # Determine which file this goes to
            local use_file=""
            local check_lines="$content"
            local ctx=""
            ctx=$(echo "$check_lines" | grep -B5 "$stripped" | head -5)
            if echo "$ctx" | grep -qiE "(app/Providers|RepositoryServiceProvider)"; then
                use_file="app/Providers/RepositoryServiceProvider.php"
            elif echo "$ctx" | grep -qiE "(app/Models|Permission\.php)"; then
                use_file="app/Models/Permission.php"
            elif echo "$ctx" | grep -qiE "(DatabaseController|app/Http/Controllers)"; then
                use_file=$(echo "$ctx" | grep -oP "app/Http/Controllers/[^ ]+" | head -1)
            fi
            if [[ -n "$use_file" ]]; then
                _addon_add_use "$use_file" "$stripped"
            fi
        fi
    done <<< "$content"

    # --- Direct file edit instructions (insert after / add below / replace) ---
    local current_file=""
    local current_pattern=""
    local current_lines=""
    local mode=""

    while IFS= read -r line; do
        local stripped
        stripped=$(echo "$line" | sed 's/^[[:space:]]*//')

        # Detect file context
        if echo "$stripped" | grep -qE '^(/var/www/pterodactyl|app/|resources/|routes/|config/|database/)'; then
            # Flush previous
            if [[ -n "$current_file" && -n "$current_pattern" && -n "$current_lines" ]]; then
                _addon_insert_after "$current_file" "$current_pattern" "$current_lines"
            fi
            current_file=$(echo "$stripped" | sed 's|/var/www/pterodactyl/||' | tr -d '`*')
            current_pattern=""
            current_lines=""
            mode="file"
            continue
        fi

        # Detect "add after/below/under" patterns
        if echo "$line" | grep -qiE "(below|after|under|add after|insert after|paste below|under the following)"; then
            current_pattern=""
            mode="add"
            continue
        fi

        # Detect "search" or "replace" patterns
        if echo "$stripped" | grep -qiE "^(search|find|replace|look for)"; then
            current_pattern=""
            mode="search"
            continue
        fi

        # Detect code blocks
        if echo "$stripped" | grep -qE '^```'; then
            if [[ -z "$current_lines" ]]; then
                mode="code"
                current_lines=""
            else
                # End of code block - apply if we have context
                if [[ -n "$current_file" && -n "$current_lines" ]]; then
                    # Determine if this is an insert or replace based on mode
                    if echo "$current_lines" | grep -qE '^Route::' || echo "$current_lines" | grep -qE '<li'; then
                        # Handled separately above
                        true
                    elif [[ -n "$current_pattern" ]]; then
                        _addon_insert_after "$current_file" "$current_pattern" "$current_lines"
                    fi
                fi
                current_lines=""
                mode=""
            fi
            continue
        fi

        # Collect content
        if [[ "$mode" == "code" ]]; then
            if [[ -z "$current_lines" ]]; then
                current_lines="$stripped"
            else
                current_lines+=$'\n'"$stripped"
            fi
        fi
    done <<< "$content"

    # --- Detect composer requires ---
    while IFS= read -r line; do
        if echo "$line" | grep -qiE "composer require"; then
            local pkg
            pkg=$(echo "$line" | sed 's/.*composer require //' | xargs | tr -d "\\\"\`'")
            if [[ -n "$pkg" ]]; then
                _addon_composer_require "$pkg"
            fi
        fi
    done <<< "$content"

    # --- Detect yarn package adds ---
    while IFS= read -r line; do
        if echo "$line" | grep -qiE "yarn add (--dev )?" && ! echo "$line" | grep -qiE "yarn install|build:"; then
            local pkg
            pkg=$(echo "$line" | sed 's/.*yarn add //' | tr -d "\\\"\`'" | awk '{print $1}')
            if [[ -n "$pkg" ]]; then
                _addon_yarn_add "$pkg"
            fi
        fi
    done <<< "$content"

    # --- Detect PHP artisan optimize commands ---
    if echo "$content" | grep -qiE "php artisan optimize"; then
        echo -e "  $(_addon_color 36 '  Running artisan optimize...')"
        cd "$PANEL_DIR" && php artisan optimize 2>/dev/null || true
    fi

    if echo "$content" | grep -qiE "php artisan view:clear"; then
        echo -e "  $(_addon_color 36 '  Running artisan view:clear...')"
        cd "$PANEL_DIR" && php artisan view:clear 2>/dev/null || true
    fi

    if echo "$content" | grep -qiE "php artisan cache:clear"; then
        echo -e "  $(_addon_color 36 '  Running artisan cache:clear...')"
        cd "$PANEL_DIR" && php artisan cache:clear 2>/dev/null || true
    fi

    if echo "$content" | grep -qiE "php artisan route:clear"; then
        echo -e "  $(_addon_color 36 '  Running artisan route:clear...')"
        cd "$PANEL_DIR" && php artisan route:clear 2>/dev/null || true
    fi

    # --- Detect .env additions ---
    if echo "$content" | grep -qiE "CURSEFORGE_API_KEY|\.env"; then
        while IFS= read -r line; do
            if echo "$line" | grep -qE '^[A-Z_]+=' && echo "$line" | grep -qiE "curl|key|secret|token|url"; then
                local env_key
                local env_val
                env_key=$(echo "$line" | cut -d= -f1)
                env_val=$(echo "$line" | cut -d= -f2- | tr -d "\\\"\`'")
                if grep -q "^$env_key=" "$PANEL_DIR/.env" 2>/dev/null; then
                    echo -e "    $(_addon_color 33 "  ~ .env: $env_key already exists")"
                else
                    echo "$env_key=$env_val" >> "$PANEL_DIR/.env"
                    echo -e "    $(_addon_color 32 "  + .env: $env_key")"
                fi
            fi
        done <<< "$content"
    fi

    return 0
}

# =========================================================
# HANDLER-BASED INSTALL for specific addons
# =========================================================

_addon_handle_activitypurges() {
    _addon_add_route_admin 'activitypurges' '
/*
|--------------------------------------------------------------------------
| Activity Purges Controller Routes
|--------------------------------------------------------------------------
|
| Endpoint: /admin/activitypurges
|
*/
Route::prefix("/activitypurges")->group(function () {
    Route::get("/", [Admin\ActivityPurgesController::class, "index"])->name("admin.activitypurges");
    Route::post("/", [Admin\ActivityPurgesController::class, "post"]);
});
'
    _addon_add_admin_nav '
                        <li class="{{ ! starts_with(Route::currentRouteName(), "admin.activitypurges") ?: "active" }}">
                            <a href="{{ route("admin.activitypurges")}}">
                                <i class="fa fa-eraser"></i> <span>Activity Purges</span>
                            </a>
                        </li>
' "admin.databases"
}

_addon_handle_ramlimit() {
    _addon_add_use "app/Console/Kernel.php" "use Pterodactyl\Console\Commands\Server\RamLimit;"
    _addon_insert_after "app/Console/Kernel.php" 'CleanServiceBackupFilesCommand::class' '$schedule->command(RamLimit::class)->everyMinute();'
    _addon_add_route_admin 'ramlimit' '
/*
|--------------------------------------------------------------------------
| RamLimit Controller Routes
|--------------------------------------------------------------------------
|
| Endpoint: /admin/ramlimit
|
*/
Route::group(["prefix" => "ramlimit"], function () {
    Route::get("/", [Admin\RamLimitController::class, "index"])->name("admin.ramlimit");
    Route::post("/system", [Admin\RamLimitController::class, "system"])->name("admin.ramlimit.system");
    Route::post("/discord", [Admin\RamLimitController::class, "discord"])->name("admin.ramlimit.discord");
});
'
    _addon_add_admin_nav '
                        <!-- RamLimit Section -->
                        <li class="{{ ! starts_with(Route::currentRouteName(), "admin.ramlimit") ?: "active" }}">
                            <a href="{{ route("admin.ramlimit") }}">
                                <i class="fa fa-stop-circle-o"></i> <span>RamLimit</span>
                            </a>
                        </li>
' "admin.nests"
}

_addon_handle_player_counter() {
    _addon_add_route_admin 'player_counter' '
/*
|--------------------------------------------------------------------------
| Player Counter Routes
|--------------------------------------------------------------------------
*/
Route::group(["prefix" => "players"], function () {
    Route::get("/", [Admin\PlayerCounterController::class, "index"])->name("admin.players");
    Route::post("/create", [Admin\PlayerCounterController::class, "create"]);
    Route::post("/update", [Admin\PlayerCounterController::class, "update"]);
    Route::post("/delete", [Admin\PlayerCounterController::class, "delete"]);
});
'
    _addon_add_admin_nav '
                        <li class="{{ ! starts_with(Route::currentRouteName(), "admin.players") ?: "active" }}">
                            <a href="{{ route("admin.players") }}">
                                <i class="fa fa-gamepad"></i> <span>Player Counter</span>
                            </a>
                        </li>
' "admin.databases"
    _addon_composer_require "austinb/gameq:~3.0" || true
    _addon_composer_require "xpaw/php-source-query-class" || true
    _addon_composer_require "xpaw/php-minecraft-query" || true
}

_addon_handle_staff_system() {
    _addon_add_route_admin 'staff_system' '
Route::group(["prefix" => "staff"], function () {
    Route::post("/update/{id}", [Admin\StaffController::class, "update"])->name("admin.staff.update");
});
'
}

# Create required DatabaseBackup files (model, services, migration) if missing
_addon_ensure_database_backup_files() {
    local base="$PANEL_DIR"
    local created=0

    if [[ ! -f "$base/app/Models/DatabaseBackup.php" ]]; then
        mkdir -p "$base/app/Models"
        cat > "$base/app/Models/DatabaseBackup.php" << 'DBMODEL'
<?php

namespace Pterodactyl\Models;

use Illuminate\Database\Eloquent\Model;

class DatabaseBackup extends Model
{
    protected $table = 'database_backups';

    protected $fillable = [
        'server_id',
        'database_host_id',
        'name',
        'file',
        'is_automatic',
    ];
}
DBMODEL
        echo -e "    $(_addon_color 32 "  + created: app/Models/DatabaseBackup.php")"
        created=$((created + 1))
    fi

    if [[ ! -f "$base/database/migrations/2022_09_20_000000_create_database_backups_table.php" ]]; then
        mkdir -p "$base/database/migrations"
        cat > "$base/database/migrations/2022_09_20_000000_create_database_backups_table.php" << 'DBMIGRATION'
<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

class CreateDatabaseBackupsTable extends Migration
{
    public function up()
    {
        Schema::create('database_backups', function (Blueprint $table) {
            $table->increments('id');
            $table->unsignedInteger('server_id');
            $table->unsignedInteger('database_host_id');
            $table->string('name');
            $table->string('file')->nullable();
            $table->integer('is_automatic')->default(0);
            $table->timestamps();
        });
    }

    public function down()
    {
        Schema::dropIfExists('database_backups');
    }
}
DBMIGRATION
        echo -e "    $(_addon_color 32 "  + created: migration create_database_backups_table")"
        created=$((created + 1))
    fi

    local sdir="$base/app/Services/Backups/Databases"
    if [[ ! -f "$sdir/CreateDatabaseBackupService.php" ]]; then
        mkdir -p "$sdir"
        cat > "$sdir/CreateDatabaseBackupService.php" << 'CDBS'
<?php

namespace Pterodactyl\Services\Backups\Databases;

use Pterodactyl\Models\Database;
use Pterodactyl\Models\DatabaseBackup;

class CreateDatabaseBackupService
{
    public function startBackup(Database $database, string $name, string $connection): array
    {
        $backup = DatabaseBackup::create([
            'server_id' => $database->server_id,
            'database_host_id' => $database->database_host_id,
            'name' => $name,
            'is_automatic' => 1,
        ]);

        return ['created' => true, 'backup' => $backup];
    }
}
CDBS
        echo -e "    $(_addon_color 32 "  + created: CreateDatabaseBackupService")"
        created=$((created + 1))
    fi

    if [[ ! -f "$sdir/DeleteDatabaseBackupService.php" ]]; then
        cat > "$sdir/DeleteDatabaseBackupService.php" << 'DDBS'
<?php

namespace Pterodactyl\Services\Backups\Databases;

use Pterodactyl\Models\DatabaseBackup;

class DeleteDatabaseBackupService
{
    public static function delete(int $id): void
    {
        $backup = DatabaseBackup::query()->find($id);
        if ($backup) {
            $backup->delete();
        }
    }
}
DDBS
        echo -e "    $(_addon_color 32 "  + created: DeleteDatabaseBackupService")"
        created=$((created + 1))
    fi

    [[ $created -gt 0 ]] && chown -R www-data:www-data "$base/app/Models/DatabaseBackup.php" "$base/database/migrations/2022_09_20_000000_create_database_backups_table.php" "$sdir" 2>/dev/null || true
}

_addon_handle_automatic_backups() {
    _addon_ensure_database_backup_files

    # Hapus migration redundant dari zip — kolom is_automatic udah ada di
    # create_database_backups_table dari _addon_ensure_database_backup_files
    rm -f "$PANEL_DIR/database/migrations/2022_09_21_083710_add_is_automatic_column_to_database_backups_table.php"

    _addon_add_route_admin 'automatic_backups' '
Route::group(["prefix" => "/backup"], function () {
    Route::get("/", [Admin\BackupController::class, "index"])->name("admin.backup");
    Route::post("/save", [Admin\BackupController::class, "save"])->name("admin.backup.save");
    Route::post("/save/database", [Admin\BackupController::class, "saveDatabase"])->name("admin.backup.save.database");
});
'
    _addon_add_admin_nav '
                        <li class="{{ ! starts_with(Route::currentRouteName(), "admin.backup") ?: "active" }}">
                            <a href="{{ route("admin.backup") }}">
                                <i class="fa fa-folder"></i> <span>Auto Backup</span>
                            </a>
                        </li>
' "admin.nodes"
    _addon_insert_after "app/Console/Kernel.php" 'CleanServiceBackupFilesCommand::class' '
$runAt = \Pterodactyl\Models\Setting::query()->where("key", "=", "backup::auto::run")->first();
$schedule->command(\Pterodactyl\Console\Commands\Backups\AutomaticBackupCommand::class)->dailyAt(!$runAt ? "02:00" : $runAt->value);
$runAt = \Pterodactyl\Models\Setting::query()->where("key", "=", "backup::database::auto::run")->first();
$schedule->command(\Pterodactyl\Console\Commands\Backups\AutomaticDatabaseBackupCommand::class)->dailyAt(!$runAt ? "02:00" : $runAt->value);
'
}

_addon_handle_ticket_system() {
    _addon_add_route_admin 'ticket_system' '
Route::group(["prefix" => "tickets"], function () {
    Route::get("/", [Admin\TicketsController::class, "index"])->name("admin.tickets");
    Route::get("/view/{id}", [Admin\TicketsController::class, "view"])->name("admin.tickets.view");
    Route::post("/status/{id}", [Admin\TicketsController::class, "status"]);
    Route::post("/reply/{id}", [Admin\TicketsController::class, "reply"]);
    Route::group(["prefix" => "categories"], function () {
        Route::get("/", [Admin\TicketsController::class, "categories"])->name("admin.tickets.categories");
        Route::post("/create", [Admin\TicketsController::class, "createCategory"]);
        Route::post("/delete", [Admin\TicketsController::class, "deleteCategory"]);
    });
});
'
    _addon_add_admin_nav '
                        <li class="{{ ! starts_with(Route::currentRouteName(), "admin.tickets") ?: "active" }}">
                            <a href="{{ route("admin.tickets") }}">
                                <i class="fa fa-ticket"></i> <span>Tickets</span>
                            </a>
                        </li>
' "admin.databases"
}

_addon_handle_discord_notifications() {
    _addon_add_route_admin 'discord_notifications' '
Route::group(["prefix" => "myplugins/discord"], function () {
    Route::get("/", [Admin\DiscordController::class, "index"])->name("admin.discord");
    Route::patch("/", [Admin\DiscordController::class, "update"]);
});
'
    _addon_add_admin_nav '
                        <li class="{{ ! starts_with(Route::currentRouteName(), "admin.discord") ?: "active" }}">
                            <a href="{{ route("admin.discord") }}">
                                <i class="fa fa-discord"></i> <span>Discord Notifications</span>
                            </a>
                        </li>
' "admin.databases"
}

_addon_handle_sftp_alias() {
    _addon_insert_after "app/Http/Controllers/Admin/Nodes/NodeViewController.php" 'daemon_token' "->only(['scheme', 'fqdn', 'daemonListen', 'daemon_token_id', 'daemon_token', 'sftp_alias'])," || true
}

_addon_handle_billing_system() {
    _addon_composer_require "stripe/stripe-php" || true
    _addon_composer_require "paypal/rest-api-sdk-php:*" || true
    _addon_composer_require "laraveldaily/laravel-invoices:^3.0" || true
    _addon_add_route_admin 'billing_system' '
Route::group(["prefix" => "shop"], function () {
    Route::get("/", [Admin\ShopController::class, "index"])->name("admin.shop");
    Route::get("/settings", [Admin\ShopController::class, "settings"])->name("admin.shop.settings");
    Route::get("/payments", [Admin\ShopController::class, "payments"])->name("admin.shop.payments");
    Route::get("/categories", [Admin\ShopController::class, "categories"])->name("admin.shop.categories");
    Route::get("/games", [Admin\ShopController::class, "games"])->name("admin.shop.games");
});
'
}

# Dispatch to specific handlers based on addon name keywords
_addon_run_handler() {
    local addon="$1"
    local topdir="$2"
    local lower
    lower=$(echo "$addon" | tr '[:upper:]' '[:lower:]')

    case "$lower" in
        *"activitypurge"*)            _addon_handle_activitypurges ;;
        *"addon off"*|*"ram"*|*"limit"*) _addon_handle_ramlimit ;;
        *"player"*"counter"*)         _addon_handle_player_counter ;;
        *"staff"*"system"*)           _addon_handle_staff_system ;;
        *"automatic"*"backup"*)       _addon_handle_automatic_backups ;;
        *"ticket"*)                   _addon_handle_ticket_system ;;
        *"discord"*"notif"*)          _addon_handle_discord_notifications ;;
        *"sftp"*"alias"*)             _addon_handle_sftp_alias ;;
        *"billing"*|*"shop"*)         _addon_handle_billing_system ;;
        *"separate"*"kill"*)          _addon_handle_separate_kill "$topdir" ;;
        *"node"*"maintenance"*)       _addon_handle_node_maintenance ;;
        *"pterodactyl"*"region"*)     _addon_handle_pterodactyl_region ;;
        *"minecraft"*"jar"*)          _addon_handle_minecraft_jar ;;
        *"email"*"util"*)             _addon_handle_emailutils ;;
        *"phpmyadmin"*)               _addon_handle_automatic_phpmyadmin ;;
        *"smart"*"file"*"search"*)    _addon_handle_smart_file_search ;;
        *"ip"*"blur"*|*"ipblur"*)     _addon_handle_ipblur ;;
        *"pterodacard"*)              _addon_handle_pterodacards ;;
        *"code"*"linter"*)            _addon_handle_code_linter ;;
        *"minecraft"*"mod"*)          _addon_handle_minecraft_mod_manager ;;
        *"minecraft"*"world"*)        _addon_handle_minecraft_world_manager ;;
        *"whmcs"*)                    _addon_handle_whmcs_sso ;;
        *"txadmin"*)                  _addon_handle_txadmin ;;
        *"firewall"*)                 _addon_handle_firewall ;;
        *"discord"*"auth"*)           _addon_handle_discord_auth ;;
        *"userimage"*)                _addon_handle_userimage ;;

    esac
    return 0
}

# ---- Specific addon handlers ----

_addon_handle_separate_kill() {
    local topdir="$1"
    # Check for version-specific folders inside the zip
    if [[ -d "$topdir/Kill" && -d "$topdir/Microsoft" ]]; then
        # v1.9.0+ variant uses simple file upload
        if (( PANEL_VERSION_MAJOR >= 1 && PANEL_VERSION_MINOR >= 9 )); then
            echo -e "    $(_addon_color 36 "  Panel >=1.9 detected — using v1.9+ files")"
            [[ -d "$topdir/Kill" ]] && cp -r "$topdir/Kill/"* "$PANEL_DIR/resources/scripts/components/server/" 2>/dev/null || true
        else
            echo -e "    $(_addon_color 36 "  Panel <1.9 detected — using v1.8 files")"
            [[ -d "$topdir/Microsoft" ]] && cp -r "$topdir/Microsoft/"* "$PANEL_DIR/resources/scripts/components/server/" 2>/dev/null || true
        fi
    fi
    _addon_yarn_build
}

_addon_handle_node_maintenance() {
    local panel_ver="$PANEL_VERSION"
    _addon_insert_after "app/Transformers/Api/Client/ServerTransformer.php" "'is_transferring'" "            'is_maintenance' => \$server->node->maintenance_mode,"
}

_addon_handle_pterodactyl_region() {
    # Try curl-based installer
    echo -e "    $(_addon_color 36 "  Menjalankan installer eksternal...")"
    curl -s https://exeyarikus.info/pterodactyl-region/install 2>/dev/null | bash 2>/dev/null || true
}

_addon_handle_minecraft_jar() {
    # Conditional route syntax for 1.8+
    if (( PANEL_VERSION_MAJOR >= 1 && PANEL_VERSION_MINOR >= 8 )); then
        _addon_add_route_api '
Route::post("/{server}/checkjar", [Client\Servers\ServerController::class, "checkjar"]);
' 'minecraft_jar'
    else
        _addon_add_route_api '
Route::post("/checkjar/{server}", "Client\Servers\ServerController@checkJar");
' 'minecraft_jar'
    fi
}

_addon_handle_emailutils() {
    # Provider auto-discovered by generic scanner
    # Just clean up any wrong namespace from previous version
    local config_file="config/app.php"
    local fpath="$(_addon_panel_path "$config_file")"
    if [[ -f "$fpath" ]] && grep -q "Extensions.*EmailUtils.*EmailUtilsServiceProvider" "$fpath" 2>/dev/null; then
        sed -i "/Extensions.*EmailUtils.*EmailUtilsServiceProvider/d" "$fpath" 2>/dev/null || true
        echo -e "    $(_addon_color 33 "  ~ cleaned wrong provider entry")"
    fi

    # Add admin nav item for Email Utils (after Settings)
    _addon_add_admin_nav '
                        <li class="{{ ! starts_with(Route::currentRouteName(), "admin.email-utils") ?: "active" }}">
                            <a href="{{ route("admin.email-utils") }}">
                                <i class="fa fa-envelope"></i> <span>Email Utils</span>
                            </a>
                        </li>
' "admin.settings"

    # Patch all 6 notification files to use EmailTemplateManager
    local use_import="use Pterodactyl\Services\EmailUtils\EmailTemplateManager;"
    local use_target="use Illuminate\Notifications\Messages\MailMessage;"

    # AccountCreated
    _addon_insert_after "app/Notifications/AccountCreated.php" "$use_target" "$use_import"
    _addon_replace "app/Notifications/AccountCreated.php" \
        "public function toMail(): MailMessage" \
        "public function toMail(mixed \$notifiable = null): MailMessage"
    # AccountCreated already uses $message, just change the final return
    _addon_replace "app/Notifications/AccountCreated.php" \
        "        return \$message;" \
        "        return EmailTemplateManager::applyFromNotification(\$this, \$notifiable, \$message);"

    # SendPasswordReset (already has mixed $notifiable, just add = null)
    _addon_insert_after "app/Notifications/SendPasswordReset.php" "$use_target" "$use_import"
    _addon_replace "app/Notifications/SendPasswordReset.php" \
        "public function toMail(mixed \$notifiable): MailMessage" \
        "public function toMail(mixed \$notifiable = null): MailMessage"
    _addon_replace "app/Notifications/SendPasswordReset.php" \
        "        return (new MailMessage())" \
        "        \$message = (new MailMessage())"
    _addon_insert_after "app/Notifications/SendPasswordReset.php" \
        "->line('If you did not request a password reset, no further action is required.');" \
        "        return EmailTemplateManager::applyFromNotification(\$this, \$notifiable, \$message);"

    # AddedToServer
    _addon_insert_after "app/Notifications/AddedToServer.php" "$use_target" "$use_import"
    _addon_replace "app/Notifications/AddedToServer.php" \
        "public function toMail(): MailMessage" \
        "public function toMail(mixed \$notifiable = null): MailMessage"
    _addon_replace "app/Notifications/AddedToServer.php" \
        "        return (new MailMessage())" \
        "        \$message = (new MailMessage())"
    _addon_insert_after "app/Notifications/AddedToServer.php" \
        "->action('Visit Server', url('/server/' . \$this->server->uuidShort));" \
        "        return EmailTemplateManager::applyFromNotification(\$this, \$notifiable, \$message);"

    # RemovedFromServer
    _addon_insert_after "app/Notifications/RemovedFromServer.php" "$use_target" "$use_import"
    _addon_replace "app/Notifications/RemovedFromServer.php" \
        "public function toMail(): MailMessage" \
        "public function toMail(mixed \$notifiable = null): MailMessage"
    _addon_replace "app/Notifications/RemovedFromServer.php" \
        "        return (new MailMessage())" \
        "        \$message = (new MailMessage())"
    _addon_insert_after "app/Notifications/RemovedFromServer.php" \
        "->action('Visit Panel', route('index'));" \
        "        return EmailTemplateManager::applyFromNotification(\$this, \$notifiable, \$message);"

    # ServerInstalled
    _addon_insert_after "app/Notifications/ServerInstalled.php" "$use_target" "$use_import"
    _addon_replace "app/Notifications/ServerInstalled.php" \
        "public function toMail(): MailMessage" \
        "public function toMail(mixed \$notifiable = null): MailMessage"
    _addon_replace "app/Notifications/ServerInstalled.php" \
        "        return (new MailMessage())" \
        "        \$message = (new MailMessage())"
    _addon_insert_after "app/Notifications/ServerInstalled.php" \
        "->action('Login and Begin Using', route('index'));" \
        "        return EmailTemplateManager::applyFromNotification(\$this, \$notifiable, \$message);"

    # MailTested
    _addon_insert_after "app/Notifications/MailTested.php" "$use_target" "$use_import"
    _addon_replace "app/Notifications/MailTested.php" \
        "public function toMail(): MailMessage" \
        "public function toMail(mixed \$notifiable = null): MailMessage"
    _addon_replace "app/Notifications/MailTested.php" \
        "        return (new MailMessage())" \
        "        \$message = (new MailMessage())"
    _addon_insert_after "app/Notifications/MailTested.php" \
        "->line('This is a test of the Pterodactyl mail system. You\\'re good to go!');" \
        "        return EmailTemplateManager::applyFromNotification(\$this, \$notifiable, \$message);"

    # Hapus auto-created route file (EmailUtils sudah punya ServiceProvider + routes/emailutils.php)
    rm -f "$PANEL_DIR/routes/addons/admin/emailutils.php" 2>/dev/null || true
}

_addon_handle_automatic_phpmyadmin() {
    _addon_add_route_admin 'automatic_phpmyadmin' '
Route::group(["prefix" => "automatic-phpmyadmin"], function () {
    Route::get("/", [Admin\AutomaticPhpMyAdminController::class, "index"])->name("admin.automatic-phpmyadmin");
    Route::get("/new", [Admin\AutomaticPhpMyAdminController::class, "create"])->name("admin.automatic-phpmyadmin.new");
    Route::get("/view/{automaticphpmyadmin:id}", [Admin\AutomaticPhpMyAdminController::class, "view"])->name("admin.automatic-phpmyadmin.view");
    Route::post("/new", [Admin\AutomaticPhpMyAdminController::class, "store"]);
    Route::patch("/view/{automaticphpmyadmin:id}", [Admin\AutomaticPhpMyAdminController::class, "update"]);
    Route::delete("/delete/{automaticphpmyadmin:id}", [Admin\AutomaticPhpMyAdminController::class, "destroy"])->name("admin.automatic-phpmyadmin.delete");
});
'
    _addon_add_admin_nav '
                        <li class="{{ ! starts_with(Route::currentRouteName(), "admin.automatic-phpmyadmin") ?: "active" }}">
                            <a href="{{ route("admin.automatic-phpmyadmin") }}">
                                <i class="fa fa-database"></i> <span>Automatic phpMyAdmin</span>
                            </a>
                        </li>
' "admin.databases"
}

_addon_handle_smart_file_search() {
    _addon_add_route_api '
Route::post("/{server}/files/search/smart", [Client\Servers\FileController::class, "smartSearch"]);
' 'smart_file_search'
}

_addon_handle_ipblur() {
    # Replace text in ServerDetailsBlock.tsx
    local file1="resources/scripts/components/server/ServerDetailsBlock.tsx"
    local fpath1="$(_addon_panel_path "$file1")"
    if [[ -f "$fpath1" ]]; then
        _addon_replace "$file1" \
            "<StatBlock icon={faWifi} title={'Address'} copyOnClick={allocation}>"$'\n'"    {allocation}"$'\n'"</StatBlock>" \
            "<StatBlock icon={faWifi} title={'Address'} copyOnClick={allocation}>"$'\n'"    <span className=\"blur-sm hover:blur-none transition duration-300\">{allocation}</span>"$'\n'"</StatBlock>"
    fi
    # Replace text in ServerRow.tsx
    local file2="resources/scripts/components/dashboard/ServerRow.tsx"
    local fpath2="$(_addon_panel_path "$file2")"
    if [[ -f "$fpath2" ]]; then
        local old_block
        old_block=$(cat <<'BLOCK1'
                    {allocation.alias || ip(allocation.ip)}:{allocation.port}
BLOCK1
)
        local new_block
        new_block=$(cat <<'BLOCK2'
                    <span className="blur-sm hover:blur-none transition duration-300">
                        {allocation.alias || ip(allocation.ip)}:{allocation.port}
                    </span>
BLOCK2
)
        _addon_replace "$file2" "$old_block" "$new_block"
    fi
    _addon_yarn_build
}

_addon_handle_pterodacards() {
    # Replace Font Awesome CDN link
    local file="resources/views/admin/locations/index.blade.php"
    local fpath="$(_addon_panel_path "$file")"
    if [[ -f "$fpath" ]]; then
        _addon_replace "$file" \
            '<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/4.7.0/css/font-awesome.min.css">' \
            '<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.0/css/all.min.css">'$'\n''<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.7.2/css/brands.min.css" integrity="sha384-<hash>" crossorigin="anonymous">'
    fi
}

_addon_handle_code_linter() {
    # Install yarn packages for linter
    echo -e "    $(_addon_color 36 "  Installing linter packages...")"
    cd "$PANEL_DIR"
    yarn add htmlhint js-yaml jshint jsonlint-mod 2>/dev/null || true
    cd "$SCRIPT_DIR" 2>/dev/null || true
    _addon_yarn_build
}

_addon_handle_minecraft_mod_manager() {
    _addon_add_route_api '
Route::resource("minecraft-software", Client\Servers\MinecraftSoftwareController::class);
Route::resource("minecraft-mods", Client\Servers\MinecraftModController::class);
Route::get("minecraft-mods/versions", [Client\Servers\MinecraftModController::class, "versions"]);
Route::post("minecraft-mods/install", [Client\Servers\MinecraftModController::class, "install"]);
Route::get("minecraft-mods/installed", [Client\Servers\MinecraftModController::class, "installed"]);
' 'minecraft_mod_manager'
    # Add CF API key to .env
    if ! grep -q "CURSEFORGE_API_KEY" "$PANEL_DIR/.env" 2>/dev/null; then
        echo "CURSEFORGE_API_KEY=" >> "$PANEL_DIR/.env"
        echo -e "    $(_addon_color 33 "  ~ .env: CURSEFORGE_API_KEY added (isi manual)")"
    fi
    _addon_yarn_build
}

_addon_handle_minecraft_world_manager() {
    _addon_add_route_api '
Route::resource("minecraft-worlds", Client\Servers\MinecraftWorldController::class);
Route::post("minecraft-worlds/make-default", [Client\Servers\MinecraftWorldController::class, "makeDefault"]);
Route::get("minecraft-worlds/maps", [Client\Servers\MinecraftWorldController::class, "maps"]);
Route::post("minecraft-worlds/maps/install", [Client\Servers\MinecraftWorldController::class, "installMap"]);
' 'minecraft_world_manager'
    if ! grep -q "CURSEFORGE_API_KEY" "$PANEL_DIR/.env" 2>/dev/null; then
        echo "CURSEFORGE_API_KEY=" >> "$PANEL_DIR/.env"
        echo -e "    $(_addon_color 33 "  ~ .env: CURSEFORGE_API_KEY added (isi manual)")"
    fi
    _addon_yarn_build
}

_addon_handle_whmcs_sso() {
    _addon_composer_require "laravel/socialite" || true
    if ! grep -q "WHMCS_URL" "$PANEL_DIR/.env" 2>/dev/null; then
        cat >> "$PANEL_DIR/.env" <<'EOF'
WHMCS_URL=
WHMCS_CLIENT_ID=
WHMCS_CLIENT_SECRET=
EOF
        echo -e "    $(_addon_color 33 "  ~ .env: WHMCS vars added (isi manual)")"
    fi
}

_addon_handle_discord_auth() {
    echo -e "    $(_addon_color 36 "  Discord Auth: hanya file copy, no specific patches needed")"
}

_addon_handle_userimage() {
    echo -e "    $(_addon_color 36 "  UserImage: hanya file copy, no specific patches needed")"
}

_addon_handle_firewall() {
    # Add route to api-remote.php (panel-file copy handles the rest)
    _addon_add_route_remote '
    Route::post("/rules", [Remote\Servers\FirewallController::class, "getRules"]);
' 'firewall'
    # Add firewall permission
    local perm_file="$PANEL_DIR/app/Models/Permission.php"
    if [[ -f "$perm_file" ]] && ! grep -q "'firewall'" "$perm_file" 2>/dev/null; then
        sed -i "/'websocket' => \[/i\        'firewall' => [\n            'description' => 'Manage server firewall.',\n            'keys' => [\n                'manage' => 'View, create and remove rules.',\n            ],\n        ],\n" "$perm_file" 2>/dev/null || true
        echo -e "    $(_addon_color 32 "  + added firewall permission")"
    fi
}

_addon_handle_txadmin() {
    # Files already copied via PanelFiles/panelfiles
    # Need to edit SettingsContainer to add TxServerBox
    local file="resources/scripts/components/server/settings/SettingsContainer.tsx"
    local fpath="$(_addon_panel_path "$file")"
    if [[ -f "$fpath" ]]; then
        _addon_add_use "$file" "import TxServerBox from '@/components/server/settings/TxServerBox';"
        echo -e "    $(_addon_color 33 "  ⚠️  TxAdmin: perlu configure egg ID di SettingsContainer")"
    fi
    _addon_yarn_build
}

_addon_yarn_build() {
    if command -v yarn &>/dev/null && [[ -f "$PANEL_DIR/package.json" ]]; then
        echo -e "    $(_addon_color 36 "  Membangun frontend...")"
        cd "$PANEL_DIR"
        export NODE_OPTIONS=--openssl-legacy-provider
        yarn install --frozen-lockfile 2>/dev/null || yarn install 2>/dev/null || true
        yarn build:production 2>/dev/null || yarn run build 2>/dev/null || true
        cd "$SCRIPT_DIR" 2>/dev/null || true
    fi
}

# =========================================================
# MAIN INSTALL FUNCTION
# =========================================================

_addon_install_single() {
    local addon="$1"
    local zipfile="$ADDON_DIR/$addon.zip"
    _ADDON_ROUTE_SLUGS=""

    [[ -f "$zipfile" ]] || { fail "File $zipfile tidak ditemukan"; return 1; }
    if ! unzip -tq "$zipfile" >/dev/null 2>&1; then
        fail "Zip file korup atau tidak valid: $zipfile"
        log_msg "Addon zip corrupt: $addon"
        return 1
    fi
    _addon_is_installed "$addon" && {
        echo -e "  $(_addon_color 33 "Addon '$addon' sudah terinstall. Install ulang?")"
        confirm_action "Lanjutkan?" || return
    }

    # Version compatibility check
    _addon_detect_panel_version
    echo
    echo -e "  $(_addon_color 36 "Panel version detected: v$PANEL_VERSION")"
    _addon_check_compatibility "$addon"
    echo

    mkdir -p "$ADDON_MARKER_DIR"

    local tmpdir
    tmpdir=$(mktemp -d)
    echo -e "  $(_addon_color 36 'Mengekstrak...')"
    if ! unzip -q "$zipfile" -d "$tmpdir" 2>/dev/null; then
        rm -rf "$tmpdir"
        fail "Gagal extract zip (mungkin korup). Coba download ulang addon."
        return 1
    fi

    local topdir
    topdir=$(find "$tmpdir" -mindepth 1 -maxdepth 1 -type d | head -1)

    if [[ -z "$topdir" ]]; then
        rm -rf "$tmpdir"
        fail "Struktur zip tidak valid"
        return 1
    fi

    local has_panel_files=false
    local has_manual_edit=false
    local has_migration=false
    local has_frontend=false

    # Detect structure (check both topdir and zip root for multi-directory zips)
    for _basedir in "$topdir" "$tmpdir"; do
        if [[ -d "$_basedir/PanelFiles" ]] || [[ -d "$_basedir/pterodactyl" ]] || [[ -d "$_basedir/upload" ]] || [[ -d "$_basedir/PANEL" ]] || [[ -d "$_basedir/panelfiles" ]]; then
            has_panel_files=true
        fi
        if [[ -d "$_basedir/app" ]] || [[ -d "$_basedir/resources" ]] || [[ -d "$_basedir/database" ]]; then
            has_panel_files=true
        fi
        if [[ -d "$_basedir/config" ]]; then
            has_panel_files=true
        fi
    done
    # Fallback: check subdirectories for app/resources/database
    if ! $has_panel_files; then
        find "$topdir" -maxdepth 3 -type d \( -name "app" -o -name "resources" -o -name "database" -o -name "config" \) 2>/dev/null | grep -q . && has_panel_files=true
        find "$tmpdir" -maxdepth 3 -type d \( -name "app" -o -name "resources" -o -name "database" -o -name "config" \) 2>/dev/null | grep -q . && has_panel_files=true
    fi

    # Copy panel files
    if $has_panel_files; then
        local copied=0
        local copy_dir
        for copy_dir in "PanelFiles" "pterodactyl" "upload" "PANEL" "panelfiles"; do
            local src=""
            [[ -d "$topdir/$copy_dir" ]] && src="$topdir/$copy_dir"
            [[ -z "$src" && -d "$tmpdir/$copy_dir" ]] && src="$tmpdir/$copy_dir"
            if [[ -n "$src" ]]; then
                local file_count
                file_count=$(find "$src" -type f 2>/dev/null | wc -l)
                cp -r "$src/"* "$PANEL_DIR/" 2>/dev/null || true
                copied=$((copied + file_count))
                echo -e "    $(_addon_color 32 "  + copied $file_count files from $copy_dir/")"
            fi
        done
        for _sub in app database resources config vendor images; do
            local src=""
            [[ -d "$topdir/$_sub" ]] && src="$topdir/$_sub"
            [[ -z "$src" && -d "$tmpdir/$_sub" ]] && src="$tmpdir/$_sub"
            if [[ -n "$src" ]]; then
                local fc
                fc=$(find "$src" -type f 2>/dev/null | wc -l)
                if [[ "$_sub" == "images" ]]; then
                    mkdir -p "$PANEL_DIR/public/images" 2>/dev/null || true
                    cp -r "$src"/* "$PANEL_DIR/public/images/" 2>/dev/null || true
                else
                    cp -r "$src"/* "$PANEL_DIR/$_sub/" 2>/dev/null || true
                fi
                copied=$((copied + fc))
                echo -e "    $(_addon_color 32 "  + copied $fc files from $_sub/")"
            fi
        done

        # Fallback: find nested app/resources/database/config dirs not at top level
        local handled_dirs=""
        while IFS= read -r nested_dir; do
            [[ -z "$nested_dir" ]] && continue
            local dirname
            dirname=$(basename "$nested_dir")
            # Skip if already handled at topdir level
            [[ -d "$topdir/$dirname" ]] && continue
            [[ -d "$tmpdir/$dirname" ]] && continue
            # Skip if already handled this dirname
            echo "$handled_dirs" | grep -q ":$dirname:" && continue
            handled_dirs="$handled_dirs:$dirname:"
            local target_dir="$PANEL_DIR/$dirname"
            mkdir -p "$target_dir" 2>/dev/null || true
            local fc
            fc=$(find "$nested_dir" -type f 2>/dev/null | wc -l)
            cp -r "$nested_dir/"* "$target_dir/" 2>/dev/null || true
            copied=$((copied + fc))
            echo -e "    $(_addon_color 33 "  ~ copied $fc files from .../$dirname (nested)")"
        done < <(find "$topdir" "$tmpdir" -mindepth 2 -maxdepth 4 -type d \( -name "app" -o -name "resources" -o -name "database" -o -name "config" -o -name "routes" \) 2>/dev/null)

        echo -e "    $(_addon_color 36 "  Total $copied files copied")"

        chown -R www-data:www-data "$PANEL_DIR/" 2>/dev/null || true
    fi

    # ---- AUTO-DISCOVER SERVICE PROVIDERS ----
    local registered_providers=0
    local config_file="$PANEL_DIR/config/app.php"
    while IFS= read -r sp_file; do
        [[ -z "$sp_file" ]] && continue
        local rel_path
        rel_path="${sp_file#$topdir/}"
        # Only consider providers copied into the panel
        local panel_sp="$PANEL_DIR/${rel_path#PanelFiles/}"
        panel_sp="${panel_sp#pterodactyl/}"
        panel_sp="${panel_sp#upload/}"
        panel_sp="${panel_sp#PANEL/}"
        panel_sp="${panel_sp#panelfiles/}"
        if [[ -f "$panel_sp" ]]; then
            local namespace
            namespace=$(grep -oP '^namespace\s+\K[A-Za-z0-9_\\]+' "$panel_sp" 2>/dev/null | tr -d ';')
            local class_name
            class_name=$(basename "$panel_sp" .php)
            if [[ -n "$namespace" && -n "$class_name" ]]; then
                local fqcn="${namespace}\\${class_name}"
                # Escape backslashes for grep -F (fixed string)
                if grep -Fq "$fqcn" "$config_file" 2>/dev/null; then
                    echo -e "    $(_addon_color 33 "  ~ already registered: $fqcn")"
                else
                    local escaped
                    escaped="${fqcn//\\/\\\\}"
                    sed -i "/Pterodactyl\\\Providers\\\ViewComposerServiceProvider::class,/a\\        ${escaped}::class," "$config_file" 2>/dev/null || true
                    echo -e "    $(_addon_color 32 "  + auto-registered: $fqcn")"
                    registered_providers=$((registered_providers + 1))
                fi
            fi
        fi
    done < <(find "$topdir" "$tmpdir" -maxdepth 5 -name '*ServiceProvider.php' 2>/dev/null)

    # Check for migrations and frontend
    if find "$topdir" "$tmpdir" -path "*/database/migrations/*.php" 2>/dev/null | grep -q .; then
        has_migration=true
    fi
    if find "$topdir" "$tmpdir" -path "*/resources/scripts/*.tsx" -o -path "*/resources/scripts/*.ts" 2>/dev/null | grep -q .; then
        has_frontend=true
    fi

    # ---- APPLY SMART PATCHES ----
    # First try specific handler
    echo
    echo -e "  $(_addon_color 36 'Menerapkan patch otomatis...')"

    if ! _addon_run_handler "$addon" "$topdir"; then
        # Try generic instruction parser
        _addon_parse_instructions "$tmpdir" "$topdir"
    fi

    # ---- RUN MIGRATIONS ----
    if [[ -d "$PANEL_DIR" ]] && [[ -f "$PANEL_DIR/artisan" ]]; then
        cd "$PANEL_DIR"
        if $has_migration; then
            echo
            echo -e "  $(_addon_color 36 'Menjalankan php artisan migrate...')"
            sudo -u www-data php artisan migrate --force 2>/dev/null && \
                echo -e "  $(_addon_color 32 '  + Migrasi sukses')" || \
                echo -e "  $(_addon_color 33 '  ~ Migrasi selesai (ada catatan)')"
        fi
        echo
        echo -e "  $(_addon_color 36 'Refresh autoloader...')"
        COMPOSER_ALLOW_SUPERUSER=1 composer dump-autoload 2>/dev/null || true
        echo
        echo -e "  $(_addon_color 36 'Clear panel cache...')"
        sudo -u www-data php artisan optimize:clear 2>/dev/null || sudo -u www-data php artisan view:clear 2>/dev/null || true
        echo -e "  $(_addon_color 36 'Optimasi panel...')"
        sudo -u www-data php artisan optimize 2>/dev/null || true
        cd "$SCRIPT_DIR" 2>/dev/null || true
    fi

    # ---- BUILD FRONTEND ----
    if $has_frontend; then
        echo
        echo -e "  $(_addon_color 36 'Membangun frontend assets...')"
        if command -v yarn &>/dev/null && [[ -f "$PANEL_DIR/package.json" ]]; then
            cd "$PANEL_DIR"
            export NODE_OPTIONS=--openssl-legacy-provider
            yarn install --frozen-lockfile 2>/dev/null || yarn install 2>/dev/null || true
            yarn build:production 2>/dev/null || yarn run build 2>/dev/null || \
                echo -e "  $(_addon_color 33 '  ~ Build frontend skipped (manual)')"
            cd "$SCRIPT_DIR" 2>/dev/null || true
        else
            echo -e "  $(_addon_color 33 '  ~ Yarn tidak tersedia')"
        fi
    fi

    # ---- RUN AINX/INSTALL SCRIPTS ----
    local ainx_file
    ainx_file=$(find "$tmpdir" -maxdepth 2 -name '*.ainx' 2>/dev/null | head -1)

    local install_sh
    install_sh=$(find "$tmpdir" -maxdepth 2 -name 'install-*.sh' 2>/dev/null | head -1)
    if [[ -n "$install_sh" ]]; then
        echo -e "  $(_addon_color 36 'Menjalankan script install...')"
        bash "$install_sh" 2>/dev/null || true
    fi

    if [[ -n "$ainx_file" ]]; then
        echo -e "  $(_addon_color 36 'Menjalankan ainx install...')"
        npm install -g ainx 2>/dev/null || true
        cd "$PANEL_DIR"
        ainx install "$ainx_file" --force 2>/dev/null || ainx install "$ainx_file" 2>/dev/null || true
        cd "$SCRIPT_DIR" 2>/dev/null || true
        echo -e "  $(_addon_color 32 "  + ainx patch applied")"
    fi

    # ---- CHECK REMAINING MANUAL STEPS ----
    local has_unpatched=false
    local inst_file
    inst_file=$(find "$tmpdir" -maxdepth 3 -name "manual_install.txt" 2>/dev/null | head -1)
    [[ -z "$inst_file" ]] && inst_file=$(find "$tmpdir" -maxdepth 3 -name "PanelEdit.txt" 2>/dev/null | head -1)
    [[ -z "$inst_file" ]] && inst_file=$(find "$tmpdir" -maxdepth 3 -name "paneledit.txt" 2>/dev/null | head -1)
    local inst_html
    inst_html=$(find "$tmpdir" -maxdepth 3 -name "manual_install.html" 2>/dev/null | head -1)

    if [[ -f "$inst_file" ]]; then
        local raw_content
        raw_content=$(cat "$inst_file")
        # Check for remaining patterns that need manual intervention
        if echo "$raw_content" | grep -qiE "(edit|change|modify|open|nano|vim|replace|search for)" ; then
            has_unpatched=true
        fi
    fi

    if [[ -f "$inst_html" ]] || $has_unpatched; then
        has_manual_edit=true
    fi

    rm -rf "$tmpdir"

    # ---- MARK INSTALLED ----
    local installed_at
    installed_at=$(date '+%Y-%m-%d %H:%M:%S')
    cat > "$ADDON_MARKER_DIR/$addon.installed" <<EOF
ADDON_NAME="$addon"
INSTALLED_AT="$installed_at"
HAS_MANUAL_EDIT=$has_manual_edit
HAS_FRONTEND=$has_frontend
HAS_PANEL_FILES=$has_panel_files
HAS_MIGRATION=$has_migration
ROUTE_SLUGS="$_ADDON_ROUTE_SLUGS"
EOF

    echo
    echo -e "  $(_addon_color 32 "✓ Addon '$addon' berhasil diinstall!")"

    if $has_manual_edit; then
        echo
        echo -e "  $(_addon_color 33 '⚠️  BEBERAPA EDIT MANUAL MASIH DIPERLUKAN!')"
        echo -e "  $(_addon_color 33 'Lihat petunjuk lengkap di menu 3 (Lihat Petunjuk Install).')"
        echo
    fi

    notify_detail "Addon Installed" "Addon '$addon' berhasil diinstall di panel."
    log_msg "Addon '$addon' installed"
    systemctl restart pteroq 2>/dev/null || true

    pause
}

# =========================================================
# UNINSTALL ADDON
# =========================================================

_addon_uninstall_menu() {
    require_root || return 1
    mkdir -p "$ADDON_MARKER_DIR"

    local installed=()
    for f in "$ADDON_MARKER_DIR"/*.installed; do
        [[ -f "$f" ]] || continue
        . "$f"
        installed+=("$ADDON_NAME")
    done

    if [[ ${#installed[@]} -eq 0 ]]; then
        echo -e "  $(_addon_color 33 'Tidak ada addon terinstall.')"
        pause
        return
    fi

    _addon_header
    echo -e "  $(_addon_color 33 'Pilih addon yang mau diuninstall:')"
    echo
    local i=0
    for a in "${installed[@]}"; do
        i=$((i+1))
        echo -e "  $(_addon_color 32 "$i") $a"
    done
    echo -e "  $(_addon_color 31 '0')  Kembali"
    echo
    read -r -p "  Pilih [0-$i]: " sel
    [[ "$sel" == "0" ]] && return
    [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= i )) || return

    local addon="${installed[$((sel-1))]}"
    echo
    echo -e "  $(_addon_color 31 "Uninstall '$addon'?")"
    confirm_action "Lanjutkan?" || return
    _addon_uninstall_single "$addon"
}

_addon_uninstall_single() {
    local addon="$1"
    local zipfile="$ADDON_DIR/$addon.zip"
    [[ ! -f "$zipfile" ]] && {
        # No zip file, just remove marker
        rm -f "$ADDON_MARKER_DIR/$addon.installed"
        echo -e "  $(_addon_color 33 "  Zip tidak ditemukan, hanya menghapus track")"
        echo -e "  $(_addon_color 32 "✓ Addon '$addon' diuninstall (tanpa zip)")"
        pause
        return
    }

    local tmpdir
    tmpdir=$(mktemp -d)
    echo -e "  $(_addon_color 36 'Menganalisis file addon...')"
    unzip -q "$zipfile" -d "$tmpdir" 2>/dev/null

    local topdir
    topdir=$(find "$tmpdir" -mindepth 1 -maxdepth 1 -type d | head -1)
    [[ -z "$topdir" ]] && { rm -rf "$tmpdir"; rm -f "$ADDON_MARKER_DIR/$addon.installed"; echo -e "  $(_addon_color 32 "✓ Track dihapus")"; pause; return; }

    local removed_files=0

    # Remove ServiceProvider registration from config/app.php FIRST (before file removal)
    local config_file="$PANEL_DIR/config/app.php"
    while IFS= read -r sp_file; do
        [[ -z "$sp_file" ]] && continue
        local sp_base="${sp_file#$topdir/}"
        sp_base="${sp_base#PanelFiles/}"
        sp_base="${sp_base#pterodactyl/}"
        sp_base="${sp_base#upload/}"
        sp_base="${sp_base#PANEL/}"
        sp_base="${sp_base#panelfiles/}"
        local panel_sp="$PANEL_DIR/$sp_base"
        if [[ -f "$panel_sp" ]]; then
            local namespace class_name
            namespace=$(grep -oP '^namespace\s+\K[A-Za-z0-9_\\]+' "$panel_sp" 2>/dev/null | tr -d ';')
            class_name=$(basename "$panel_sp" .php)
            if [[ -n "$namespace" && -n "$class_name" ]]; then
                local fqcn="${namespace}\\${class_name}"
                local escaped_fqcn
                escaped_fqcn=$(printf '%s' "$fqcn" | sed -e 's|/|\\/|g' -e 's|\\|\\\\|g')
                sed -i "/$escaped_fqcn/d" "$config_file" 2>/dev/null || true
                printf "    %s  + removed provider: %s\n" "$(_addon_color 32 '')" "$fqcn"
            fi
        fi
    done < <(find "$topdir" -maxdepth 5 -name '*ServiceProvider.php' 2>/dev/null)

    # Remove known nav items + revert notification files (before file removal)
    local lower
    lower=$(echo "$addon" | tr '[:upper:]' '[:lower:]')
    case "$lower" in
        *"email"*"util"*)
            sed -i '/email-utils/,/<\/li>/d' "$PANEL_DIR/resources/views/layouts/admin.blade.php" 2>/dev/null || true
            echo -e "    $(_addon_color 32 "  + removed nav: Email Utils")"
            for nf in AccountCreated SendPasswordReset AddedToServer RemovedFromServer ServerInstalled MailTested; do
                local nfile="$PANEL_DIR/app/Notifications/$nf.php"
                if [[ -f "$nfile" ]]; then
                    sed -i '/use Pterodactyl\\Services\\EmailUtils\\EmailTemplateManager;/d' "$nfile" 2>/dev/null || true
                    sed -i 's/public function toMail(mixed $notifiable = null): MailMessage/public function toMail(): MailMessage/' "$nfile" 2>/dev/null || true
                    sed -i '/return EmailTemplateManager::applyFromNotification/d' "$nfile" 2>/dev/null || true
                fi
            done
            echo -e "    $(_addon_color 32 "  + reverted notification files")"
            ;;
        *"activitypurge"*)
            sed -i '/activitypurges/,/<\/li>/d' "$PANEL_DIR/resources/views/layouts/admin.blade.php" 2>/dev/null || true
            echo -e "    $(_addon_color 32 "  + removed nav: Activity Purges")"
            ;;
        *"phpmyadmin"*)
            sed -i '/automatic-phpmyadmin/,/<\/li>/d' "$PANEL_DIR/resources/views/layouts/admin.blade.php" 2>/dev/null || true
            echo -e "    $(_addon_color 32 "  + removed nav: phpMyAdmin")"
            ;;
        *"automatic"*"backup"*)
            sed -i '/Auto Backup/,/<\/li>/d' "$PANEL_DIR/resources/views/layouts/admin.blade.php" 2>/dev/null || true
            sed -i '/admin\.backup/,/<\/li>/d' "$PANEL_DIR/resources/views/layouts/admin.blade.php" 2>/dev/null || true
            local _kfile="$PANEL_DIR/app/Console/Kernel.php"
            sed -i '/AutomaticBackupCommand/d' "$_kfile" 2>/dev/null || true
            sed -i '/AutomaticDatabaseBackupCommand/d' "$_kfile" 2>/dev/null || true
            sed -i '/backup::auto::run/d' "$_kfile" 2>/dev/null || true
            sed -i '/backup::database::auto::run/d' "$_kfile" 2>/dev/null || true
            sed -i '/^$/N;/^\n$/D' "$_kfile" 2>/dev/null || true
            echo -e "    $(_addon_color 32 "  + reverted nav & scheduler: Auto Backup")"
            ;;
        *"addon off"*|*"ram"*|*"limit"*)
            sed -i '/Ram Limit\|ram\.limit/,/<\/li>/d' "$PANEL_DIR/resources/views/layouts/admin.blade.php" 2>/dev/null || true
            local _kfile="$PANEL_DIR/app/Console/Kernel.php"
            sed -i '/RamLimit::class/d' "$_kfile" 2>/dev/null || true
            sed -i '/^$/N;/^\n$/D' "$_kfile" 2>/dev/null || true
            echo -e "    $(_addon_color 32 "  + reverted nav & scheduler: Ram Limit")"
            ;;
        *"player"*"counter"*)
            sed -i '/Player Counter\|player\.counter/,/<\/li>/d' "$PANEL_DIR/resources/views/layouts/admin.blade.php" 2>/dev/null || true
            echo -e "    $(_addon_color 32 "  + removed nav: Player Counter")"
            ;;
        *"staff"*"system"*)
            sed -i '/Staff System\|staff\.requests/,/<\/li>/d' "$PANEL_DIR/resources/views/layouts/admin.blade.php" 2>/dev/null || true
            echo -e "    $(_addon_color 32 "  + removed nav: Staff System")"
            ;;
        *"ticket"*)
            sed -i '/Tickets\|admin\.tickets/,/<\/li>/d' "$PANEL_DIR/resources/views/layouts/admin.blade.php" 2>/dev/null || true
            echo -e "    $(_addon_color 32 "  + removed nav: Tickets")"
            ;;
        *"discord"*"notif"*)
            sed -i '/Discord\|admin\.myplugins\.discord/,/<\/li>/d' "$PANEL_DIR/resources/views/layouts/admin.blade.php" 2>/dev/null || true
            echo -e "    $(_addon_color 32 "  + removed nav: Discord Notifications")"
            ;;
        *"sftp"*"alias"*)
            # IPBlur juga make _addon_replace — revert cukup susah, tandai aja
            echo -e "    $(_addon_color 33 "  ~ SFTP Alias: perlu dicek manual di NodeViewController.php")"
            ;;
        *"billing"*|*"shop"*)
            sed -i '/Billing\|admin\.shop/,/<\/li>/d' "$PANEL_DIR/resources/views/layouts/admin.blade.php" 2>/dev/null || true
            echo -e "    $(_addon_color 32 "  + removed nav: Billing/Shop")"
            ;;
        *"node"*"maintenance"*)
            local _tf="$PANEL_DIR/app/Transformers/Api/Client/ServerTransformer.php"
            sed -i "/'is_maintenance' =>.*maintenance_mode/d" "$_tf" 2>/dev/null || true
            echo -e "    $(_addon_color 32 "  + reverted: Node Maintenance transformer")"
            ;;
        *"minecraft"*"jar"*)
            # Only adds API routes, no nav/scheduler
            echo -e "    $(_addon_color 33 "  ~ Minecraft Jar Checker: hanya rute API")"
            ;;
        *"smart"*"file"*"search"*)
            # Only adds API routes
            echo -e "    $(_addon_color 33 "  ~ Smart File Search: hanya rute API")"
            ;;
        *"code"*"linter"*)
            echo -e "    $(_addon_color 33 "  ~ Code Linter: yarn packages, tidak ada file panel")"
            ;;
        *"minecraft"*"mod"*|*"minecraft"*"world"*)
            echo -e "    $(_addon_color 33 "  ~ Minecraft Mod/World Manager: hanya frontend")"
            ;;
        *"separate"*"kill"*)
            # Hanya frontend, dihapus lewat file copy reversal
            echo -e "    $(_addon_color 33 "  ~ Separate Kill Button: hanya frontend")"
            ;;
        *"pterodactyl"*"region"*)
            echo -e "    $(_addon_color 33 "  ~ Pterodactyl Region: installer eksternal")"
            ;;
        *"ip"*"blur"*|*"ipblur"*)
            echo -e "    $(_addon_color 33 "  ~ IPBlur: patch file frontend, perlu rebuild")"
            ;;
        *"pterodacard"*)
            echo -e "    $(_addon_color 33 "  ~ Pterodacards: patch file blade, perlu dicek")"
            ;;
        *"whmcs"*)
            echo -e "    $(_addon_color 33 "  ~ WHMCS SSO: perlu dicek manual")"
            ;;
        *"txadmin"*)
            echo -e "    $(_addon_color 33 "  ~ TXAdmin: perlu dicek manual")"
            ;;
        *"firewall"*)
            echo -e "    $(_addon_color 33 "  ~ Firewall: perlu dicek manual")"
            ;;
        *"discord"*"auth"*)
            echo -e "    $(_addon_color 33 "  ~ Discord Auth: perlu dicek manual")"
            ;;
        *"userimage"*)
            echo -e "    $(_addon_color 33 "  ~ UserImage: perlu dicek manual")"
            ;;
    esac

    # Generic nav cleanup: remove nav items referencing route slugs from marker
    local _gen_marker="$ADDON_MARKER_DIR/$addon.installed"
    if [[ -f "$_gen_marker" ]]; then
        local _gen_slugs
        _gen_slugs=$(grep '^ROUTE_SLUGS=' "$_gen_marker" 2>/dev/null | cut -d= -f2- | tr -d '"')
        if [[ -n "$_gen_slugs" ]]; then
            for _gs in $_gen_slugs; do
                local _gslug="${_gs#*:}"
                sed -i "/$_gslug/,/<\/li>/d" "$PANEL_DIR/resources/views/layouts/admin.blade.php" 2>/dev/null || true
            done
        fi
    fi

    # Remove copied panel files
    for copy_dir in "PanelFiles" "pterodactyl" "upload" "PANEL" "panelfiles"; do
        if [[ -d "$topdir/$copy_dir" ]]; then
            while IFS= read -r src_file; do
                [[ -z "$src_file" ]] && continue
                local rel="${src_file#$topdir/$copy_dir/}"
                local target="$PANEL_DIR/$rel"
                if [[ -f "$target" ]]; then
                    rm -f "$target" 2>/dev/null || true
                    removed_files=$((removed_files + 1))
                fi
            done < <(find "$topdir/$copy_dir" -type f 2>/dev/null)
        fi
    done

    # Remove files from app/, resources/, database/ directories
    for subdir in "app" "resources" "database" "config" "routes"; do
        if [[ -d "$topdir/$subdir" ]]; then
            while IFS= read -r src_file; do
                [[ -z "$src_file" ]] && continue
                local rel="${src_file#$topdir/}"
                local target="$PANEL_DIR/$rel"
                if [[ -f "$target" ]]; then
                    rm -f "$target" 2>/dev/null || true
                    removed_files=$((removed_files + 1))
                fi
            done < <(find "$topdir/$subdir" -type f 2>/dev/null)
        fi
    done
    # Fallback: find nested app/resources/database/config dirs not at top level
    local handled_removedirs=""
    while IFS= read -r nested_dir; do
        [[ -z "$nested_dir" ]] && continue
        local dirname
        dirname=$(basename "$nested_dir")
        [[ -d "$topdir/$dirname" ]] && continue
        echo "$handled_removedirs" | grep -q ":$dirname:" && continue
        handled_removedirs="$handled_removedirs:$dirname:"
        while IFS= read -r src_file; do
            [[ -z "$src_file" ]] && continue
            local rel="${src_file#*"$dirname/"}"
            local target="$PANEL_DIR/$dirname/$rel"
            if [[ -f "$target" ]]; then
                rm -f "$target" 2>/dev/null || true
                removed_files=$((removed_files + 1))
            fi
        done < <(find "$nested_dir" -type f 2>/dev/null)
    done < <(find "$topdir" -mindepth 2 -maxdepth 4 -type d \( -name "app" -o -name "resources" -o -name "database" -o -name "config" -o -name "routes" \) 2>/dev/null)

    # Remove empty directories left behind
    find "$PANEL_DIR/app" "$PANEL_DIR/resources" "$PANEL_DIR/database" "$PANEL_DIR/config" "$PANEL_DIR/routes" -type d -empty -delete 2>/dev/null || true

    echo -e "    $(_addon_color 32 "  + removed $removed_files files")"

    # Remove migration files copied from addon
    local mig_dir="$PANEL_DIR/database/migrations"
    while IFS= read -r src_file; do
        [[ -z "$src_file" ]] && continue
        local mig_name
        mig_name=$(basename "$src_file")
        local target="$mig_dir/$mig_name"
        [[ -f "$target" ]] && rm -f "$target" 2>/dev/null || true
    done < <(find "$topdir" -path "*/database/migrations/*.php" -type f 2>/dev/null)

    rm -rf "$tmpdir"

    # Remove addon-specific route files from routes/addons/
    local _route_cleaned=false
    local _marker_file="$ADDON_MARKER_DIR/$addon.installed"
    if [[ -f "$_marker_file" ]]; then
        local _route_slugs
        _route_slugs=$(grep '^ROUTE_SLUGS=' "$_marker_file" 2>/dev/null | cut -d= -f2- | tr -d '"')
        if [[ -n "$_route_slugs" ]]; then
            for _rs in $_route_slugs; do
                local _rdir="${_rs%%:*}"
                local _rslug="${_rs#*:}"
                rm -f "$PANEL_DIR/routes/addons/$_rdir/$_rslug.php" 2>/dev/null || true
                rmdir "$PANEL_DIR/routes/addons/$_rdir" 2>/dev/null || true
            done
            _route_cleaned=true
        fi
    fi
    # Fallback: compute slug from addon name
    if ! $_route_cleaned; then
        local slug
        slug=$(echo "$addon" | tr '[:upper:]' '[:lower:]' | tr -s ' _-' '_')
        for _rdir in admin api remote; do
            rm -f "$PANEL_DIR/routes/addons/$_rdir/$slug.php" 2>/dev/null || true
            rmdir "$PANEL_DIR/routes/addons/$_rdir" 2>/dev/null || true
        done
    fi
    rmdir "$PANEL_DIR/routes/addons" 2>/dev/null || true

    rm -f "$ADDON_MARKER_DIR/$addon.installed"

    # Hapus manual semua cache — optimize:clear bakal error kalo
    # provider yg filenya udah ilang masih tercache di services.php
    echo
    echo -e "  $(_addon_color 36 'Clear & regenerate cache...')"
    rm -f "$PANEL_DIR/bootstrap/cache/"*.php 2>/dev/null || true
    rm -rf "$PANEL_DIR/storage/framework/cache/data/"* 2>/dev/null || true
    rm -rf "$PANEL_DIR/storage/framework/views/"* 2>/dev/null || true
    cd "$PANEL_DIR"
    sudo -u www-data php artisan config:cache 2>/dev/null || true
    sudo -u www-data php artisan route:cache 2>/dev/null || true
    sudo -u www-data php artisan view:cache 2>/dev/null || true
    cd "$SCRIPT_DIR" 2>/dev/null || true

    echo
    echo -e "  $(_addon_color 32 "✓ Addon '$addon' berhasil diuninstall!")"
    echo -e "  $(_addon_color 33 "  ⚠️  File Blade/view yang dimodifikasi manual tidak dikembalikan")"
    systemctl restart pteroq 2>/dev/null || true
    pause
}

_addon_show_installed() {
    mkdir -p "$ADDON_MARKER_DIR"
    _addon_header
    echo -e "  $(_addon_color 33 'Addon Terinstall:')"
    echo
    local count=0
    for f in "$ADDON_MARKER_DIR"/*.installed; do
        [[ -f "$f" ]] || continue
        count=$((count+1))
        . "$f"
        echo -e "  $(_addon_color 32 "• $ADDON_NAME")"
        echo -e "    Installed: $INSTALLED_AT"
        echo -e "    Manual Edit: $([ "$HAS_MANUAL_EDIT" = "true" ] && echo -e "$(_addon_color 33 'Required')" || echo -e "$(_addon_color 32 'Auto')")"
        echo
    done

    [[ $count -eq 0 ]] && echo -e "  $(_addon_color 33 'Belum ada addon terinstall.')"
    echo
    pause
}

_addon_show_instructions() {
    require_root || return 1

    local addons=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && addons+=("$line")
    done < <(_addon_get_list)
    if [[ ${#addons[@]} -eq 0 ]]; then
        echo -e "  $(_addon_color 31 'Tidak ada addon')"
        pause
        return
    fi

    _addon_header
    echo -e "  $(_addon_color 33 'Pilih addon untuk lihat petunjuk install:')"
    echo
    local i=0
    for a in "${addons[@]}"; do
        i=$((i+1))
        echo -e "  $(_addon_color 32 "$i") $a"
    done
    echo -e "  $(_addon_color 31 '0')  Kembali"
    echo
    read -r -p "  Pilih [0-$i]: " sel
    [[ "$sel" == "0" ]] && return
    [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= i )) || return

    local chosen="${addons[$((sel-1))]}"
    local zipfile="$ADDON_DIR/$chosen.zip"
    local tmpdir
    tmpdir=$(mktemp -d)
    unzip -q "$zipfile" -d "$tmpdir"

    local topdir
    topdir=$(find "$tmpdir" -mindepth 1 -maxdepth 1 -type d | head -1)

    local found=false
    for fname in "manual_install.txt" "PanelEdit.txt" "paneledit.txt" "manual_install.md" "manual_install.html" "WingsEdit.txt" "wingsedit.txt"; do
        local fpath
        fpath=$(find "$tmpdir" -maxdepth 3 -name "$fname" 2>/dev/null | head -1)
        if [[ -n "$fpath" ]]; then
            found=true
            echo
            echo -e "$(_addon_color 36 '═══════════════════════════════════════════')"
            echo -e "  Petunjuk Install: $chosen ($fname)"
            echo -e "$(_addon_color 36 '═══════════════════════════════════════════')"
            echo
            if [[ "$fname" == *.html ]]; then
                echo -e "  $(_addon_color 33 '(HTML file - buka manual di browser)')"
                cp "$fpath" "/tmp/${chosen}_instructions.html"
                echo -e "  $(_addon_color 33 "  File: /tmp/${chosen}_instructions.html")"
            else
                cat "$fpath"
            fi
            echo
            break
        fi
    done

    if ! $found; then
        echo -e "  $(_addon_color 33 'Tidak ada file petunjuk install untuk addon ini.')"
    fi

    rm -rf "$tmpdir"
    pause
}

_addon_remove_track() {
    require_root || return 1
    mkdir -p "$ADDON_MARKER_DIR"

    local installed=()
    for f in "$ADDON_MARKER_DIR"/*.installed; do
        [[ -f "$f" ]] || continue
        . "$f"
        installed+=("$ADDON_NAME")
    done

    if [[ ${#installed[@]} -eq 0 ]]; then
        echo -e "  $(_addon_color 33 'Tidak ada track addon terinstall.')"
        pause
        return
    fi

    _addon_header
    echo -e "  $(_addon_color 33 'Pilih track yang mau dihapus:')"
    echo
    local i=0
    for a in "${installed[@]}"; do
        i=$((i+1))
        echo -e "  $(_addon_color 32 "$i") $a"
    done
    echo -e "  $(_addon_color 31 '0')  Kembali"
    echo
    read -r -p "  Pilih [0-$i]: " sel
    [[ "$sel" == "0" ]] && return
    [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= i )) || return

    local chosen="${installed[$((sel-1))]}"
    confirm_action "Hapus track install '$chosen'? (file addon TIDAK dihapus dari panel)" || return
    rm -f "$ADDON_MARKER_DIR/$chosen.installed"
    echo -e "  $(_addon_color 32 "Track '$chosen' dihapus")"
    pause
}

# ====================================================
# ADDON INFO - inspect zip before install
# ====================================================

_addon_show_info() {
    require_root || return 1
    local addons=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && addons+=("$line")
    done < <(_addon_get_list)
    if [[ ${#addons[@]} -eq 0 ]]; then
        echo -e "  $(_addon_color 31 'Tidak ada addon')"; pause; return
    fi

    _addon_header
    echo -e "  $(_addon_color 33 'Pilih addon untuk lihat info:')"
    local i=0
    for a in "${addons[@]}"; do i=$((i+1)); echo -e "  $(_addon_color 32 "$i") $a"; done
    echo -e "  $(_addon_color 31 '0')  Kembali"
    read -r -p "  Pilih [0-$i]: " sel
    [[ "$sel" == "0" ]] && return
    [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= i )) || { pause; return; }

    local chosen="${addons[$((sel-1))]}"
    local zipfile="$ADDON_DIR/$chosen.zip"
    _addon_header
    echo -e "  $(_addon_color 33 "Info: $chosen")"
    echo
    local size
    size=$(du -sh "$zipfile" 2>/dev/null | awk '{print $1}')
    echo -e "  Size       : ${CYAN}$size${NC}"
    local zip_status="OK"
    unzip -tq "$zipfile" >/dev/null 2>&1 || zip_status="CORRUPT"
    echo -e "  Integrity  : $([ "$zip_status" = "OK" ] && _addon_color 32 "$zip_status" || _addon_color 31 "$zip_status")"
    local zip_date
    zip_date=$(stat -c %y "$zipfile" 2>/dev/null | cut -d. -f1)
    echo -e "  Zip date   : ${zip_date:-?}"

    local tmpdir
    tmpdir=$(mktemp -d)
    if unzip -q "$zipfile" -d "$tmpdir" 2>/dev/null; then
        local topdir
        topdir=$(find "$tmpdir" -mindepth 1 -maxdepth 1 -type d | head -1)
        if [[ -n "$topdir" ]]; then
            local fc
            fc=$(find "$topdir" -type f 2>/dev/null | wc -l)
            echo -e "  Files      : ${CYAN}$fc${NC}"
            local has_pf=false has_fe=false has_mig=false has_ins=false
            for d in PanelFiles pterodactyl upload PANEL panelfiles app resources database config; do
                [[ -d "$topdir/$d" ]] && has_pf=true
            done
            find "$topdir" -path "*/resources/scripts/*" -name "*.ts*" 2>/dev/null | grep -q . && has_fe=true
            find "$topdir" -path "*/database/migrations/*.php" 2>/dev/null | grep -q . && has_mig=true
            for f in manual_install.txt PanelEdit.txt paneledit.txt manual_install.html; do
                find "$topdir" -maxdepth 3 -name "$f" 2>/dev/null | grep -q . && has_ins=true
            done
            echo -e "  Panel files: $([ "$has_pf" = true ] && _addon_color 32 "yes" || _addon_color 33 "no")"
            echo -e "  Frontend   : $([ "$has_fe" = true ] && _addon_color 32 "yes" || _addon_color 33 "no")"
            echo -e "  Migration  : $([ "$has_mig" = true ] && _addon_color 32 "yes" || _addon_color 33 "no")"
            echo -e "  Manual inst: $([ "$has_ins" = true ] && _addon_color 33 "yes" || _addon_color 32 "no")"
            local inst_file
            inst_file=$(find "$topdir" -maxdepth 3 \( -name "manual_install.txt" -o -name "PanelEdit.txt" -o -name "paneledit.txt" \) 2>/dev/null | head -1)
            if [[ -n "$inst_file" ]]; then
                echo
                echo -e "  $(_addon_color 36 '── Petunjuk (potongan pertama) ──')"
                head -20 "$inst_file" 2>/dev/null | sed 's/^/    /'
                local total_lines
                total_lines=$(wc -l < "$inst_file")
                [[ $total_lines -gt 20 ]] && echo -e "    $(_addon_color 33 "... ($((total_lines - 20)) baris lagi)")"
            fi
        fi
    else
        echo -e "  $(_addon_color 31 'Tidak bisa extract untuk inspect.')"
    fi
    rm -rf "$tmpdir"
    echo
    echo -e "  $(_addon_color 36 'Panel:')"
    _addon_detect_panel_version
    _addon_check_compatibility "$chosen"
    echo
    pause
}

# ====================================================
# SEARCH/FILTER addon list
# ====================================================

_addon_search_filter() {
    require_root || return 1
    local filter="${1:-}"
    if [[ -z "$filter" ]]; then
        read -r -p "  Filter (case-insensitive substring, kosongkan untuk semua): " filter
    fi
    local lower_filter
    lower_filter=$(echo "$filter" | tr '[:upper:]' '[:lower:]')

    local addons=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && addons+=("$line")
    done < <(_addon_get_list)
    [[ ${#addons[@]} -eq 0 ]] && { echo -e "  $(_addon_color 31 'Tidak ada addon')"; pause; return; }

    local filtered=()
    for a in "${addons[@]}"; do
        local low
        low=$(echo "$a" | tr '[:upper:]' '[:lower:]')
        if [[ -z "$lower_filter" ]] || echo "$low" | grep -qF -- "$lower_filter"; then
            filtered+=("$a")
        fi
    done

    _addon_header
    echo -e "  $(_addon_color 33 "Hasil filter: '$filter' → ${#filtered[@]} dari ${#addons[@]} addon")"
    echo
    if [[ ${#filtered[@]} -eq 0 ]]; then
        echo -e "  $(_addon_color 33 "Tidak ada addon yang cocok.")"
    else
        local i=0
        for a in "${filtered[@]}"; do
            i=$((i+1))
            local mark=" "
            _addon_is_installed "$a" && mark="✓"
            echo -e "  $(_addon_color 32 "$i")${mark}) $a"
        done
    fi
    echo
    pause
}

# ====================================================
# EXPORT/IMPORT addon state (untuk clone server)
# ====================================================

_addon_export_state() {
    require_root || return 1
    mkdir -p "$ADDON_MARKER_DIR"
    local out="${1:-/root/ptero-addons-export-$(date +%F_%H-%M-%S).json}"

    if [[ -f "$ADDON_STATE_FILE" && "$out" == "/root/ptero-addons-export-"* ]] && ! [[ "$1" =~ / ]]; then
        out="/root/ptero-addons-export-$(date +%F_%H-%M-%S).json"
    fi

    local json="{\n  \"exported_at\": \"$(date -Iseconds)\",\n  \"ptero_manager_version\": \"${SCRIPT_VERSION:-unknown}\",\n  \"panel_version\": \"${PANEL_VERSION:-unknown}\",\n  \"addons\": ["
    local first=1
    local count=0
    for f in "$ADDON_MARKER_DIR"/*.installed; do
        [[ -f "$f" ]] || continue
        . "$f"
        if [[ $first -eq 0 ]]; then json+=","; fi
        json+="\n    {\n      \"name\": \"$ADDON_NAME\",\n      \"installed_at\": \"$INSTALLED_AT\",\n      \"has_manual_edit\": $HAS_MANUAL_EDIT,\n      \"has_frontend\": $HAS_FRONTEND,\n      \"has_panel_files\": $HAS_PANEL_FILES,\n      \"has_migration\": $HAS_MIGRATION,\n      \"route_slugs\": \"$ROUTE_SLUGS\"\n    }"
        first=0
        count=$((count+1))
    done
    json+="\n  ],\n  \"count\": $count\n}"

    if echo -e "$json" > "$out"; then
        echo -e "  $(_addon_color 32 "✓ Exported $count addon ke:")"
        echo -e "  $(_addon_color 36 "    $out")"
        echo -e "  $(_addon_color 33 "Salin file ini ke server lain, lalu gunakan menu Import.")"
        log_msg "Exported $count addon state ke $out"
        notify_detail "Addon Export" "Exported $count addon state."
    else
        fail "Gagal tulis ke $out"
    fi
    pause
}

_addon_import_state() {
    require_root || return 1
    local in="${1:-}"
    if [[ -z "$in" ]]; then
        read -r -p "  Path file JSON (kosongkan untuk browse di /root): " in
    fi
    [[ -z "$in" ]] && in="/root"
    if [[ -d "$in" ]]; then
        local files=()
        while IFS= read -r -d '' f; do
            files+=("$f")
        done < <(find "$in" -maxdepth 2 -name 'ptero-addons-export-*.json' -print0 2>/dev/null | sort -z)
        if [[ ${#files[@]} -eq 0 ]]; then
            fail "Tidak ada file ptero-addons-export-*.json di $in"; pause; return 1
        fi
        echo
        echo -e "  $(_addon_color 33 'Pilih file export:')"
        local i=0
        for f in "${files[@]}"; do i=$((i+1)); echo -e "  $(_addon_color 32 "$i") $(basename "$f")"; done
        echo -e "  $(_addon_color 31 '0')  Batal"
        read -r -p "  Pilih [0-$i]: " sel
        [[ "$sel" == "0" ]] && return
        [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= i )) || { pause; return; }
        in="${files[$((sel-1))]}"
    fi
    [[ ! -f "$in" ]] && { fail "File tidak ada: $in"; pause; return 1; }

    if ! command -v python3 >/dev/null 2>&1; then
        fail "python3 tidak tersedia (dibutuhkan untuk parse JSON)."; pause; return 1
    fi

    local names
    names=$(python3 -c "
import json, sys
try:
    with open('$in') as f:
        data = json.load(f)
    if 'addons' in data:
        for a in data['addons']:
            print(a.get('name',''))
except Exception as e:
    print('PARSE_ERROR: ' + str(e), file=sys.stderr)
    sys.exit(1)
" 2>/dev/null)

    if [[ -z "$names" ]]; then
        fail "Gagal parse JSON atau file kosong."; pause; return 1
    fi

    local addon_arr=()
    while IFS= read -r n; do
        [[ -n "$n" ]] && addon_arr+=("$n")
    done <<< "$names"

    echo
    echo -e "  $(_addon_color 32 "Ditemukan ${#addon_arr[@]} addon di export:")"
    for n in "${addon_arr[@]}"; do
        local mark=" "
        _addon_is_installed "$n" && mark="✓ (sudah)"
        echo -e "    - $n$mark"
    done
    echo
    confirm_action "Install ${#addon_arr[@]} addon di atas (yang belum terinstall)?" || { echo "Batal."; pause; return; }

    local installed=0 skipped=0 failed=0
    for n in "${addon_arr[@]}"; do
        if _addon_is_installed "$n"; then
            skipped=$((skipped+1))
            continue
        fi
        local zipfile="$ADDON_DIR/$n.zip"
        if [[ ! -f "$zipfile" ]]; then
            echo -e "  $(_addon_color 31 "Skip: $n (zip tidak ada di $ADDON_DIR)")"
            failed=$((failed+1))
            continue
        fi
        echo
        echo -e "  $(_addon_color 36 "── Installing: $n ──")"
        if _addon_install_single "$n" >/dev/null 2>&1; then
            installed=$((installed+1))
            echo -e "  $(_addon_color 32 "✓ $n")"
        else
            failed=$((failed+1))
            echo -e "  $(_addon_color 31 "✗ $n gagal")"
        fi
    done
    echo
    echo -e "  $(_addon_color 32 "Selesai: $installed terinstall, $skipped sudah ada, $failed gagal")"
    log_msg "Addon import: $installed installed, $skipped skipped, $failed failed"
    notify_detail "Addon Import" "Import: $installed installed, $skipped skipped, $failed failed."
    pause
}

# ====================================================
# BULK install/uninstall
# ====================================================

_addon_pick_multi() {
    local prompt="$1"
    shift
    local items=("$@")
    [[ ${#items[@]} -eq 0 ]] && return 1
    local i=0
    for x in "${items[@]}"; do i=$((i+1)); echo -e "  $(_addon_color 32 "$i") $x"; done
    echo -e "  $(_addon_color 36 "Contoh: '1,3,5' atau '1-3' atau 'all' atau '0' batal")"
    read -r -p "  $prompt: " raw
    [[ "$raw" == "0" ]] && return 1
    local picks=()
    if [[ "$raw" == "all" ]]; then
        picks=("${items[@]}")
    else
        local IFS=','
        for part in $raw; do
            part=$(echo "$part" | tr -d ' ')
            if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                local s=${BASH_REMATCH[1]} e=${BASH_REMATCH[2]}
                (( s >= 1 && e <= ${#items[@]} && s <= e )) || continue
                for ((x=s; x<=e; x++)); do picks+=("${items[$((x-1))]}"); done
            elif [[ "$part" =~ ^[0-9]+$ ]] && (( part >= 1 && part <= ${#items[@]} )); then
                picks+=("${items[$((part-1))]}")
            fi
        done
    fi
    [[ ${#picks[@]} -eq 0 ]] && return 1
    printf '%s\n' "${picks[@]}"
    return 0
}

_addon_bulk_install() {
    require_root || return 1
    local addons=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && addons+=("$line")
    done < <(_addon_get_list)
    if [[ ${#addons[@]} -eq 0 ]]; then
        echo -e "  $(_addon_color 31 'Tidak ada addon')"; pause; return
    fi
    _addon_header
    echo -e "  $(_addon_color 33 'Pilih addon yang mau diinstall (bisa lebih dari 1):')"
    local picks
    picks=$(_addon_pick_multi "Pilih nomor" "${addons[@]}") || { echo "Batal."; pause; return; }

    local pick_arr=()
    while IFS= read -r p; do [[ -n "$p" ]] && pick_arr+=("$p"); done <<< "$picks"

    local skipped=0
    local to_install=()
    for p in "${pick_arr[@]}"; do
        if _addon_is_installed "$p"; then
            echo -e "  $(_addon_color 33 "Skip (sudah): $p")"
            skipped=$((skipped+1))
        else
            to_install+=("$p")
        fi
    done

    [[ ${#to_install[@]} -eq 0 ]] && { echo -e "  $(_addon_color 33 'Tidak ada yang perlu diinstall.')"; pause; return; }

    confirm_action "Install ${#to_install[@]} addon (skip $skipped yang sudah ada)?" || { echo "Batal."; pause; return; }

    local ok=0 fail=0
    for p in "${to_install[@]}"; do
        echo
        echo -e "  $(_addon_color 36 "── [$((ok+fail+1))/${#to_install[@]}] $p ──")"
        if _addon_install_single "$p"; then
            ok=$((ok+1))
        else
            fail=$((fail+1))
        fi
    done
    echo
    echo -e "  $(_addon_color 32 "Bulk install selesai: ${ok} sukses, ${fail} gagal")"
    log_msg "Bulk install: $ok ok, $fail fail"
    notify_detail "Addon Bulk Install" "$ok sukses, $fail gagal."
    pause
}

_addon_bulk_uninstall() {
    require_root || return 1
    local installed=()
    for f in "$ADDON_MARKER_DIR"/*.installed; do
        [[ -f "$f" ]] || continue
        . "$f"
        installed+=("$ADDON_NAME")
    done
    [[ ${#installed[@]} -eq 0 ]] && { echo -e "  $(_addon_color 33 'Belum ada addon terinstall.')"; pause; return; }
    _addon_header
    echo -e "  $(_addon_color 33 'Pilih addon yang mau diuninstall:')"
    local picks
    picks=$(_addon_pick_multi "Pilih nomor" "${installed[@]}") || { echo "Batal."; pause; return; }
    local pick_arr=()
    while IFS= read -r p; do [[ -n "$p" ]] && pick_arr+=("$p"); done <<< "$picks"
    confirm_action "Uninstall ${#pick_arr[@]} addon?" || { echo "Batal."; pause; return; }
    local ok=0 fail=0
    for p in "${pick_arr[@]}"; do
        if _addon_uninstall_single "$p" >/dev/null 2>&1; then ok=$((ok+1)); else fail=$((fail+1)); fi
    done
    echo
    echo -e "  $(_addon_color 32 "Bulk uninstall selesai: ${ok} sukses, ${fail} gagal")"
    log_msg "Bulk uninstall: $ok ok, $fail fail"
    pause
}

# ====================================================
# DIFF installed vs available + REINSTALL ALL
# ====================================================

_addon_diff() {
    require_root || return 1
    local available=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && available+=("$line")
    done < <(_addon_get_list)
    local installed=()
    for f in "$ADDON_MARKER_DIR"/*.installed; do
        [[ -f "$f" ]] || continue
        . "$f"
        installed+=("$ADDON_NAME")
    done

    _addon_header
    echo -e "  $(_addon_color 33 'Diff: Tersedia vs Terinstall')"
    echo
    echo -e "  $(_addon_color 36 '── Belum diinstall ──')"
    local missing=0
    for a in "${available[@]}"; do
        if ! _addon_is_installed "$a"; then
            missing=$((missing+1))
            echo -e "    ${YELLOW}○${NC} $a"
        fi
    done
    [[ $missing -eq 0 ]] && echo -e "    ${GREEN}(semua addon sudah terinstall)${NC}"

    echo
    echo -e "  $(_addon_color 36 '── Sudah diinstall ──')"
    [[ ${#installed[@]} -eq 0 ]] && echo -e "    ${YELLOW}(belum ada)${NC}"
    for i in "${installed[@]}"; do echo -e "    ${GREEN}●${NC} $i"; done

    echo
    echo -e "  Summary: ${CYAN}${#available[@]}${NC} tersedia, ${GREEN}${#installed[@]}${NC} terinstall, ${YELLOW}$missing${NC} belum"
    pause
}

_addon_reinstall_all() {
    require_root || return 1
    local installed=()
    for f in "$ADDON_MARKER_DIR"/*.installed; do
        [[ -f "$f" ]] || continue
        . "$f"
        installed+=("$ADDON_NAME")
    done
    [[ ${#installed[@]} -eq 0 ]] && { echo -e "  $(_addon_color 33 'Belum ada addon terinstall.')"; pause; return; }
    _addon_header
    echo -e "  $(_addon_color 33 'Akan reinstall ${#installed[@]} addon:')"
    for a in "${installed[@]}"; do echo -e "    - $a"; done
    echo
    confirm_action "Reinstall semua ${#installed[@]} addon di atas?" || { echo "Batal."; pause; return; }
    local ok=0 fail=0
    for a in "${installed[@]}"; do
        echo
        echo -e "  $(_addon_color 36 "── [$((ok+fail+1))/${#installed[@]}] $a ──")"
        rm -f "$ADDON_MARKER_DIR/$a.installed"
        if _addon_install_single "$a"; then
            ok=$((ok+1))
        else
            fail=$((fail+1))
        fi
    done
    echo
    echo -e "  $(_addon_color 32 "Reinstall selesai: ${ok} sukses, ${fail} gagal")"
    log_msg "Reinstall all: $ok ok, $fail fail"
    pause
}

# ====================================================
# Public entry point
_addon_uninstall_phpmyadmin() {
    require_root || return 1
    local target="$PANEL_DIR/public/pma"

    if [[ ! -d "$target" ]]; then
        echo -e "  $(_addon_color 33 "phpMyAdmin tidak terinstall di $target")"
        pause
        return 0
    fi

    echo -e "  $(_addon_color 31 "PERINGATAN: phpMyAdmin akan dihapus permanen dari panel.")"
    echo -e "  $(_addon_color 33 "User MySQL phpmyadmin TIDAK ikut dihapus (drop manual jika perlu).")"
    confirm_action "Hapus phpMyAdmin dari $target ?" || { echo "Dibatalkan."; pause; return 0; }

    rm -rf "$target"
    echo -e "  $(_addon_color 32 "✓ phpMyAdmin dihapus dari $target")"
    echo -e "  $(_addon_color 33 "User MySQL masih ada. Untuk hapus, jalankan:")"
    echo -e "  $(_addon_color 36 "    sudo mysql -e \"DROP USER IF EXISTS 'phpmyadmin'@'%';\"")"
    log_msg "phpMyAdmin dihapus dari $target"
    notify_detail "phpMyAdmin Removed" "phpMyAdmin diuninstall dari panel."
    pause
}

# ====================================================
# Public entry point
_addon_install_phpmyadmin() {
    require_root || return 1
    local target="$PANEL_DIR/public/pma"

    echo
    echo -e "  $(_addon_color 36 'Buat user MySQL untuk phpMyAdmin:')"
    read -r -p "  Username [phpmyadmin]: " PMA_USER
    PMA_USER="${PMA_USER:-phpmyadmin}"
    while true; do
        read -r -s -p "  Password: " PMA_PASS
        echo
        read -r -s -p "  Ulangi password: " PMA_PASS2
        echo
        [[ "$PMA_PASS" == "$PMA_PASS2" && -n "$PMA_PASS" ]] && break
        echo -e "  $(_addon_color 31 'Password tidak cocok atau kosong!')"
    done

    if [[ -f "$target/index.php" ]]; then
        echo -e "  $(_addon_color 32 'phpMyAdmin sudah terinstall di /pma')"
        echo -e "  $(_addon_color 33 'Versi:') $(grep -oP 'Version \K[0-9.]+' "$target/README.txt" 2>/dev/null || echo "?")"
        echo
        if confirm_action "Install ulang?"; then
            rm -rf "$target"
        else
            return
        fi
    fi

    echo -e "  $(_addon_color 36 'Mendownload phpMyAdmin...')"
    local tmpdir
    tmpdir=$(mktemp -d)
    cd "$tmpdir" || return 1

    wget -q "https://www.phpmyadmin.net/downloads/phpMyAdmin-latest-all-languages.zip" -O phpmyadmin.zip || {
        fail "Gagal download phpMyAdmin"
        rm -rf "$tmpdir"
        return 1
    }

    unzip -q phpmyadmin.zip || {
        fail "Gagal extract zip"
        rm -rf "$tmpdir"
        return 1
    }

    local dirname
    dirname=$(ls -d phpMyAdmin-*/ 2>/dev/null | head -1)
    [[ -z "$dirname" ]] && {
        fail "Gagal nemuin folder hasil extract"
        rm -rf "$tmpdir"
        return 1
    }

    rm -rf "$target"
    mv "$dirname" "$target"
    chown -R www-data:www-data "$target"

    mkdir -p "$target/tmp"
    chown www-data:www-data "$target/tmp"

    if [[ -f "$target/config.sample.inc.php" ]] && [[ ! -f "$target/config.inc.php" ]]; then
        cp "$target/config.sample.inc.php" "$target/config.inc.php"
        local secret
        secret=$(openssl rand -base64 32)
        sed -i "s|cfg\['blowfish_secret'\] = ''|cfg['blowfish_secret'] = '$secret'|" "$target/config.inc.php"
    fi

    rm -rf "$tmpdir"

    # Create dedicated phpMyAdmin MySQL user
    sudo mysql -e "DROP USER IF EXISTS 'phpmyadmin'@'127.0.0.1'; DROP USER IF EXISTS 'phpmyadmin'@'%'; CREATE USER '$PMA_USER'@'%' IDENTIFIED BY '$PMA_PASS'; GRANT ALL PRIVILEGES ON *.* TO '$PMA_USER'@'%' WITH GRANT OPTION; FLUSH PRIVILEGES;" 2>/dev/null

    echo
    echo -e "  $(_addon_color 32 '✓ phpMyAdmin siap!')"
    echo -e "  $(_addon_color 36 'Akses:') https://$(hostname)/pma"
    echo -e "  $(_addon_color 36 'User MySQL:')"
    echo -e "    $(_addon_color 33 'Username:') $PMA_USER"
    echo -e "    $(_addon_color 33 'Password:') $PMA_PASS"
    echo -e "    $(_addon_color 33 'Server:')   0.0.0.0"
    pause
}

# ====================================================

_addon_backup() {
    clear
    _addon_header
    echo -e "  $(_addon_color 36 'Backup Ptero-Manager')"
    echo

    local backup_dir="/root/ptero-manager-backup"
    mkdir -p "$backup_dir"

    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    local zipname="ptero-manager-backup-$ts.zip"

    echo -e "  $(_addon_color 33 'Mengompres ptero-manager + opencode config...')"

    cd /
    # Flush WAL to DB so backup is consistent
    sqlite3 /root/.local/share/opencode/opencode.db "PRAGMA wal_checkpoint(TRUNCATE);" 2>/dev/null

    zip -r "$backup_dir/$zipname" \
        root/ptero-manager/ \
        root/.local/share/opencode/opencode.db \
        root/.local/share/opencode/storage/session_diff/ \
        root/.local/share/opencode/tool-output/ \
        root/.local/share/opencode/log/ \
        root/.local/state/opencode/prompt-history.jsonl \
        root/.local/state/opencode/kv.json \
        root/.local/state/opencode/model.json \
        home/runner/.config/opencode/opencode.jsonc \
        var/www/pterodactyl/routes/admin.php \
        var/www/pterodactyl/routes/api-client.php \
        var/www/pterodactyl/routes/api-remote.php \
        -x "root/ptero-manager/.git/*" "root/ptero-manager/addon-pterodactyl/*.zip" 2>&1 | tail -3

    echo
    echo -e "  $(_addon_color 32 "✓ Backup selesai!")"
    echo -e "  File: $backup_dir/$zipname"
    echo -e "  Size: $(du -h "$backup_dir/$zipname" | cut -f1)"
    echo
    echo -e "  $(_addon_color 36 'Untuk restore, pilih menu Restore (8)')"
    echo -e "  $(_addon_color 36 'atau jalankan:')"
    echo -e "  $(_addon_color 37 "    unzip $backup_dir/$zipname -d /root/ptero-manager-restore")"
    pause
}

_addon_restore() {
    clear
    _addon_header
    echo -e "  $(_addon_color 36 'Restore Ptero-Manager')"
    echo

    local backup_dir="/root/ptero-manager-backup"
    if [[ ! -d "$backup_dir" ]]; then
        echo -e "  $(_addon_color 31 'Tidak ada backup ditemukan di /root/ptero-manager-backup/')"
        pause
        return
    fi

    local backups=()
    local i=0
    while IFS= read -r -d '' f; do
        backups+=("$f")
        ((i++))
    done < <(find "$backup_dir" -name '*.zip' -print0 2>/dev/null | sort -z)

    if (( ${#backups[@]} == 0 )); then
        echo -e "  $(_addon_color 31 'Tidak ada file .zip backup ditemukan.')"
        pause
        return
    fi

    echo -e "  $(_addon_color 33 'Pilih backup yang akan direstore:')"
    echo
    for (( idx=0; idx<${#backups[@]}; idx++ )); do
        local fname
        fname=$(basename "${backups[$idx]}")
        local fsize
        fsize=$(du -h "${backups[$idx]}" | cut -f1)
        echo -e "  $(_addon_color 32 "$((idx+1))")  $fname ($fsize)"
    done
    echo -e "  $(_addon_color 31 '0')  Batal"
    echo
    read -r -p "  Pilih [0-${#backups[@]}]: " sel

    if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#backups[@]} )); then
        local chosen="${backups[$((sel-1))]}"
        echo
        echo -e "  $(_addon_color 33 "Restore dari: $(basename "$chosen")...")"

        local restore_dir="/root/ptero-manager-restore"
        rm -rf "$restore_dir"
        mkdir -p "$restore_dir"

        unzip -q "$chosen" -d "$restore_dir"

        local restored=0

        # Restore ptero-manager
        if [[ -d "$restore_dir/root/ptero-manager" ]]; then
            rm -rf /root/ptero-manager
            cp -a "$restore_dir/root/ptero-manager" /root/ptero-manager
            echo -e "  $(_addon_color 32 '  ✓ Ptero-Manager')"
            restored=1
        elif [[ -d "$restore_dir/ptero-manager" ]]; then
            rm -rf /root/ptero-manager
            cp -a "$restore_dir/ptero-manager" /root/ptero-manager
            echo -e "  $(_addon_color 32 '  ✓ Ptero-Manager')"
            restored=1
        fi

        # Restore opencode config & data
        if [[ -f "$restore_dir/home/runner/.config/opencode/opencode.jsonc" ]]; then
            mkdir -p /home/runner/.config/opencode
            cp -a "$restore_dir/home/runner/.config/opencode/opencode.jsonc" /home/runner/.config/opencode/opencode.jsonc
            echo -e "  $(_addon_color 32 '  ✓ Opencode config')"
            restored=1
        fi
        if [[ -f "$restore_dir/root/.local/share/opencode/opencode.db" ]]; then
            mkdir -p /root/.local/share/opencode
            cp -a "$restore_dir/root/.local/share/opencode/opencode.db" /root/.local/share/opencode/opencode.db
            echo -e "  $(_addon_color 32 '  ✓ Opencode database')"
            restored=1
        fi
        if [[ -f "$restore_dir/root/.local/state/opencode/prompt-history.jsonl" ]]; then
            mkdir -p /root/.local/state/opencode
            cp -a "$restore_dir/root/.local/state/opencode/prompt-history.jsonl" /root/.local/state/opencode/prompt-history.jsonl
            echo -e "  $(_addon_color 32 '  ✓ Opencode history')"
            restored=1
        fi
        if [[ -d "$restore_dir/root/.local/share/opencode/storage/session_diff" ]]; then
            mkdir -p /root/.local/share/opencode/storage
            cp -a "$restore_dir/root/.local/share/opencode/storage/session_diff" /root/.local/share/opencode/storage/session_diff
            echo -e "  $(_addon_color 32 '  ✓ Opencode session diffs')"
            restored=1
        fi
        if [[ -d "$restore_dir/root/.local/share/opencode/tool-output" ]]; then
            cp -a "$restore_dir/root/.local/share/opencode/tool-output" /root/.local/share/opencode/
            echo -e "  $(_addon_color 32 '  ✓ Opencode tool output')"
            restored=1
        fi
        if [[ -d "$restore_dir/root/.local/share/opencode/log" ]]; then
            cp -a "$restore_dir/root/.local/share/opencode/log" /root/.local/share/opencode/
            echo -e "  $(_addon_color 32 '  ✓ Opencode logs')"
            restored=1
        fi

        # Restore panel routes
        if [[ -f "$restore_dir/var/www/pterodactyl/routes/admin.php" ]]; then
            cp -a "$restore_dir/var/www/pterodactyl/routes/admin.php" /var/www/pterodactyl/routes/admin.php
            echo -e "  $(_addon_color 32 '  ✓ Panel routes (admin.php)')"
            restored=1
        fi
        if [[ -f "$restore_dir/var/www/pterodactyl/routes/api-client.php" ]]; then
            cp -a "$restore_dir/var/www/pterodactyl/routes/api-client.php" /var/www/pterodactyl/routes/api-client.php
            restored=1
        fi

        if (( restored == 0 )); then
            echo -e "  $(_addon_color 31 'Gagal: struktur backup tidak dikenal.')"
            echo -e "  File diekstrak di: $restore_dir"
        else
            echo -e "  $(_addon_color 32 '✓ Restore selesai!')"
        fi

        rm -rf "$restore_dir"
    fi
    pause
}

# ====================================================

addon_manager() {
    _addon_menu
}
