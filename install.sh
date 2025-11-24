#! /usr/bin/env  bash

# https://github.com/oneclickvirt/pterodactyl
# 2025.11.23

myvar=$(pwd)
PANEL_DIR="/var/lib/pterodactyl"
USER_FILE="$PANEL_DIR/auto_users.txt"
COOKIES_FILE="/tmp/pterodactyl_cookies.txt"

# Global variables used to store function return values
G_IPV4=""
G_PANEL_URL=""
G_ADMIN_EMAIL=""
G_ADMIN_PASSWORD=""
G_CSRF_TOKEN=""
G_NODE_ID=""
G_INSTALL_TOKEN=""
G_ADMIN_KEY=""

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "Error: The script must be run as root!"
        exit 1
    fi
}

is_private_ipv4() {
    local ip=$1
    if [ -z "$ip" ]; then
        return 0
    fi
    if ! echo "$ip" | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' >/dev/null; then
        return 0
    fi
    IFS='.' read -r -a ip_parts <<<"$ip"
    # 10.0.0.0/8
    if [ "${ip_parts[0]}" -eq 10 ]; then
        return 0
    fi
    # 172.16.0.0/12
    if [ "${ip_parts[0]}" -eq 172 ] && [ "${ip_parts[1]}" -ge 16 ] && [ "${ip_parts[1]}" -le 31 ]; then
        return 0
    fi
    # 192.168.0.0/16
    if [ "${ip_parts[0]}" -eq 192 ] && [ "${ip_parts[1]}" -eq 168 ]; then
        return 0
    fi
    # 127.0.0.0/8
    if [ "${ip_parts[0]}" -eq 127 ]; then
        return 0
    fi
    # 169.254.0.0/16
    if [ "${ip_parts[0]}" -eq 169 ] && [ "${ip_parts[1]}" -eq 254 ]; then
        return 0
    fi
    # 224.0.0.0/4
    if [ "${ip_parts[0]}" -ge 224 ] && [ "${ip_parts[0]}" -le 239 ]; then
        return 0
    fi
    # 0.0.0.0
    if [ "${ip_parts[0]}" -eq 0 ] && [ "${ip_parts[1]}" -eq 0 ] && [ "${ip_parts[2]}" -eq 0 ] && [ "${ip_parts[3]}" -eq 0 ]; then
        return 0
    fi
    # RFC 6598 (100.64.0.0/10)
    if [ "${ip_parts[0]}" -eq 100 ] && [ "${ip_parts[1]}" -ge 64 ] && [ "${ip_parts[1]}" -le 127 ]; then
        return 0
    fi
    return 1
}

get_ipv4() {
    local output
    output=$(ip -4 addr show | grep global | awk '{print $2}' | cut -d '/' -f1 | head -n 1)
    if [ -n "$output" ]; then
        if ! is_private_ipv4 "$output"; then
            G_IPV4="$output"
            return 0
        fi
    fi
    local api_list=(
        "https://ipv4.ip.sb"
        "https://ipget.net"
        "https://ip.ping0.cc"
        "https://ip4.seeip.org"
        "https://api.my-ip.io/ip"
        "https://ipv4.icanhazip.com"
        "https://api.ipify.org"
    )
    for api_url in "${api_list[@]}"; do
        if ip=$(curl -s --connect-timeout 8 "$api_url"); then
            if [ -n "$ip" ] && ! echo "$ip" | grep -i "error" >/dev/null; then
                G_IPV4="$ip"
                return 0
            fi
        fi
        sleep 1
    done
    return 1
}

read_panel_config() {
    if [ ! -f "$USER_FILE" ]; then
        return 1
    fi
    local panel_ip=""
    G_PANEL_URL=""
    G_ADMIN_EMAIL=""
    G_ADMIN_PASSWORD=""
    while IFS= read -r line; do
        if [[ "$line" == *Login page* ]]; then
            panel_ip=$(echo "$line" | sed -n 's#.*http://\([^/:]*\).*#\1#p')
            G_PANEL_URL="http://$panel_ip"
        elif [[ "$line" == *Username* ]]; then
            G_ADMIN_EMAIL=$(echo "$line" | cut -d':' -f2- | sed 's/^ *//')
        elif [[ "$line" == *Password* ]]; then
            G_ADMIN_PASSWORD=$(echo "$line" | cut -d':' -f2- | sed 's/^ *//')
        fi
    done <"$USER_FILE"
    G_PANEL_URL=$(echo "$G_PANEL_URL" | xargs)
    G_ADMIN_EMAIL=$(echo "$G_ADMIN_EMAIL" | xargs)
    G_ADMIN_PASSWORD=$(echo "$G_ADMIN_PASSWORD" | xargs)
    if [ -z "$G_PANEL_URL" ] || [ -z "$G_ADMIN_EMAIL" ] || [ -z "$G_ADMIN_PASSWORD" ]; then
        return 1
    fi
    G_PANEL_URL=${G_PANEL_URL%/}
    return 0
}

create_node() {
    local node_name=$1
    local node_memory=$2
    local node_over_memory=$3
    local node_disk=$4
    local node_over_disk=$5
    local ipv4=$6
    echo "Starting to create node: $node_name"
    echo "Node IP address: $ipv4"
    echo "Node configuration: Memory=${node_memory}MB (over-allocation ${node_over_memory}%) Disk=${node_disk}MB (over-allocation ${node_over_disk}%)"
    cd "$PANEL_DIR" || exit 1
    if ! php artisan p:node:make \
        "--name=$node_name" \
        "--description=Auto Generate" \
        "--locationId=1" \
        "--fqdn=$ipv4" \
        "--public=1" \
        "--scheme=http" \
        "--proxy=0" \
        "--maintenance=0" \
        "--maxMemory=$node_memory" \
        "--overallocateMemory=$node_over_memory" \
        "--maxDisk=$node_disk" \
        "--overallocateDisk=$node_over_disk" \
        "--uploadSize=1024" \
        "--daemonListeningPort=8080" \
        "--daemonSFTPPort=2022" \
        "--daemonBase=/var/lib/pterodactyl" \
        "--no-interaction"; then
        echo "Error: Node creation failed"
        return 1
    fi
    echo "Node created successfully!"
    return 0
}

login_panel() {
    local panel_url=$1
    local admin_email=$2
    local admin_password=$3
    echo "Logging in to Pterodactyl panel: $panel_url"
    rm -f "$COOKIES_FILE" 2>/dev/null
    local csrf_response
    csrf_response=$(curl -s -c "$COOKIES_FILE" -b "$COOKIES_FILE" "$panel_url/sanctum/csrf-cookie")
    sleep 1
    local xsrf_token
    xsrf_token=$(grep -oP 'XSRF-TOKEN\s+\K[^\s]+' "$COOKIES_FILE" | sed 's/%3D/=/g' | sed 's/%3d/=/g')
    if [ -z "$xsrf_token" ]; then
        echo "Could not get XSRF-TOKEN"
        return 1
    fi
    xsrf_token=$(echo "$xsrf_token" | sed -e 's/%\([0-9A-F][0-9A-F]\)/\\\\\\x\1/g' | xargs -0 printf "%b")
    echo "Decoded XSRF-TOKEN: $xsrf_token"
    local login_data="{\"user\":\"$admin_email\",\"password\":\"$admin_password\",\"g-recaptcha-response\":\"\"}"
    local login_response
    login_response=$(curl -s -c "$COOKIES_FILE" -b "$COOKIES_FILE" \
        -H "Content-Type: application/json" \
        -H "X-XSRF-TOKEN: $xsrf_token" \
        -H "Referer: $panel_url/auth/login" \
        -H "X-Requested-With: XMLHttpRequest" \
        -H "Accept: application/json" \
        -d "$login_data" \
        "$panel_url/auth/login")
    local admin_check_status
    sleep 1
    admin_check_status=$(curl -s -o /dev/null -w "%{http_code}" -c "$COOKIES_FILE" -b "$COOKIES_FILE" "$panel_url/admin")
    sleep 1
    echo "$panel_url/admin login response status code: $admin_check_status"
    echo "Login response text: ${login_response:0:200}"
    if ! echo "$login_response" | grep -q '"complete":true'; then
        echo "Error: Panel login failed, please check whether username and password are correct!"
        return 1
    fi
    local updated_token
    updated_token=$(grep -oP 'XSRF-TOKEN\s+\K[^\s]+' "$COOKIES_FILE" | sed 's/%3D/=/g' | sed 's/%3d/=/g')
    updated_token=$(echo "$updated_token" | sed -e 's/%\([0-9A-F][0-9A-F]\)/\\\\\\x\1/g' | xargs -0 printf "%b")
    echo "Login successful, obtained CSRF token: $updated_token"
    G_CSRF_TOKEN="$updated_token"
    return 0
}

get_latest_node_id() {
    local result
    result=$(php /var/www/pterodactyl/artisan p:node:list --format=json 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$result" ]; then
        G_NODE_ID="1"
        return 0
    fi
    local latest_node_id
    latest_node_id=$(echo "$result" | jq '.[-1].id')
    if [ -n "$latest_node_id" ]; then
        G_NODE_ID="$latest_node_id"
    else
        G_NODE_ID="1"
    fi
    return 0
}

generate_admin_api_key() {
    local panel_url=$1
    local api_page_url="$panel_url/admin/api"
    local key_file="AdminKey.txt"
    echo "Fetching API page..."
    sleep 1
    local api_page_content
    api_page_content=$(curl -s -b "$COOKIES_FILE" "$api_page_url")
    if [ $? -ne 0 ] || [ -z "$api_page_content" ]; then
        echo "Failed to fetch API page"
        return 1
    fi
    local admin_key
    admin_key=$(echo "$api_page_content" | tr -d '\n' | grep -oP '<td><code>(ptla_[^<]+)</code></td>\s*<td>AdminKey</td>' | grep -oP 'ptla_[^<]+')
    if [ -n "$admin_key" ]; then
        echo "Found existing AdminKey, using this key directly."
        G_ADMIN_KEY="$admin_key"
        echo "$G_ADMIN_KEY" > "$key_file"
        return 0
    fi
    echo "No existing key found, trying to create a new API key..."
    local api_csrf_token
    api_csrf_token=$(echo "$api_page_content" | grep -oP '<meta name="_token" content="\K[^"]+')
    if [ -z "$api_csrf_token" ]; then
        echo "Unable to get CSRF token from API page"
        return 1
    fi
    echo "Obtained CSRF token: $api_csrf_token"
    sleep 1
    curl -s -b "$COOKIES_FILE" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -H "Origin: $panel_url" \
        -H "Referer: $panel_url/admin/api/new" \
        -X POST \
        --data-raw "r_allocations=3&r_database_hosts=3&r_eggs=3&r_locations=3&r_nests=3&r_nodes=3&r_server_databases=3&r_servers=3&r_users=3&memo=AdminKey&_token=$api_csrf_token" \
        "$panel_url/admin/api/new" > /dev/null
    sleep 3
    api_page_content=$(curl -s -b "$COOKIES_FILE" "$api_page_url")
    if [ $? -ne 0 ] || [ -z "$api_page_content" ]; then
        echo "Failed to fetch API page again"
        return 1
    fi
    admin_key=$(echo "$api_page_content" | tr -d '\n' | grep -oP '<td><code>(ptla_[^<]+)</code></td>\s*<td>AdminKey</td>' | grep -oP 'ptla_[^<]+')
    if [ -z "$admin_key" ]; then
        echo "Unable to extract API key from response"
        return 1
    fi
    G_ADMIN_KEY="$admin_key"
    echo "Successfully created API key: $G_ADMIN_KEY"
    echo "$G_ADMIN_KEY" > "$key_file"
    return 0
}

generate_install_token() {
    local panel_url=$1
    local node_id=$2
    local config_url="$panel_url/admin/nodes/view/$node_id/configuration"
    local html_content
    sleep 1
    html_content=$(curl -s -b "$COOKIES_FILE" "$config_url")
    if [ $? -ne 0 ] || [ -z "$html_content" ]; then
        return 1
    fi
    local csrf_token
    csrf_token=$(echo "$html_content" | grep -oP '<meta name="_token" content="\K[^"]+')
    if [ -z "$csrf_token" ]; then
        return 1
    fi
    local token_url="$panel_url/admin/nodes/view/$node_id/settings/token"
    local token_response
    sleep 1
    token_response=$(curl -s -b "$COOKIES_FILE" \
        -H "X-CSRF-TOKEN: $csrf_token" \
        -H "Accept: */*" \
        -H "X-Requested-With: XMLHttpRequest" \
        -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36" \
        -H "Origin: $panel_url" \
        -H "Referer: $panel_url/admin/nodes/view/$node_id/configuration" \
        -X POST \
        "$token_url")
    if [ $? -ne 0 ] || [ -z "$token_response" ]; then
        return 1
    fi
    local install_token
    install_token=$(echo "$token_response" | grep -oP '"token":"\K[^"]+')
    if [ -z "$install_token" ]; then
        return 1
    fi
    G_INSTALL_TOKEN="$install_token"
    return 0
}

show_wings_install_command() {
    cd $myvar >/dev/null 2>&1
    local panel_url=$1
    local install_token=$2
    local node_id=$3
    local cmd="(cd /etc/pterodactyl && sudo wings configure --panel-url \"$panel_url\" --token \"$install_token\" --node \"$node_id\")"
    echo -e "Command for one-click import of configuration on the wings side [with English parentheses]; this command is also saved in the current path as wings_cmd.txt to avoid forgetting it:"
    echo "$cmd"
    echo "$cmd" >> ./wings_cmd.txt
}

main() {
    check_root
    echo -n "Please enter node name [default: auto-node]: "
    read -r node_name
    node_name=${node_name:-auto-node}
    echo -n "Please enter node memory (MB) [default: 1024]: "
    read -r node_memory
    node_memory=${node_memory:-1024}
    if ! [[ "$node_memory" =~ ^[0-9]+$ ]]; then
        echo "Input must be a number, default will be used"
        node_memory=1024
    fi
    echo -n "Please enter memory over-allocation percentage [default: 0]: "
    read -r node_over_memory
    node_over_memory=${node_over_memory:-0}
    if ! [[ "$node_over_memory" =~ ^[0-9]+$ ]]; then
        echo "Input must be a number, default will be used"
        node_over_memory=0
    fi
    echo -n "Please enter node disk (MB) [default: 10240]: "
    read -r node_disk
    node_disk=${node_disk:-10240}
    if ! [[ "$node_disk" =~ ^[0-9]+$ ]]; then
        echo "Input must be a number, default will be used"
        node_disk=10240
    fi
    echo -n "Please enter disk over-allocation percentage [default: 0]: "
    read -r node_over_disk
    node_over_disk=${node_over_disk:-0}
    if ! [[ "$node_over_disk" =~ ^[0-9]+$ ]]; then
        echo "Input must be a number, default will be used"
        node_over_disk=0
    fi
    if ! get_ipv4; then
        echo "Unable to get IPv4 address, aborting script"
        exit 1
    fi
    if ! create_node "$node_name" "$node_memory" "$node_over_memory" "$node_disk" "$node_over_disk" "$G_IPV4"; then
        echo "Node creation failed, aborting script"
        exit 1
    fi
    echo "Reading panel configuration..."
    if ! read_panel_config; then
        echo "Unable to get panel configuration, aborting script"
        exit 1
    fi
    echo "Panel address: $G_PANEL_URL"
    echo "Admin email: $G_ADMIN_EMAIL"
    echo "Admin password: ${G_ADMIN_PASSWORD:0:3}****"
    if ! login_panel "$G_PANEL_URL" "$G_ADMIN_EMAIL" "$G_ADMIN_PASSWORD"; then
        echo "Panel login failed, aborting script"
        exit 1
    fi
    generate_admin_api_key "$G_PANEL_URL"
    get_latest_node_id
    echo "Using node ID: $G_NODE_ID"
    echo -n "Please confirm node ID [default: $G_NODE_ID]: "
    read -r input_node_id
    if [ -n "$input_node_id" ]; then
        if [[ "$input_node_id" =~ ^[0-9]+$ ]]; then
            G_NODE_ID=$input_node_id
        else
            echo "Invalid input, using default node ID: $G_NODE_ID"
        fi
    fi
    if ! generate_install_token "$G_PANEL_URL" "$G_NODE_ID"; then
        echo "Install token generation failed, aborting script"
        exit 1
    fi
    show_wings_install_command "$G_PANEL_URL" "$G_INSTALL_TOKEN" "$G_NODE_ID"
}

main
