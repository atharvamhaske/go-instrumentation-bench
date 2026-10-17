#!/usr/bin/env bash
# Usage: aws/aws.sh <command>
#   check        tools, credentials, region, AZs and vCPU quota; prints the cost per day
#   budget       monthly cost budget with email alerts at 50% and forecast 100% (EMAIL=, BUDGET_USD=25)
#   push         create ECR repos, log in, build linux/amd64 images and push them
#   up           EKS cluster (eksctl, ~15-20 min) + AWS Load Balancer Controller
#   platform     Jaeger, Prometheus, Grafana, site variants, launcher and the ALB Ingress
#   ingress      (re)apply only the Ingress; HTTPS when HOST has an issued ACM certificate
#   cert         request an ACM certificate for HOST and validate it through Route 53
#   dns          point HOST at the ALB (Route 53 alias record)
#   url          print the public URL
#   pause        scale both node groups to 0 (control plane + ALB keep billing)
#   resume       scale both node groups back to 1
#   down         delete the Ingress, wait for the ALB to go, remove the DNS record, delete the cluster
#   leftovers    list anything that still bills after `down`
#   ecr-delete   delete the ECR repos and their images
#   env          print `export REGISTRY=...` for bench.sh against ECR
# Env: AWS_REGION (else `aws configure get region`, else us-east-1), HOST (e.g. bench.example.com),
#      ZONE_ID (Route 53 zone for HOST; looked up if unset), EMAIL, BUDGET_USD,
#      APP_TYPE (c7i.large), LOAD_TYPE (m7i.large), ALLOW_CIDR (who may reach the ALB, 0.0.0.0/0)
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER=bench
REGION=${AWS_REGION:-$(aws configure get region 2>/dev/null || true)}
REGION=${REGION:-us-east-1}
APP_TYPE=${APP_TYPE:-c7i.large}
LOAD_TYPE=${LOAD_TYPE:-m7i.large}
HOST=${HOST:-}
export AWS_REGION=$REGION AWS_PAGER=""

log() { printf '\033[1m==> %s\033[0m\n' "$*" >&2; }
die() { log "$*"; exit 1; }
account() { aws sts get-caller-identity --query Account --output text; }
registry() { echo "$(account).dkr.ecr.$REGION.amazonaws.com"; }

check() {
  local t missing=0
  for t in aws eksctl kubectl helm docker jq; do
    command -v "$t" >/dev/null || { log "missing: $t (brew install $t)"; missing=1; }
  done
  [[ $missing == 0 ]] || exit 1
  aws sts get-caller-identity --query Arn --output text >/dev/null 2>&1 || die "AWS credentials missing or expired: run 'aws login' or 'aws configure sso'"
  log "account $(account), region $REGION, nodes $APP_TYPE (app) + $LOAD_TYPE (load)"
  log "zones offering both instance types: $(zones | tr '\n' ' ')"
  # L-1216C47A: running on-demand standard (A, C, D, H, I, M, R, T, Z) instances, in vCPUs.
  local quota
  quota=$(aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A --query Quota.Value --output text 2>/dev/null || echo "?")
  log "on-demand standard vCPU quota: $quota (two .large nodes need 4)"
  cat >&2 <<'EOF'
    Cost while running, us-east-1 on-demand (check your region's prices):
      EKS control plane                 $0.10/h    $2.40/day
      c7i.large app node                ~$0.089/h  $2.14/day
      m7i.large load node               ~$0.101/h  $2.42/day
      ALB (low traffic) + its 2 IPv4    ~$0.035/h  ~$0.85/day
      node IPv4 x2 + EBS 2x20 GB gp3               ~$0.35/day
      total                                        ~$8/day running, ~$3/day paused
    Not created on purpose: NAT gateway, CloudWatch control plane logs, EBS volumes for data.
EOF
}

# Zones that offer both instance types, sorted. The node groups go in the first one.
zones() {
  local a b
  a=$(aws ec2 describe-instance-type-offerings --location-type availability-zone \
    --filters "Name=instance-type,Values=$APP_TYPE" --query 'InstanceTypeOfferings[].Location' --output text | tr '\t' '\n' | sort)
  b=$(aws ec2 describe-instance-type-offerings --location-type availability-zone \
    --filters "Name=instance-type,Values=$LOAD_TYPE" --query 'InstanceTypeOfferings[].Location' --output text | tr '\t' '\n' | sort)
  comm -12 <(echo "$a") <(echo "$b")
}

budget() {
  local email=${EMAIL:?set EMAIL=you@example.com} usd=${BUDGET_USD:-25}
  aws budgets create-budget --account-id "$(account)" \
    --budget "{\"BudgetName\":\"bench\",\"BudgetLimit\":{\"Amount\":\"$usd\",\"Unit\":\"USD\"},\"TimeUnit\":\"MONTHLY\",\"BudgetType\":\"COST\"}" \
    --notifications-with-subscribers "$(jq -nc --arg e "$email" '
      [{n: "ACTUAL", t: 50}, {n: "FORECASTED", t: 100}] | map({
        Notification: {NotificationType: .n, ComparisonOperator: "GREATER_THAN", Threshold: .t, ThresholdType: "PERCENTAGE"},
        Subscribers: [{SubscriptionType: "EMAIL", Address: $e}]})')"
  log "budget 'bench': \$$usd/month, mail to $email at 50% actual and 100% forecast"
}

push() {
  local reg r v
  reg=$(registry)
  for r in bench/conduit bench/launcher; do
    aws ecr describe-repositories --repository-names "$r" >/dev/null 2>&1 \
      || aws ecr create-repository --repository-name "$r" --query repository.repositoryUri --output text
  done
  aws ecr get-login-password | docker login --username AWS --password-stdin "$reg"
  for v in baseline manual otelc; do
    docker buildx build --platform linux/amd64 --build-arg VARIANT="$v" -t "$reg/bench/conduit:$v" --push service
  done
  docker buildx build --platform linux/amd64 -t "$reg/bench/launcher:latest" --push launcher
}

up() {
  local z1 z2
  read -r z1 z2 _ <<<"$(zones | tr '\n' ' ')" || true
  [[ -n ${z2:-} ]] || die "need two zones offering $APP_TYPE and $LOAD_TYPE in $REGION, found: ${z1:-none}"
  sed -e "s/__REGION__/$REGION/" -e "s/__AZ1__/$z1/g" -e "s/__AZ2__/$z2/" \
    -e "s/__APP_TYPE__/$APP_TYPE/" -e "s/__LOAD_TYPE__/$LOAD_TYPE/" aws/cluster.yaml | eksctl create cluster -f -
  lb_controller
}

lb_controller() {
  local vpc
  vpc=$(aws eks describe-cluster --name "$CLUSTER" --query cluster.resourcesVpcConfig.vpcId --output text)
  helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
  helm repo update eks >/dev/null
  helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system \
    --set clusterName="$CLUSTER" --set region="$REGION" --set vpcId="$vpc" \
    --set serviceAccount.create=false --set serviceAccount.name=aws-load-balancer-controller --wait
}

platform() {
  local reg
  reg=$(registry)
  ./bench.sh infra
  ./bench.sh observability
  REGISTRY=$reg ./bench.sh site-up
  ingress
}

cert_arn() {
  [[ -n $HOST ]] || return 0
  aws acm list-certificates --certificate-statuses ISSUED \
    --query "CertificateSummaryList[?DomainName=='$HOST'].CertificateArn | [0]" --output text | grep -v '^None$' || true
}

ingress() {
  local arn
  arn=$(cert_arn)
  {
    cat <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: bench
  namespace: bench
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/inbound-cidrs: ${ALLOW_CIDR:-0.0.0.0/0}
EOF
    if [[ -n $arn ]]; then
      cat <<EOF
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
    alb.ingress.kubernetes.io/certificate-arn: $arn
    alb.ingress.kubernetes.io/ssl-redirect: "443"
EOF
    fi
    cat <<EOF
spec:
  ingressClassName: alb
  rules:
    - ${HOST:+host: $HOST
      }http:
        paths:
          - {path: /grafana, pathType: Prefix, backend: {service: {name: grafana, port: {number: 3000}}}}
          - {path: /, pathType: Prefix, backend: {service: {name: launcher, port: {number: 8080}}}}
EOF
  } | kubectl apply -f -
  if [[ -n $arn ]]; then log "HTTPS with $arn"; else log "HTTP only (no issued certificate for HOST=${HOST:-<unset>})"; fi
  log "waiting for the ALB (2-3 min)"
  until [[ -n $(alb_dns) ]]; do sleep 10; done
  url
}

alb_dns() { kubectl -n bench get ingress bench -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true; }

url() {
  local dns scheme=http
  dns=$(alb_dns)
  [[ -n $(cert_arn) ]] && scheme=https
  log "ALB: http://$dns/run/  (new ALB DNS names take a few minutes to resolve)"
  [[ -n $HOST ]] && log "site: $scheme://$HOST/run/  (after 'make aws-dns')"
  return 0
}

# zone_id: the Route 53 hosted zone for HOST, from ZONE_ID or the closest parent domain.
zone_id() {
  [[ -n ${ZONE_ID:-} ]] && { echo "$ZONE_ID"; return; }
  local d=$HOST id
  while [[ $d == *.* ]]; do
    id=$(aws route53 list-hosted-zones-by-name --dns-name "$d" --max-items 1 \
      --query "HostedZones[?Name=='$d.'].Id | [0]" --output text)
    [[ $id != None && -n $id ]] && { echo "${id#/hostedzone/}"; return; }
    d=${d#*.}
  done
  die "no Route 53 hosted zone found for $HOST; set ZONE_ID"
}

# change <action> <record set JSON>
change() {
  aws route53 change-resource-record-sets --hosted-zone-id "$(zone_id)" \
    --change-batch "{\"Changes\":[{\"Action\":\"$1\",\"ResourceRecordSet\":$2}]}" --query ChangeInfo.Status --output text
}

cert() {
  [[ -n $HOST ]] || die "set HOST=bench.example.com"
  local arn rr=None
  arn=$(aws acm request-certificate --domain-name "$HOST" --validation-method DNS \
    --idempotency-token "bench${HOST//[^a-zA-Z0-9]/}" --query CertificateArn --output text)
  log "certificate $arn"
  until [[ $rr != None ]]; do
    sleep 5
    rr=$(aws acm describe-certificate --certificate-arn "$arn" --query 'Certificate.DomainValidationOptions[0].ResourceRecord' --output json)
  done
  change UPSERT "$(jq -c '{Name: .Name, Type: .Type, TTL: 300, ResourceRecords: [{Value: .Value}]}' <<<"$rr")"
  log "validation record written; waiting for ACM (usually 2-10 min)"
  aws acm wait certificate-validated --certificate-arn "$arn"
  log "issued. Run 'make aws-ingress HOST=$HOST' to switch the ALB to HTTPS"
}

alb_zone() {
  aws elbv2 describe-load-balancers --query "LoadBalancers[?DNSName=='$1'].CanonicalHostedZoneId | [0]" --output text
}

dns() {
  [[ -n $HOST ]] || die "set HOST=bench.example.com"
  local d
  d=$(alb_dns)
  [[ -n $d ]] || die "no ALB yet: run 'make platform' first"
  change UPSERT "{\"Name\":\"$HOST\",\"Type\":\"A\",\"AliasTarget\":{\"HostedZoneId\":\"$(alb_zone "$d")\",\"DNSName\":\"$d\",\"EvaluateTargetHealth\":false}}"
  url
}

scale() {
  local g
  for g in app load; do
    eksctl scale nodegroup --cluster "$CLUSTER" --region "$REGION" --name "$g" --nodes "$1" --nodes-min 0 --nodes-max 1
  done
}

down() {
  local d=""
  if kubectl -n bench get ingress bench >/dev/null 2>&1; then
    d=$(alb_dns)
    # The ALB belongs to the controller, not to eksctl's CloudFormation stacks. Deleting the
    # cluster first orphans it, and its security groups then block the VPC deletion.
    log "deleting the Ingress so the controller removes the ALB"
    kubectl -n bench delete ingress bench --wait
    while [[ $(aws elbv2 describe-load-balancers --query "length(LoadBalancers[?starts_with(LoadBalancerName, 'k8s-bench-')])" --output text) != 0 ]]; do
      sleep 10
    done
    log "ALB gone"
  fi
  if [[ -n $HOST && -n $d ]]; then
    local rec
    rec=$(aws route53 list-resource-record-sets --hosted-zone-id "$(zone_id)" \
      --query "ResourceRecordSets[?Name=='$HOST.' && Type=='A'] | [0]" --output json)
    [[ $rec != null ]] && change DELETE "$rec" && log "removed DNS record $HOST"
  fi
  eksctl delete cluster --name "$CLUSTER" --region "$REGION" --wait --disable-nodegroup-eviction
  leftovers
}

leftovers() {
  log "anything listed below still costs money (or is left over from this project)"
  aws elbv2 describe-load-balancers --query "LoadBalancers[?starts_with(LoadBalancerName, 'k8s-bench-')].[LoadBalancerName, DNSName]" --output text | sed 's/^/  load balancer: /'
  aws ec2 describe-instances --filters "Name=tag:eks:cluster-name,Values=$CLUSTER" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].[InstanceId, InstanceType, State.Name]' --output text | sed 's/^/  instance: /'
  aws ec2 describe-volumes --filters "Name=tag:kubernetes.io/cluster/$CLUSTER,Values=owned" \
    --query 'Volumes[].[VolumeId, Size, State]' --output text | sed 's/^/  EBS volume: /'
  aws ec2 describe-addresses --query 'Addresses[?AssociationId==null].[PublicIp, AllocationId]' --output text | sed 's/^/  unattached Elastic IP: /'
  aws eks list-clusters --query "clusters[?@=='$CLUSTER']" --output text | sed 's/^/  EKS cluster: /'
  aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE DELETE_FAILED ROLLBACK_COMPLETE \
    --query "StackSummaries[?starts_with(StackName, 'eksctl-$CLUSTER-')].[StackName, StackStatus]" --output text | sed 's/^/  CloudFormation stack: /'
  aws logs describe-log-groups --log-group-name-prefix "/aws/eks/$CLUSTER" --query 'logGroups[].[logGroupName, storedBytes]' --output text | sed 's/^/  log group: /'
  aws ecr describe-repositories --query "repositories[?starts_with(repositoryName, 'bench/')].repositoryName" --output text | tr '\t' '\n' | sed '/^$/d; s/^/  ECR repo (cents per month; make aws-ecr-delete): /'
  log "done"
}

ecr_delete() {
  local r
  for r in bench/conduit bench/launcher; do
    aws ecr delete-repository --repository-name "$r" --force --query repository.repositoryName --output text 2>/dev/null || true
  done
}

cmd=${1:-}
case $cmd in
  check) check ;;
  budget) budget ;;
  push) push ;;
  up) up ;;
  lb-controller) lb_controller ;;
  platform) platform ;;
  ingress) ingress ;;
  cert) cert ;;
  dns) dns ;;
  url) url ;;
  pause) scale 0 ;;
  resume) scale 1 ;;
  down) down ;;
  leftovers) leftovers ;;
  ecr-delete) ecr_delete ;;
  env) echo "export REGISTRY=$(registry)" ;;
  *) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 1 ;;
esac
