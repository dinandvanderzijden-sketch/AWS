#!/bin/bash
set -euxo pipefail

# Installeert en registreert een GitHub Actions self-hosted runner.
# Draait binnen het Hub management subnet — heeft dus alleen uitgaand
# internet nodig (via de NAT Gateway) om github.com te bereiken; er hoeft
# nooit een poort open te staan voor inkomend verkeer vanaf internet.

dnf install -y docker git jq tar gzip
systemctl enable --now docker
usermod -aG docker ec2-user

RUNNER_VERSION="2.319.1"
mkdir -p /opt/actions-runner
cd /opt/actions-runner

curl -o actions-runner.tar.gz -L \
  "https://github.com/actions/runner/releases/download/v$${RUNNER_VERSION}/actions-runner-linux-x64-$${RUNNER_VERSION}.tar.gz"
tar xzf actions-runner.tar.gz
chown -R ec2-user:ec2-user /opt/actions-runner

sudo -u ec2-user ./config.sh \
  --url "https://github.com/${github_org}/${github_repo}" \
  --token "${runner_token}" \
  --name "$(hostname)" \
  --labels "${runner_labels}" \
  --work "_work" \
  --unattended \
  --replace

./svc.sh install ec2-user
./svc.sh start
