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
mkdir -p /opt/nuon/runner/.config/systemd/user
Chown -R runner:runner /opt/nuon/runner

# nopassword root access
cat << EOF > /etc/sudoers.d/runner
runner ALL= NOPASSWD: `which systemctl` enable --system nuon-runner.service
runner ALL= NOPASSWD: `which systemctl` start --system nuon-runner.service
runner ALL= NOPASSWD: `which systemctl` stop --system nuon-runner.service
runner ALL= NOPASSWD: `which systemctl` restart --system nuon-runner.service
runner ALL= NOPASSWD: `which systemctl` restart --system nuon-runner.service
runner ALL= NOPASSWD: `which shutdown` -h now
EOF

#
# grant group:runner permission to manage the nuon-runner.service via systemd
#

cat << 'EOF' > /etc/polkit-1/rules.d/50-runner-manage-nuon-service.rules
polkit.addRule(function(action, subject) {
  if (action.id == "org.freedesktop.systemd1.manage-units" &&
      action.lookup("unit") == "nuon-runner.service" &&
      subject.isInGroup("runner")) {
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
        action.id.includes("org.freedesktop.login1.power") ||
        action.id.includes("org.freedesktop.login1.reboot") ||
        action.id.includes("org.freedesktop.login1.set-reboot-") ||
    ) {
        return polkit.Result.YES;
    }
});
EOF

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

# NOTE: HOST_IP: userdata is only run on instance creation, and ip can change on each boot. we set it "up front" here but it
# should be fetched fresh by the `runner mng` process whnever the env file is recreated.
cat << EOF > /opt/nuon/runner/env
RUNNER_ID=$RUNNER_ID
RUNNER_API_URL=$RUNNER_API_URL
AWS_REGION=$AWS_REGION
HOST_IP=$(curl -s https://checkip.amazonaws.com)
GIT_REF="local-binary"
EOF

cat << EOF > /opt/nuon/runner/token
RUNNER_API_TOKEN=$RUNNER_API_TOKEN
EOF

cat << EOF > /opt/nuon/runner/image
CONTAINER_IMAGE_URL=$CONTAINER_IMAGE_URL
CONTAINER_IMAGE_TAG=$CONTAINER_IMAGE_TAG
EOF

# chown again, just so they know who's boss
chown -R runner:runner /opt/nuon/runner

#
# install runner binary (tag: latest always)
#
curl -fsSL https://nuon-artifacts.s3.us-west-2.amazonaws.com/runner/install.sh > /tmp/install-runner.sh
chmod +x /tmp/install-runner.sh
yes | /tmp/install-runner.sh 43aff5cc5d9ecefc048aebc931b3ba75905f7e62 /opt/nuon/runner/bin
rm /tmp/install-runner.sh

#
# Create systemd unit file for "runner mng" process
#

cat << 'EOF' > /etc/systemd/system/nuon-runner-mng.service
[Unit]
Description=Nuon Runner Mng Service

[Service]
TimeoutStartSec=0
StandardOutput=file:/var/log/runner-mng/logs.log
StandardError=file:/var/log/runner-mng/errors.log
User=runner
EnvironmentFile=/opt/nuon/runner/image
EnvironmentFile=/opt/nuon/runner/env
EnvironmentFile=/opt/nuon/runner/token
ExecStart=/opt/nuon/runner/bin/runner mng
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF

#
# create file and grant ownership
#

chown runner:runner /etc/systemd/system/nuon-runner.service

#
# Just in case SELinux might be unhappy
#

/sbin/restorecon -v /etc/systemd/system/nuon-runner-mng.service
systemctl daemon-reload
systemctl enable nuon-runner-mng
systemctl start nuon-runner-mng
