#!/bin/bash
set -euo pipefail

RUNNER_ID="${RUNNER_ID:?}"
RUNNER_API_URL="${RUNNER_API_URL:?}"
RUNNER_PLATFORM="${RUNNER_PLATFORM:-azure}"
CONTAINER_IMAGE_URL="${CONTAINER_IMAGE_URL:?}"
CONTAINER_IMAGE_TAG="${CONTAINER_IMAGE_TAG:?}"
AWS_REGION="${AWS_REGION:?}"

apt-get remove -y docker docker-engine docker.io containerd runc

apt-get update
apt-get install -y ca-certificates curl gnupg lsb-release jq

mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

rm -f /etc/systemd/system/docker.service
rm -f /etc/systemd/system/docker.socket
systemctl daemon-reload
systemctl unmask docker.service
systemctl unmask docker.socket
systemctl enable docker
systemctl start docker

groupadd -f docker
mkdir -p /opt/nuon/runner
useradd runner -G docker -c "" -d /opt/nuon/runner -m
chown -R runner:runner /opt/nuon/runner

auth_line=""
if [ -n "${AZURE_RUNNER_AUTH_RESOURCE:-}" ]; then
  auth_line="AZURE_RUNNER_AUTH_RESOURCE=$AZURE_RUNNER_AUTH_RESOURCE"
fi

cat << EOF > /opt/nuon/runner/env
RUNNER_ID=$RUNNER_ID
RUNNER_API_URL=$RUNNER_API_URL
RUNNER_PLATFORM=$RUNNER_PLATFORM
ARM_USE_MSI=true
HOST_IP=$(curl -s https://checkip.amazonaws.com)
$auth_line
EOF

RUNNER_BINARY_VERSION="${CONTAINER_IMAGE_TAG:-latest}"
echo "determining runner binary version"
echo "> $RUNNER_API_URL/v1/runners/$RUNNER_ID/public-settings"
for i in $(seq 1 30); do
  runner_binary_version=$(curl -s "$RUNNER_API_URL/v1/runners/$RUNNER_ID/public-settings" | jq -r '.binary_version // empty')
  if [ -n "$runner_binary_version" ] && [ "$runner_binary_version" != "null" ]; then
    RUNNER_BINARY_VERSION="$runner_binary_version"
    echo "determined runner binary version: $RUNNER_BINARY_VERSION"
    break
  fi
  echo "attempt $i/30: failed to determine runner binary version, retrying in 2s"
  sleep 2
done

mkdir -p /opt/nuon/runner/bin
curl -fsSL https://nuon-artifacts.s3.us-west-2.amazonaws.com/runner/install.sh > /tmp/install-runner.sh
chmod +x /tmp/install-runner.sh
yes | /tmp/install-runner.sh $RUNNER_BINARY_VERSION /opt/nuon/runner/bin
rm /tmp/install-runner.sh

cat << EOF > /opt/nuon/runner/image
CONTAINER_IMAGE_URL=$CONTAINER_IMAGE_URL
CONTAINER_IMAGE_TAG=$CONTAINER_IMAGE_TAG
EOF

chown -R runner:runner /opt/nuon/runner

cat << 'EOF' > /etc/systemd/system/nuon-runner-mng.service
[Unit]
Description=Nuon Runner Management Service
After=docker.service
Requires=docker.service

[Service]
TimeoutStartSec=0
User=root
EnvironmentFile=/opt/nuon/runner/env
ExecStart=/opt/nuon/runner/bin/runner mng
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF

systemctl daemon-reload
systemctl enable --now nuon-runner-mng
