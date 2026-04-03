#!/bin/bash

#
# install dependencies
# NOTE: Ubuntu 24.04+ required for polkit JS rules support
#

apt-get update -y
apt-get install -y docker.io policykit-1
systemctl enable --now docker

#
# set up user, home directory, and subdirs for the runner
#

useradd runner -G docker -c "" -d /opt/nuon/runner || true
usermod -a -G root runner
mkdir -p /opt/nuon/runner/bin

#
# commands which we want to be able to run w/ passwordless sudo
# - fallback for shutdown
#

cat << EOF > /etc/sudoers.d/runner
runner ALL= NOPASSWD: $(which shutdown) -h now
EOF

#
# grant group:runner permission to manage the nuon-runner.service via systemd
#

cat << 'EOF' > /etc/polkit-1/rules.d/50-runner-manage-nuon-service.rules
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.systemd1.reload-daemon" && subject.isInGroup("runner")) {
        return polkit.Result.YES;
    }
});

polkit.addRule(function(action, subject) {
    if (
        action.id == "org.freedesktop.systemd1.manage-units" &&
        action.lookup("unit") == "nuon-runner.service" &&
        subject.isInGroup("runner")
    ) {
        return polkit.Result.YES;
    }
});
EOF

#
# grant group:runner permission to shutdown and reboot the VM
#

cat << 'EOF' > /etc/polkit-1/rules.d/10-runner-shutdown.rules
polkit.addRule(function(action, subject) {
    if (
      (
        action.id.includes("org.freedesktop.login1.power")      ||
        action.id.includes("org.freedesktop.login1.reboot")     ||
        action.id.includes("org.freedesktop.login1.set-reboot-")
      ) && subject.isInGroup("runner")
    ) {
        return polkit.Result.YES;
    }
});
EOF

#
# restart polkit so policies take effect
#

systemctl restart polkit.service

#
# gather some facts from GCP metadata
#

get_metadata() {
    local key=$1
    curl -s -H "Metadata-Flavor: Google" \
        "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$key" 2>/dev/null || echo ""
}

RUNNER_API_URL=${NUON_RUNNER_API_URL:-$(get_metadata "nuon_runner_api_url")}

#
# install runner binary (tag: latest always)
#

curl -fsSL https://nuon-artifacts.s3.us-west-2.amazonaws.com/runner/install.sh > /tmp/install-runner.sh
chmod +x /tmp/install-runner.sh
/tmp/install-runner.sh --no-input latest /opt/nuon/runner/bin
rm /tmp/install-runner.sh

#
# change ownership - ensure user runner can execute the runner binary
#

chown -R runner:runner /opt/nuon/runner

# run mng fetch-token with the runner api url (retry indefinitely every 15s until success)
while ! sudo -u runner RUNNER_API_URL="$RUNNER_API_URL" CLOUD_PROVIDER=gcp /opt/nuon/runner/bin/runner mng fetch-token; do
  echo "mng fetch-token failed, retrying in 15s"
  sleep 15
done

#
# gather more facts
#

RUNNER_ID=${NUON_RUNNER_ID:-$(get_metadata "nuon_runner_id")}
GCP_REGION=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/zone" | awk -F/ '{print $NF}' | sed 's/-[a-z]$//')

# gather facts for container image
RUNNER_API_TOKEN=$(cat /opt/nuon/runner/token | cut -d '=' -f 2)
RUNNER_SETTINGS=$(curl -s -H "Authorization: Bearer $RUNNER_API_TOKEN" "$RUNNER_API_URL/v1/runners/$RUNNER_ID/settings")
CONTAINER_IMAGE_URL=$(echo "$RUNNER_SETTINGS" | grep -o '"container_image_url":"[^"]*"' | cut -d '"' -f 4)
CONTAINER_IMAGE_TAG=$(echo "$RUNNER_SETTINGS" | grep -o '"container_image_tag":"[^"]*"' | cut -d '"' -f 4)

#
# create env files (env, image, token). these env files are used by the systemd unit files AND by the processes they manage.
#

cat << EOF > /opt/nuon/runner/env
RUNNER_ID=$RUNNER_ID
RUNNER_API_URL=$RUNNER_API_URL
GCP_REGION=$GCP_REGION
CLOUD_PROVIDER=gcp
HOST_IP=$(curl -s https://checkip.amazonaws.com)
EOF

cat << EOF > /opt/nuon/runner/image
CONTAINER_IMAGE_URL=$CONTAINER_IMAGE_URL
CONTAINER_IMAGE_TAG=$CONTAINER_IMAGE_TAG
EOF

# grant the runner ownership over the files here
chown -R runner:runner /opt/nuon/runner

#
# create directory for logs
#

mkdir -p /var/log/nuon-runner-mng

#
# Create systemd unit file for "runner mng" process
#

cat << 'EOF' > /etc/systemd/system/nuon-runner-mng.service
[Unit]
Description=Nuon Runner Mng Service

[Service]
TimeoutStartSec=0
StandardOutput=file:/var/log/nuon-runner-mng/logs.log
StandardError=file:/var/log/nuon-runner-mng/errors.log
User=runner
EnvironmentFile=/opt/nuon/runner/image
EnvironmentFile=/opt/nuon/runner/env
EnvironmentFile=/opt/nuon/runner/token
Environment="GIT_REF=latest"
ExecStart=/opt/nuon/runner/bin/runner mng
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF

#
# create the nuon-runner.service file and change owner to runner:runner
#

touch /etc/systemd/system/nuon-runner.service
chown runner:runner /etc/systemd/system/nuon-runner.service

#
# start the management service
#

systemctl daemon-reload
systemctl enable nuon-runner-mng
systemctl start nuon-runner-mng
