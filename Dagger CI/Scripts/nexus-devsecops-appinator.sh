#!/bin/bash

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
