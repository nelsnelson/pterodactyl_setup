# Pterodactyl Panel + Wings docker setup

How to install and configure Pterodactly Panel and Wings as Docker-managed container services.


## Install Docker

Install the latest version of docker.

```sh
sudo apt install docker.io
sudo apt install docker-compose
sudo mkdir -p /usr/local/lib/docker/cli-plugins
# As of 2025-11-23, latest stable is v2.40.3
sudo curl --show-error --location "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m)" /usr/local/lib/docker/cli-plugins/docker-compose
sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
docker compose version
```


## Clone this repository

First, clone this repository.

```sh
git clone git@github.com:nelsnelson/pterodactyl_setup.git
```


## Install Pterodactyl

Download Pterodactyl Panel.

```sh
# As of 2025-11-23, latest stable is v1.11.11
curl --remote-name --location 'https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz'
mkdir panel
tar -xf panel.tar.gz -C panel
cd panel
```


## Services configuration

Modify the `docker-compose.example.yml` file to automatically create an admin user.

```sh
cp ../pterodactyl_setup/docker-compose.yml docker-compose-with-wings.yml
```


## Start services

Test it out.

```sh
docker compose --file=./docker-compose-with-wings.yml up --force-recreate --detach
curl http://localhost/
docker compose --file=./docker-compose-with-wings.yml logs
```

To tear down (warning -- this means deleting everything):

```sh
docker compose --file=./docker-compose-with-wings.yml down --volumes --remove-orphans
```


## Set up Pterodactyl

Create an admin user.

This email has to be an actual real email.

```sh
EMAIL=CHANGEME@example.com
FIRST_NAME=Anonymous
LAST_NAME=User
docker exec panel-panel-1 php artisan p:user:make --email=$EMAIL --admin=1 --username=admin --name-first=$FIRST_NAME --name-last=$LAST_NAME --password=password --no-interaction
```


## Create a node

First, login to the Panel.  The Panel website should be navigable at:

http://triton/auth/login

Create a new node.  (TODO: Automate.  Example in the ./install.sh script.)

```sh
# Name it 01, or something.
```


## Configure the Wings service

Perform an "Auto-deploy" operation in the Panel.  (This will not work, because wings crashloops until the configuration exists.)

```sh
docker exec panel-wings-1 cd /etc/pterodactyl && sudo wings configure --panel-url http://panel --token ptla_pointless-redaction --node 1 --allow-insecure
```

Or, instead, manually lay down the Wings configuration file.  The Wings configuration file is obtained from the Configuration tab of the Panel > Nodes > 01 page of the freshly created node.

Only the `remote:` field must be changed to match one's real hostname or IP address.

```sh
cat << EOF | sudo tee /var/lib/pterodactyl/wings/config.yml > /dev/null
debug: false
uuid: ee56f1f6-5467-47c9-99dd-e4d56d7b9901
token_id: wVoEmQkIU1SHY2FB
token: pointless-redaction
api:
  host: 0.0.0.0
  port: 8080
  ssl:
    enabled: false
    cert: /etc/letsencrypt/live/triton/fullchain.pem
    key: /etc/letsencrypt/live/triton/privkey.pem
  upload_limit: 100
system:
  data: /var/lib/pterodactyl/volumes
  sftp:
    bind_port: 2022
allowed_mounts: []
remote: 'http://triton'
EOF
```


### Enable CORS

Enable CORS for Panel's web interface.

```sh
sudo sed -i.bak -f - /var/lib/pterodactyl/wings/config.yml <<'EOF'
/^allowed_origins: \[\]$/{
  s//allowed_origins:/
  a\
  - http://triton
}
/^allow_cors_private_network: false$/{
  s//allow_cors_private_network: true/
}
EOF
```


## Allocate IP address

Create a new IP allocation for the node.

```sh
192.1681.141
triton
25565 -> 27000-27050
```

