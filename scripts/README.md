# Scripts

This directory contains scripts that are executed as part of the [runner's]((https://docs.nuon.co/concepts/runners)) bootstrapping processes, when other more standard mechanisms are not available.

## `aws/init.sh`

This script is set as the [UserData](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/user-data.html) for runner EC2 instances, causing it to be run on exactly once on first boot.

The script installs docker and the cloudwatch agent, then sets up a systemd service that fetches the latest image of Nuon's runner and sets it to restart always.

Eventually, this script will be modified to offer more control over runner version.

## `aws/phonehome.py`

This script is triggered [as a lambda](https://docs.aws.amazon.com/lambda/latest/dg/services-cloudformation.html) on success or failure of Cloudformation stack creation. It tells the Nuon control plane that a new runner now exists, and reports information that is necessary for subsequent runner bootstrapping
and day-to-day operation (e.g. ARNs for IAM roles the runner needs to assume).