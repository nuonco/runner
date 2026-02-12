#!bin/bash

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

yum install -y docker amazon-cloudwatch-agent
systemctl enable --now docker

# Set up things for the runner
useradd runner -G docker -c "" -d /opt/nuon/runner
chown -R runner:runner /opt/nuon/runner

cat << EOF > /opt/nuon/runner/env
RUNNER_ID=$RUNNER_ID
RUNNER_API_TOKEN=$RUNNER_API_TOKEN
RUNNER_API_URL=$RUNNER_API_URL
AWS_REGION=$AWS_REGION
# FIXME(sdboyer) this hack must be fixed - userdata is only run on instance creation, and ip can change on each boot
HOST_IP=$(curl -s https://checkip.amazonaws.com)
EOF


# this ⤵ is wrapped w/ single quotes to prevent variable expansion.
cat << 'EOF' > /opt/nuon/runner/get_image_tag.sh
#!/bin/sh

set -u

# source this file to get some env vars
source /opt/nuon/runner/env

# Fetch runner settings from the API
echo "Fetching runner settings from $RUNNER_API_URL/v1/runners/$RUNNER_ID/settings"
RUNNER_SETTINGS=$(curl -s -H "Authorization: Bearer $RUNNER_API_TOKEN" "$RUNNER_API_URL/v1/runners/$RUNNER_ID/settings")

# Extract container image URL and tag from the response
CONTAINER_IMAGE_URL=$(echo "$RUNNER_SETTINGS" | grep -o '"container_image_url":"[^"]*"' | cut -d '"' -f 4)
CONTAINER_IMAGE_TAG=$(echo "$RUNNER_SETTINGS" | grep -o '"container_image_tag":"[^"]*"' | cut -d '"' -f 4)

# echo into a file for easier retrieval; re-create the file to avoid duplicate values.
rm -f /opt/nuon/runner/image
echo "CONTAINER_IMAGE_URL=$CONTAINER_IMAGE_URL" >> /opt/nuon/runner/image
echo "CONTAINER_IMAGE_TAG=$CONTAINER_IMAGE_TAG" >> /opt/nuon/runner/image

# export so we can get these values by sourcing this file
export CONTAINER_IMAGE_URL=$CONTAINER_IMAGE_URL
export CONTAINER_IMAGE_TAG=$CONTAINER_IMAGE_TAG

echo "Using container image: $CONTAINER_IMAGE_URL:$CONTAINER_IMAGE_TAG"
EOF

sh /opt/nuon/runner/get_image_tag.sh


# Create systemd unit file for runner
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
ExecStartPre=-/bin/sh /opt/nuon/runner/get_image_tag.sh
EnvironmentFile=/opt/nuon/runner/image
EnvironmentFile=/opt/nuon/runner/env
ExecStartPre=/usr/bin/docker pull ${CONTAINER_IMAGE_URL}:${CONTAINER_IMAGE_TAG}
ExecStart=/usr/bin/docker run -v /tmp/nuon-runner:/tmp --rm --name %n -p 5000:5000 --memory "3750g" --cpus="1.75" --env-file /opt/nuon/runner/env --log-driver=awslogs --log-opt awslogs-region=${AWS_REGION} --log-opt awslogs-group=runner-${RUNNER_ID} ${CONTAINER_IMAGE_URL}:${CONTAINER_IMAGE_TAG} run
ExecStopPost=-/bin/sh -c "rm -rf /tmp/nuon-runner/*"
ExecStopPost=-/bin/sh -c "/usr/bin/docker rmi  $(/usr/bin/docker images -a -q)"
ExecStopPost=-/bin/sh -c "yes | /usr/bin/docker system prune"
Restart=always
RestartSec=5
StartLimitIntervalSec=0

[Install]
WantedBy=default.target
EOF


# Just in case SELinux might be unhappy
/sbin/restorecon -v /etc/systemd/system/nuon-runner.service
systemctl daemon-reload
systemctl enable --now nuon-runner
