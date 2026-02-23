#!/bin/bash
set -e

# GCP runner init script
# Equivalent to scripts/aws/init.sh for GCE instances.
# Runner config is passed via instance metadata or environment variables.

get_metadata() {
    local key=$1
    curl -s -H "Metadata-Flavor: Google" \
        "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$key" 2>/dev/null || echo ""
}

# Try environment variables first (set by startup script), fall back to instance metadata
RUNNER_ID=${NUON_RUNNER_ID:-$(get_metadata "nuon_runner_id")}
RUNNER_API_TOKEN=${NUON_RUNNER_API_TOKEN:-$(get_metadata "nuon_runner_api_token")}
RUNNER_API_URL=${NUON_RUNNER_API_URL:-$(get_metadata "nuon_runner_api_url")}
INSTALL_ID=${NUON_INSTALL_ID:-$(get_metadata "nuon_install_id")}
GCP_REGION=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/zone" | awk -F/ '{print $NF}' | sed 's/-[a-z]$//')

# Install docker
apt-get update -y
apt-get install -y docker.io
systemctl enable --now docker

# Set up runner user
useradd runner -G docker -c "" -d /opt/nuon/runner || true
mkdir -p /opt/nuon/runner
chown -R runner:runner /opt/nuon/runner

cat << EOF > /opt/nuon/runner/env
RUNNER_ID=$RUNNER_ID
RUNNER_API_TOKEN=$RUNNER_API_TOKEN
RUNNER_API_URL=$RUNNER_API_URL
GCP_REGION=$GCP_REGION
HOST_IP=$(curl -s https://checkip.amazonaws.com)
EOF

cat << 'EOF' > /opt/nuon/runner/get_image_tag.sh
#!/bin/bash
set -u

. /opt/nuon/runner/env

echo "Fetching runner settings from $RUNNER_API_URL/v1/runners/$RUNNER_ID/settings"
RUNNER_SETTINGS=$(curl -s -H "Authorization: Bearer $RUNNER_API_TOKEN" "$RUNNER_API_URL/v1/runners/$RUNNER_ID/settings")

CONTAINER_IMAGE_URL=$(echo "$RUNNER_SETTINGS" | grep -o '"container_image_url":"[^"]*"' | cut -d '"' -f 4)
CONTAINER_IMAGE_TAG=$(echo "$RUNNER_SETTINGS" | grep -o '"container_image_tag":"[^"]*"' | cut -d '"' -f 4)

rm -f /opt/nuon/runner/image
echo "CONTAINER_IMAGE_URL=$CONTAINER_IMAGE_URL" >> /opt/nuon/runner/image
echo "CONTAINER_IMAGE_TAG=$CONTAINER_IMAGE_TAG" >> /opt/nuon/runner/image

export CONTAINER_IMAGE_URL=$CONTAINER_IMAGE_URL
export CONTAINER_IMAGE_TAG=$CONTAINER_IMAGE_TAG

echo "Using container image: $CONTAINER_IMAGE_URL:$CONTAINER_IMAGE_TAG"
EOF

bash /opt/nuon/runner/get_image_tag.sh

cat << 'EOF' > /etc/systemd/system/nuon-runner.service
[Unit]
Description=Nuon Runner Service
After=docker.service
Requires=docker.service

[Service]
TimeoutStartSec=0
User=runner
ExecStartPre=-/bin/sh -c "/usr/bin/docker stop $(/usr/bin/docker ps -a -q --filter=\"name=%n\")"
ExecStartPre=-/bin/sh -c "/usr/bin/docker rm   $(/usr/bin/docker ps -a -q --filter=\"name=%n\")"
ExecStartPre=-/bin/bash /opt/nuon/runner/get_image_tag.sh
EnvironmentFile=/opt/nuon/runner/image
EnvironmentFile=/opt/nuon/runner/env
ExecStartPre=/usr/bin/docker pull ${CONTAINER_IMAGE_URL}:${CONTAINER_IMAGE_TAG}
ExecStart=/usr/bin/docker run -v /tmp/nuon-runner:/tmp --rm --name %n -p 5000:5000 --memory "3750m" --cpus="1.75" --env-file /opt/nuon/runner/env ${CONTAINER_IMAGE_URL}:${CONTAINER_IMAGE_TAG} run
ExecStopPost=-/bin/sh -c "rm -rf /tmp/nuon-runner/*"
ExecStopPost=-/bin/sh -c "/usr/bin/docker rmi  $(/usr/bin/docker images -a -q)"
ExecStopPost=-/bin/sh -c "yes | /usr/bin/docker system prune"
Restart=always
RestartSec=5
StartLimitIntervalSec=0

[Install]
WantedBy=default.target
EOF

systemctl daemon-reload
systemctl enable --now nuon-runner
