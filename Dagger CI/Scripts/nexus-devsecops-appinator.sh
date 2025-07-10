#!/bin/bash

# ---- Standard DevSecOps Commands ----

# Create the DEV command script
echo 'docker run -itd --name=nexus-creator-vault -h nexus-creator-vault --privileged -p 1050:3000 -e PUID=1050 -e PGID=1050 -e TZ=America/Colorado --restart unless-stopped -v /dev:/dev -v creator-vault0:/config -v /var/run/docker.sock:/var/run/docker.sock natoascode/zero-trust-cockpit:creator-vault' > /usr/local/bin/DEV
chmod +x /usr/local/bin/DEV

# Create the SEC command script
echo 'docker run -itd --name=Underground-Nexus -h Underground-Nexus --privileged --init -p 22 -p 80:80 -p 8080:8080 -p 443:443 -p 1000:1000 -p 2375:2375 -p 2376:2376 -p 2377:2377 -p 9010:9010 -p 9050:9443 -p 18080:8080 -p 18443:18443 -v /dev:/dev -v underground-nexus-docker-socket:/var/run -v underground-nexus-data:/var/lib/docker/volumes -v nexus-bucket:/nexus-bucket natoascode/underground-nexus:amd64 && docker exec Underground-Nexus bash deploy-olympiad.sh' > /usr/local/bin/SEC
chmod +x /usr/local/bin/SEC

# Create the OPS command script
echo 'docker run -itd --name=Underground-Ops -h Underground-Ops --privileged --init -p 1060:1050 -v /dev:/dev -v underground-ops-docker-socket:/var/run -v underground-nexus-data:/var/lib/docker/volumes -v nexus-bucket:/nexus-bucket natoascode/underground-nexus:amd64' > /usr/local/bin/OPS
chmod +x /usr/local/bin/OPS

echo "Commands have been added to /usr/local/bin and are now executable."

# ---- Rebuild Commands ----

# Create the DEV-rebuild command script
echo 'docker container stop nexus-creator-vault && docker container rm nexus-creator-vault && docker volume rm creator-vault0 && docker pull natoascode/zero-trust-cockpit:creator-vault && docker run -itd --name=nexus-creator-vault -h nexus-creator-vault --privileged -p 1050:3000 -e PUID=1050 -e PGID=1050 -e TZ=America/Colorado --restart unless-stopped -v /dev:/dev -v creator-vault0:/config -v /var/run/docker.sock:/var/run/docker.sock natoascode/zero-trust-cockpit:creator-vault' > /usr/local/bin/DEV-rebuild
chmod +x /usr/local/bin/DEV-rebuild

# Create the SEC-rebuild command script
echo 'docker container stop Underground-Nexus && docker container rm Underground-Nexus && docker volume rm underground-nexus-docker-socket underground-nexus-data nexus-bucket && docker pull natoascode/underground-nexus:amd64 && docker run -itd --name=Underground-Nexus -h Underground-Nexus --privileged --init -p 22 -p 80:80 -p 8080:8080 -p 443:443 -p 1000:1000 -p 2375:2375 -p 2376:2376 -p 2377:2377 -p 9010:9010 -p 9050:9443 -p 18080:8080 -p 18443:18443 -v /dev:/dev -v underground-nexus-docker-socket:/var/run -v underground-nexus-data:/var/lib/docker/volumes -v nexus-bucket:/nexus-bucket natoascode/underground-nexus:amd64 && docker exec Underground-Nexus bash deploy-olympiad.sh' > /usr/local/bin/SEC-rebuild
chmod +x /usr/local/bin/SEC-rebuild

# Create the OPS-rebuild command script
echo 'docker container stop Underground-Ops && docker container rm Underground-Ops && docker volume rm underground-ops-docker-socket underground-nexus-data nexus-bucket && docker pull natoascode/underground-nexus:amd64 && docker run -itd --name=Underground-Ops -h Underground-Ops --privileged --init -p 1060:1050 -v /dev:/dev -v underground-ops-docker-socket:/var/run -v underground-nexus-data:/var/lib/docker/volumes -v nexus-bucket:/nexus-bucket natoascode/underground-nexus:amd64' > /usr/local/bin/OPS-rebuild
chmod +x /usr/local/bin/OPS-rebuild

