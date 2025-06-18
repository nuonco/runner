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
# FIXME(sdboyer) this hack must be fixed - userdata is only run on instance creation, and ip can change on each boot
HOST_IP=$(curl -s https://checkip.amazonaws.com)
EOF

# Fetch runner settings from the API
echo "Fetching runner settings from $RUNNER_API_URL/v1/runners/$RUNNER_ID/settings"
RUNNER_SETTINGS=$(curl -s -H "Authorization: Bearer $RUNNER_API_TOKEN" "$RUNNER_API_URL/v1/runners/$RUNNER_ID/settings")

# Extract container image URL and tag from the response
CONTAINER_IMAGE_URL=$(echo "$RUNNER_SETTINGS" | grep -o '"container_image_url":"[^"]*"' | cut -d '"' -f 4)
CONTAINER_IMAGE_TAG=$(echo "$RUNNER_SETTINGS" | grep -o '"container_image_tag":"[^"]*"' | cut -d '"' -f 4)

echo "Using container image: $CONTAINER_IMAGE_URL:$CONTAINER_IMAGE_TAG"


# Create systemd unit file for runner
cat << EOF > /etc/systemd/system/nuon-runner.service
[Unit]
Description=Nuon Runner Service
After=docker.service
Requires=docker.service

[Service]
TimeoutStartSec=0
User=runner
ExecStartPre=-/bin/sh -c "/usr/bin/docker stop $(/usr/bin/docker ps -a -q --filter=\"name=%n\")"
ExecStartPre=-/bin/sh -c "/usr/bin/docker rm   $(/usr/bin/docker ps -a -q --filter=\"name=%n\")"
ExecStartPre=-/bin/sh -c "yes | /usr/bin/docker system prune"
ExecStartPre=/usr/bin/docker pull ${CONTAINER_IMAGE_URL:-public.ecr.aws/p7e3r5y0/runner}:${CONTAINER_IMAGE_TAG:-latest}
ExecStart=/usr/bin/docker run -v /tmp/nuon-runner:/tmp --rm --name %n -p 5000:5000 --memory "3750g" --cpus="1.75" --env-file /opt/nuon/runner/env --log-driver=awslogs --log-opt awslogs-region=$AWS_REGION --log-opt awslogs-group=runner-$RUNNER_ID ${CONTAINER_IMAGE_URL:-public.ecr.aws/p7e3r5y0/runner}:${CONTAINER_IMAGE_TAG:-latest} run
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF

# Just in case SELinux might be unhappy
/sbin/restorecon -v /etc/systemd/system/nuon-runner.service
systemctl daemon-reload
systemctl enable --now nuon-runner
