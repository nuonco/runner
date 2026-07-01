#!/bin/bash

#
# Nuon Runner Init Script
# Runs on a VM on GCP
#

#
# schedule a hard-deadline shutdown FIRST, before any other commands run.
#
# this is a safety net: if any command in this script fails, hangs, or loops
# indefinitely (e.g. apt install, metadata fetch, fetch-token retry loop), the
# vm will still be shut down. the MIG (targetSize maintenance, no autohealing)
# recreates a TERMINATED instance to maintain its target size, replacing this
# vm with a fresh one.
#
# we save the pid so we can cancel this shutdown at the end of the script
# once we have confirmed the runner mng service is healthy. nohup + disown
# ensure the timer survives cloud-init script cleanup.
#
nohup bash -c 'sleep 900; /sbin/shutdown -h now "nuon-runner-mng userdata 15m hard deadline expired"' </dev/null >/dev/null 2>&1 &
SHUTDOWN_PID=$!
disown "$SHUTDOWN_PID" 2>/dev/null || true
echo "scheduled hard-deadline shutdown in 15m with pid=$SHUTDOWN_PID"

#
# install dependencies
# NOTE: Ubuntu 24.04+ required for polkit JS rules support
#

apt-get update -y
apt-get install -y docker.io policykit-1 jq
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
RUNNER_ID=${NUON_RUNNER_ID:-$(get_metadata "nuon_runner_id")}

# the runner binary version should never fall back to latest.
# if no value is provided (via metadata/env) leave it empty,
# attempt to retrieve from the API, and shut down if that fails.
RUNNER_BINARY_VERSION="${RUNNER_BINARY_VERSION:-}"

#
# Fetch public settings
#
echo "fetching public settings"
echo " > $RUNNER_API_URL/v1/runners/$RUNNER_ID/public-settings"
PUBLIC_SETTINGS=""
for i in $(seq 1 30); do
  PUBLIC_SETTINGS=$(curl -s "$RUNNER_API_URL/v1/runners/$RUNNER_ID/public-settings")
  if [ -n "$PUBLIC_SETTINGS" ] && [ "$PUBLIC_SETTINGS" != "null" ]; then
    echo "fetched public settings (attempt $i)"
    break
  fi
  echo "attempt $i/30: failed to fetch public settings, retrying in 2s"
  sleep 2
done

RUNNER_BINARY_VERSION=$(echo "$PUBLIC_SETTINGS" | jq -r '.binary_version // empty')
echo "runner binary version: $RUNNER_BINARY_VERSION"

runner_api_url=$(echo "$PUBLIC_SETTINGS" | jq -r '.runner_api_url // empty')
if [ -n "$runner_api_url" ]; then
  echo "setting RUNNER_API_URL from public settings: $runner_api_url"
  RUNNER_API_URL="$runner_api_url"
fi

if [ -z "$RUNNER_BINARY_VERSION" ]; then
  echo "No runner binary version provided and could not determine from Nuon Runner API - shutting down"
  /sbin/shutdown -h now "nuon-runner-mng could not determine RUNNER_BINARY_VERSION"
  exit 1
fi

#
# install runner binary (tag: RUNNER_BINARY_VERSION)
#

curl -fsSL https://nuon-artifacts.s3.us-west-2.amazonaws.com/runner/install.sh > /tmp/install-runner.sh
chmod +x /tmp/install-runner.sh
/tmp/install-runner.sh --no-input "$RUNNER_BINARY_VERSION" /opt/nuon/runner/bin
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

GCP_REGION=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/zone" | awk -F/ '{print $NF}' | sed 's/-[a-z]$//')

# gather facts for container image
RUNNER_API_TOKEN=$(cat /opt/nuon/runner/token | cut -d '=' -f 2)
RUNNER_SETTINGS=$(curl -s -H "Authorization: Bearer $RUNNER_API_TOKEN" "$RUNNER_API_URL/v1/runners/$RUNNER_ID/settings")
CONTAINER_IMAGE_URL=$(echo "$RUNNER_SETTINGS" | grep -o '"container_image_url":"[^"]*"' | cut -d '"' -f 4)
CONTAINER_IMAGE_TAG=$(echo "$RUNNER_SETTINGS" | grep -o '"container_image_tag":"[^"]*"' | cut -d '"' -f 4)

#
# create env files (env, image, token). these env files are used by the systemd unit files AND by the processes they manage.
#

# Size container from VM resources, leaving 1Gi host headroom (avoids OOM/page-cache thrash on builds)
MEM_TOTAL_MB=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
if [ "$MEM_TOTAL_MB" -gt 3072 ]; then
  RUNNER_MEMORY="$((MEM_TOTAL_MB - 1024))m"
else
  RUNNER_MEMORY="$((MEM_TOTAL_MB * 80 / 100))m"
fi
RUNNER_CPUS=$(nproc)

cat << EOF > /opt/nuon/runner/env
RUNNER_ID=$RUNNER_ID
RUNNER_API_URL=$RUNNER_API_URL
GCP_REGION=$GCP_REGION
CLOUD_PROVIDER=gcp
HOST_IP=$(curl -s https://checkip.amazonaws.com)
RUNNER_MEMORY=$RUNNER_MEMORY
RUNNER_CPUS=$RUNNER_CPUS
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

#
# poll nuon-runner-mng health every 15s. a single "is-active" check is not
# enough because the unit has Restart=always, so it can look "active"
# momentarily between crashes in a restart loop. to confirm the service is
# actually stable we require:
#   - ActiveState=active and SubState=running
#   - the current run has been up for at least MIN_UPTIME_SEC seconds
#     (ActiveEnterTimestamp resets on every restart, so a crash loop will
#     never accumulate enough uptime to pass this check)
#   - REQUIRED_CONSECUTIVE consecutive samples meet the above
#
# if the service stabilizes, cancel the hard-deadline shutdown. otherwise,
# let the timer fire and let the MIG replace this vm.
#
HEALTHY=false
CONSECUTIVE_HEALTHY=0
REQUIRED_CONSECUTIVE=3
MIN_UPTIME_SEC=60

for i in $(seq 1 60); do
    ACTIVE_STATE=$(systemctl show nuon-runner-mng --property=ActiveState --value)
    SUB_STATE=$(systemctl show nuon-runner-mng --property=SubState --value)
    N_RESTARTS=$(systemctl show nuon-runner-mng --property=NRestarts --value)
    ACTIVE_ENTER=$(systemctl show nuon-runner-mng --property=ActiveEnterTimestamp --value)

    UPTIME_SEC=0
    if [ -n "$ACTIVE_ENTER" ]; then
        ACTIVE_ENTER_EPOCH=$(date -d "$ACTIVE_ENTER" +%s 2>/dev/null || echo 0)
        if [ "$ACTIVE_ENTER_EPOCH" -gt 0 ]; then
            UPTIME_SEC=$(( $(date +%s) - ACTIVE_ENTER_EPOCH ))
        fi
    fi

    if [ "$ACTIVE_STATE" = "active" ] && [ "$SUB_STATE" = "running" ] && [ "$UPTIME_SEC" -ge "$MIN_UPTIME_SEC" ]; then
        CONSECUTIVE_HEALTHY=$((CONSECUTIVE_HEALTHY + 1))
        echo "nuon-runner-mng stable ($CONSECUTIVE_HEALTHY/$REQUIRED_CONSECUTIVE consecutive): uptime=${UPTIME_SEC}s restarts=$N_RESTARTS (attempt $i/60)"
        if [ "$CONSECUTIVE_HEALTHY" -ge "$REQUIRED_CONSECUTIVE" ]; then
            HEALTHY=true
            break
        fi
    else
        CONSECUTIVE_HEALTHY=0
        echo "nuon-runner-mng not stable: state=$ACTIVE_STATE/$SUB_STATE uptime=${UPTIME_SEC}s restarts=$N_RESTARTS (attempt $i/60)"
    fi

    sleep 15
done

if [ "$HEALTHY" = "true" ]; then
    echo "cancelling hard-deadline shutdown (pid=$SHUTDOWN_PID)"
    kill "$SHUTDOWN_PID" 2>/dev/null || true
else
    echo "nuon-runner-mng failed to stabilize, leaving hard-deadline shutdown in place"
fi
