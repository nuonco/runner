#!/bin/bash

#
# install dependencies
#

yum install -y docker amazon-cloudwatch-agent polkit
systemctl enable --now docker

#
# set up user, home directory, and subdirs for the runner
#

useradd runner -G docker -c "" -d /opt/nuon/runner
usermod -a -G root runner # TODO(fd): root?
mkdir -p /opt/nuon/runner/bin

#
# commands which we want to be able to run w/ passwordless sudo
# - fallback for shutdown
#

cat << EOF > /etc/sudoers.d/runner
runner ALL= NOPASSWD: `which shutdown` -h now
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
# gather some facts
#

get_tag() {
    local tag_name=$1
    local instance_id=$(ec2-metadata -i | awk '{ print $2 }')

    aws ec2 describe-tags \
        --filters "Name=resource-id,Values=$instance_id" "Name=key,Values=$tag_name" \
        --query 'Tags[0].Value' \
        --output text
}

RUNNER_ID=$(get_tag "nuon_runner_id")
RUNNER_API_TOKEN=$(get_tag "nuon_runner_api_token")
RUNNER_API_URL=$(get_tag "nuon_runner_api_url")
AWS_REGION=$(ec2-metadata -R | awk '{ print $2 }')

# gather facts for container image

RUNNER_SETTINGS=$(curl -s -H "Authorization: Bearer $RUNNER_API_TOKEN" "$RUNNER_API_URL/v1/runners/$RUNNER_ID/settings")
CONTAINER_IMAGE_URL=$(echo "$RUNNER_SETTINGS" | grep -o '"container_image_url":"[^"]*"' | cut -d '"' -f 4)
CONTAINER_IMAGE_TAG=$(echo "$RUNNER_SETTINGS" | grep -o '"container_image_tag":"[^"]*"' | cut -d '"' -f 4)

#
# create env files (env, image, token). these env files are used by the systemd unit files AND by the processes they manage.
#

# NOTE: HOST_IP: userdata is only run on instance creation, and ip can change on each boot. we set it "up front" here.
# in all likelihood, the runner vm will have restarted if the ip has changed.
cat << EOF > /opt/nuon/runner/env
RUNNER_ID=$RUNNER_ID
RUNNER_API_URL=$RUNNER_API_URL
AWS_REGION=$AWS_REGION
HOST_IP=$(curl -s https://checkip.amazonaws.com)
EOF

cat << EOF > /opt/nuon/runner/token
RUNNER_API_TOKEN=$RUNNER_API_TOKEN
EOF

cat << EOF > /opt/nuon/runner/image
CONTAINER_IMAGE_URL=$CONTAINER_IMAGE_URL
CONTAINER_IMAGE_TAG=$CONTAINER_IMAGE_TAG
EOF

#
# install runner binary (tag: latest always)
# NOTE(fd): we want a pre-release version for a moment while we test the new commands
#

curl -fsSL https://nuon-artifacts.s3.us-west-2.amazonaws.com/runner/install.sh > /tmp/install-runner.sh
chmod +x /tmp/install-runner.sh
yes | /tmp/install-runner.sh 65c4a07 /opt/nuon/runner/bin
rm /tmp/install-runner.sh

#
# change ownership - ensure user runner can execute the runner binary
#

chown -R runner:runner /opt/nuon/runner

#
# create directory for logs
# TODO(fd): send logs to cloudwatch
#

mkdir /var/log/nuon-runner-mng

#
# configure cloudwatch
#
cat << EOF > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
{
  "agent": {
    "region": "$AWS_REGION",
    "logfile": "/opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log"
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/nuon-runner-mng/*.log",
            "log_group_name": "runner-$RUNNER_ID",
            "log_stream_name": "nuon-runner-mng-{date}",
            "timezone": "UTC"
          }
        ]
      }
    },
    "log_stream_name": "nuon-runner-mng",
    "force_flush_interval": 10
  }
}
EOF

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
Environment="GIT_REF=65c4a07"
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
# Just in case SELinux might be unhappy
#

/sbin/restorecon -v /etc/systemd/system/nuon-runner-mng.service
systemctl daemon-reload
systemctl enable nuon-runner-mng
systemctl start nuon-runner-mng

#
# re-start cloudwatch agent so our config is picked up
#
systemctl restart amazon-cloudwatch-agent
