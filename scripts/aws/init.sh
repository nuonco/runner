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

# Create systemd unit file for runner
cat << EOF > /etc/systemd/system/nuon-runner.service
[Unit]
Description=Nuon Runner Service
After=docker.service
Requires=docker.service

[Service]
TimeoutStartSec=0
User=runner
ExecStartPre=-/usr/bin/docker exec %n stop
ExecStartPre=-/usr/bin/docker rm %n
ExecStartPre=/usr/bin/docker pull public.ecr.aws/p7e3r5y0/runner:latest
ExecStart=/usr/bin/docker run --rm --name %n -p 5000:5000 --detach --env-file /opt/nuon/runner/env public.ecr.aws/p7e3r5y0/runner:latest run
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF

# Just in case SELinux might be unhappy
/sbin/restorecon -v /etc/systemd/system/nuon-runner.service
systemctl daemon-reload
systemctl enable --now nuon-runner