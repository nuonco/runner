#!/bin/bash

#
# Nuon Runner Init Script
# Runs on a VM on GCP
#

#
# halt is unrecoverable when the runner is a bare instance and not a managed
# group -- nothing recreates it. reboot instead, and only halt once retries
# are exhausted. armed per phase so a slow package mirror cannot eat the
# budget the runner needs to stabilize.
#
BOOTSTRAP_STATE=/var/lib/nuon-runner-bootstrap
MAX_BOOTSTRAP_ATTEMPTS=3
DEPS_PHASE_TIMEOUT=900
RUNNER_PHASE_TIMEOUT=900

# boot_id keys the counter to boots, not to userdata's in-boot retries.
BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)
BOOTSTRAP_ATTEMPTS=$(sed -n 1p "$BOOTSTRAP_STATE" 2>/dev/null || echo 0)
if [ "$(sed -n 2p "$BOOTSTRAP_STATE" 2>/dev/null)" != "$BOOT_ID" ]; then
  BOOTSTRAP_ATTEMPTS=$((BOOTSTRAP_ATTEMPTS + 1))
  mkdir -p "$(dirname "$BOOTSTRAP_STATE")"
  printf '%s\n%s\n' "$BOOTSTRAP_ATTEMPTS" "$BOOT_ID" > "$BOOTSTRAP_STATE"
fi

if [ "$BOOTSTRAP_ATTEMPTS" -gt "$MAX_BOOTSTRAP_ATTEMPTS" ]; then
  DEADLINE_ACTION="/sbin/shutdown -h now"
else
  DEADLINE_ACTION="/sbin/reboot"
fi

DEADLINE_PID=""

cancel_deadline() {
  if [ -n "$DEADLINE_PID" ]; then
    kill "$DEADLINE_PID" 2>/dev/null || true
    DEADLINE_PID=""
  fi
}

arm_deadline() {
  local timeout=$1 phase=$2
  cancel_deadline
  nohup bash -c "sleep $timeout; $DEADLINE_ACTION \"nuon-runner-mng $phase deadline expired after ${timeout}s (boot $BOOTSTRAP_ATTEMPTS)\"" </dev/null >/dev/null 2>&1 &
  DEADLINE_PID=$!
  disown "$DEADLINE_PID" 2>/dev/null || true
  echo "armed $phase deadline: ${timeout}s, action=$DEADLINE_ACTION, pid=$DEADLINE_PID (boot $BOOTSTRAP_ATTEMPTS/$MAX_BOOTSTRAP_ATTEMPTS)"
}

arm_deadline "$DEPS_PHASE_TIMEOUT" dependency-install

#
# install dependencies
# NOTE: Ubuntu 24.04+ required for polkit JS rules support
#

apt-get update -y
apt-get install -y docker.io policykit-1 jq
systemctl enable --now docker

arm_deadline "$RUNNER_PHASE_TIMEOUT" runner-bootstrap

#
# set up user, home directory, and subdirs for the runner
#

useradd runner -G docker -c "" -d /opt/nuon/runner || true
usermod -a -G root runner
mkdir -p /opt/nuon/runner/bin
install -d -o runner -g runner -m 0700 /opt/nuon/action-workspaces

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
# Determine Runner Binary Version
#
echo "determining runner binary version"
echo " > $RUNNER_API_URL/v1/runners/$RUNNER_ID/public-settings"
for i in $(seq 1 30); do
  runner_binary_version=$(curl -s "$RUNNER_API_URL/v1/runners/$RUNNER_ID/public-settings" | jq -r '.binary_version')
  if [ -n "$runner_binary_version" ] && [ "$runner_binary_version" != "null" ]; then
    RUNNER_BINARY_VERSION="$runner_binary_version"
    echo "determined runner binary version: $RUNNER_BINARY_VERSION"
    break
  fi
  echo "attempt $i/30: failed to determine runner binary version, retrying in 2s"
  sleep 2
done

if [ -z "$RUNNER_BINARY_VERSION" ]; then
  echo "No runner binary version provided and could not determine from Nuon Runner API"
  $DEADLINE_ACTION "nuon-runner-mng could not determine RUNNER_BINARY_VERSION"
  exit 1
fi

#
# install runner binary (tag: RUNNER_BINARY_VERSION)
#

curl -fsSL https://nuon-artifacts.s3.us-west-2.amazonaws.com/runner/install.sh > /tmp/install-runner.sh
chmod +x /tmp/install-runner.sh
RUNNER_API_URL="$RUNNER_API_URL" /tmp/install-runner.sh --no-input "$RUNNER_BINARY_VERSION" /opt/nuon/runner/bin
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
    echo "cancelling bootstrap deadline (pid=$DEADLINE_PID)"
    cancel_deadline
    rm -f "$BOOTSTRAP_STATE"
else
    echo "nuon-runner-mng failed to stabilize, leaving bootstrap deadline in place"
fi
