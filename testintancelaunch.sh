#!/bin/bash
set -euo pipefail

############################################
# 0. AWS CLI CONFIG
############################################
aws configure set aws_access_key_id "$(jq -r .AccessKey.AccessKeyId userkeys.json)"
aws configure set aws_secret_access_key "$(jq -r .AccessKey.SecretAccessKey userkeys.json)"
aws configure set default.region ap-southeast-2
aws configure set output json

############################################
# 1. AMI (latest Amazon Linux 2)
############################################
AMI_ID=$(aws ec2 describe-images \
  --owners amazon \
  --filters "Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2" \
            "Name=state,Values=available" \
  --query "Images | sort_by(@, &CreationDate)[-1].ImageId" \
  --output text)

############################################
# 2. KEY PAIR (idempotent)
############################################
if ! aws ec2 describe-key-pairs --key-names MyKeyPair >/dev/null 2>&1; then
    aws ec2 create-key-pair --key-name MyKeyPair \
        --query 'KeyMaterial' --output text > MyKeyPair.pem
    chmod 400 MyKeyPair.pem
fi

############################################
# 3. IAM ROLE + INSTANCE PROFILE (idempotent)
############################################
if ! aws iam get-role --role-name app-role >/dev/null 2>&1; then
    aws iam create-role \
      --role-name app-role \
      --assume-role-policy-document file://trust_policy.json
fi

aws iam put-role-policy \
  --role-name app-role \
  --policy-name s3-read-only \
  --policy-document file://permissions.json

if ! aws iam get-instance-profile --instance-profile-name app-instance-profile >/dev/null 2>&1; then
    aws iam create-instance-profile --instance-profile-name app-instance-profile
fi

if ! aws iam get-instance-profile --instance-profile-name app-instance-profile \
    --query "InstanceProfile.Roles[?RoleName=='app-role']" --output text | grep app-role >/dev/null; then
    aws iam add-role-to-instance-profile \
      --instance-profile-name app-instance-profile \
      --role-name app-role
fi

############################################
# 4. S3 BUCKET (idempotent)
############################################
BUCKET_NAME="articlewriterstorage-929453768620-ap-southeast-2-an"

if ! aws s3api head-bucket --bucket "$BUCKET_NAME" >/dev/null 2>&1; then
    aws s3api create-bucket \
        --bucket "$BUCKET_NAME" \
        --region ap-southeast-2 \
        --create-bucket-configuration LocationConstraint=ap-southeast-2
fi

############################################
# 5. VPC + SUBNETS + IGW + ROUTES
############################################
VPC_NAME="MyVPC"
CIDR_VPC="10.0.0.0/16"
CIDR_PUB="10.0.1.0/24"
CIDR_PRIV="10.0.2.0/24"
AZ_PUB="ap-southeast-2a"
AZ_PRIV="ap-southeast-2b"

############################################
# VPC (idempotent)
############################################
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=$VPC_NAME" \
  --query "Vpcs[0].VpcId" --output text)

if [ "$VPC_ID" = "None" ]; then
  VPC_ID=$(aws ec2 create-vpc \
    --cidr-block $CIDR_VPC \
    --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$VPC_NAME}]" \
    --query "Vpc.VpcId" --output text)
fi

aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support

############################################
# Subnets (idempotent)
############################################
PUB_SUBNET=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidr-block,Values=$CIDR_PUB" \
  --query "Subnets[0].SubnetId" --output text)

if [ "$PUB_SUBNET" = "None" ]; then
  PUB_SUBNET=$(aws ec2 create-subnet \
    --vpc-id $VPC_ID \
    --cidr-block $CIDR_PUB \
    --availability-zone $AZ_PUB \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=PublicSubnet}]" \
    --query "Subnet.SubnetId" --output text)
fi

PRIV_SUBNET=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidr-block,Values=$CIDR_PRIV" \
  --query "Subnets[0].SubnetId" --output text)

if [ "$PRIV_SUBNET" = "None" ]; then
  PRIV_SUBNET=$(aws ec2 create-subnet \
    --vpc-id $VPC_ID \
    --cidr-block $CIDR_PRIV \
    --availability-zone $AZ_PRIV \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=PrivateSubnet}]" \
    --query "Subnet.SubnetId" --output text)
fi

############################################
# Internet Gateway (fully idempotent)
############################################

# 1. Check if VPC already has an IGW attached
EXISTING_IGW=$(aws ec2 describe-internet-gateways \
  --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
  --query "InternetGateways[0].InternetGatewayId" \
  --output text)

if [ "$EXISTING_IGW" != "None" ]; then
    IGW_ID="$EXISTING_IGW"
else
    # 2. Check if IGW with tag exists
    IGW_ID=$(aws ec2 describe-internet-gateways \
      --filters "Name=tag:Name,Values=${VPC_NAME}-IGW" \
      --query "InternetGateways[0].InternetGatewayId" \
      --output text)

    # 3. Create IGW if missing
    if [ "$IGW_ID" = "None" ]; then
      IGW_ID=$(aws ec2 create-internet-gateway \
        --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${VPC_NAME}-IGW}]" \
        --query "InternetGateway.InternetGatewayId" --output text)
    fi

    # 4. Attach only if not attached
    ATTACHED=$(aws ec2 describe-internet-gateways \
      --internet-gateway-ids $IGW_ID \
      --query "InternetGateways[0].Attachments[?VpcId=='$VPC_ID']" \
      --output text)

    if [ -z "$ATTACHED" ]; then
      aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID
    fi
fi

############################################
# Route Tables (idempotent)
############################################
RT_PUB=$(aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=PublicRT" \
  --query "RouteTables[0].RouteTableId" --output text)

if [ "$RT_PUB" = "None" ]; then
  RT_PUB=$(aws ec2 create-route-table \
    --vpc-id $VPC_ID \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=PublicRT}]" \
    --query "RouteTable.RouteTableId" --output text)
fi

ASSOC_EXISTS=$(aws ec2 describe-route-tables \
  --filters "Name=association.subnet-id,Values=$PUB_SUBNET" \
            "Name=association.route-table-id,Values=$RT_PUB" \
  --query "RouteTables[0].Associations[0].RouteTableAssociationId" \
  --output text)

if [ "$ASSOC_EXISTS" = "None" ]; then
  aws ec2 associate-route-table --route-table-id $RT_PUB --subnet-id $PUB_SUBNET
fi

ROUTE_EXISTS=$(aws ec2 describe-route-tables \
  --route-table-ids $RT_PUB \
  --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'] | [0].GatewayId" \
  --output text)

if [ "$ROUTE_EXISTS" != "$IGW_ID" ]; then
  aws ec2 create-route \
    --route-table-id $RT_PUB \
    --destination-cidr-block 0.0.0.0/0 \
    --gateway-id $IGW_ID || true
fi

############################################
# Private Route Table (idempotent)
############################################
RT_PRIV=$(aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=PrivateRT" \
  --query "RouteTables[0].RouteTableId" --output text)

if [ "$RT_PRIV" = "None" ]; then
  RT_PRIV=$(aws ec2 create-route-table \
    --vpc-id $VPC_ID \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=PrivateRT}]" \
    --query "RouteTable.RouteTableId" --output text)
fi

ASSOC_PRIV=$(aws ec2 describe-route-tables \
  --filters "Name=association.subnet-id,Values=$PRIV_SUBNET" \
            "Name=association.route-table-id,Values=$RT_PRIV" \
  --query "RouteTables[0].Associations[0].RouteTableAssociationId" \
  --output text)

if [ "$ASSOC_PRIV" = "None" ]; then
  aws ec2 associate-route-table --route-table-id $RT_PRIV --subnet-id $PRIV_SUBNET
fi

############################################
# NAT Gateway (idempotent)
############################################
NAT_GW_ID=$(aws ec2 describe-nat-gateways \
  --filter "Name=vpc-id,Values=$VPC_ID" "Name=subnet-id,Values=$PUB_SUBNET" \
  --query "NatGateways[?State=='available'].NatGatewayId" \
  --output text)

if [ "$NAT_GW_ID" = "None" ]; then
  EIP_ALLOC=$(aws ec2 allocate-address --query 'AllocationId' --output text)

  NAT_GW_ID=$(aws ec2 create-nat-gateway \
    --subnet-id $PUB_SUBNET \
    --allocation-id $EIP_ALLOC \
    --query 'NatGateway.NatGatewayId' \
    --output text)

  aws ec2 wait nat-gateway-available --nat-gateway-ids $NAT_GW_ID
fi

############################################
# Private Route → NAT (idempotent)
############################################
NAT_ROUTE=$(aws ec2 describe-route-tables \
  --route-table-ids $RT_PRIV \
  --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'] | [0].NatGatewayId" \
  --output text)

if [ "$NAT_ROUTE" != "$NAT_GW_ID" ]; then
  aws ec2 create-route \
    --route-table-id $RT_PRIV \
    --destination-cidr-block 0.0.0.0/0 \
    --nat-gateway-id $NAT_GW_ID || true
fi

############################################
# 6. SECURITY GROUPS (idempotent)
############################################
MY_IP="$(curl -s https://checkip.amazonaws.com)"

get_or_create_sg() {
  local NAME="$1"
  local DESC="$2"

  local SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$NAME" \
    --query "SecurityGroups[0].GroupId" --output text)

  if [ "$SG_ID" = "None" ]; then
    SG_ID=$(aws ec2 create-security-group \
      --vpc-id $VPC_ID \
      --group-name "$NAME" \
      --description "$DESC" \
      --query "GroupId" --output text)
  fi

  echo "$SG_ID"
}

SG_PUB=$(get_or_create_sg "web-public-sg" "Public layer")
SG_PRIV=$(get_or_create_sg "app-private-sg" "Private layer")
SG_BASTION=$(get_or_create_sg "bastion-sg" "SSH desde mi IP")

############################################
# RULE CHECKERS (robust)
############################################
# Both checkers query describe-security-group-rules directly, which returns
# a flat list of rules. This avoids the unreliable nested
# projection/filter (`IpPermissions[?...].UserIdGroupPairs[?...]`) that
# describe-security-groups requires, which can silently miss existing
# rules once a group has more than one rule on the same port and cause
# authorize-security-group-ingress to be called on a rule that already
# exists (InvalidPermission.Duplicate).

sg_rule_exists_cidr() {
  local TARGET_SG="$1"
  local PORT="$2"
  local CIDR="$3"

  aws ec2 describe-security-group-rules \
    --filters "Name=group-id,Values=$TARGET_SG" \
    --query "SecurityGroupRules[?FromPort==\`$PORT\` && ToPort==\`$PORT\` && CidrIpv4=='$CIDR']" \
    --output text | grep -q .
}

sg_ingress_exists() {
  local TARGET_SG="$1"
  local PORT="$2"
  local SOURCE_SG="$3"

  aws ec2 describe-security-group-rules \
    --filters "Name=group-id,Values=$TARGET_SG" \
    --query "SecurityGroupRules[?FromPort==\`$PORT\` && ToPort==\`$PORT\` && ReferencedGroupInfo.GroupId=='$SOURCE_SG']" \
    --output text | grep -q .
}

############################################
# Public SG ingress
############################################
if ! sg_rule_exists_cidr "$SG_PUB" 80 "0.0.0.0/0"; then
  aws ec2 authorize-security-group-ingress \
    --group-id $SG_PUB \
    --protocol tcp --port 80 --cidr 0.0.0.0/0
fi

############################################
# Private SG ingress from Bastion (ONLY THIS)
############################################
if ! sg_ingress_exists "$SG_PRIV" 22 "$SG_BASTION"; then
  aws ec2 authorize-security-group-ingress \
    --group-id $SG_PRIV \
    --protocol tcp --port 22 \
    --source-group $SG_BASTION
fi
############################################
# 7. VPC ENDPOINT S3 (idempotent)
############################################
ENDPOINT_ID=$(aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=service-name,Values=com.amazonaws.ap-southeast-2.s3" \
  --query "VpcEndpoints[0].VpcEndpointId" --output text)

if [ "$ENDPOINT_ID" = "None" ]; then
  ENDPOINT_ID=$(aws ec2 create-vpc-endpoint \
    --vpc-id $VPC_ID \
    --service-name com.amazonaws.ap-southeast-2.s3 \
    --vpc-endpoint-type Gateway \
    --route-table-ids $RT_PRIV \
    --query "VpcEndpoint.VpcEndpointId" --output text)
fi

############################################
# 8. BASTION HOST (idempotent)
############################################
BASTION_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=BastionHost" \
            "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" \
  --output text)

if [ "$BASTION_ID" = "None" ]; then
  BASTION_ID=$(aws ec2 run-instances \
    --image-id $AMI_ID \
    --instance-type t3.micro \
    --key-name MyKeyPair \
    --subnet-id $PUB_SUBNET \
    --security-group-ids $SG_BASTION \
    --associate-public-ip-address \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=BastionHost}]' \
    --query 'Instances[0].InstanceId' \
    --output text)
fi

aws ec2 wait instance-running --instance-ids $BASTION_ID

BASTION_PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids $BASTION_ID \
  --query "Reservations[0].Instances[0].PublicIpAddress" \
  --output text)

############################################
# 9. PRIVATE EC2 (idempotent)
############################################
USERDATA=$(base64 < userdata.sh | tr -d '\n')

LT_DATA="{
    \"ImageId\": \"$AMI_ID\",
    \"InstanceType\": \"t3.small\",
    \"KeyName\": \"MyKeyPair\",
    \"UserData\": \"${USERDATA}\",
    \"NetworkInterfaces\": [{
        \"AssociatePublicIpAddress\": false,
        \"DeviceIndex\": 0,
        \"SubnetId\": \"$PRIV_SUBNET\",
        \"Groups\": [\"$SG_PRIV\"]
    }]
}"

LT_ID=$(aws ec2 describe-launch-templates \
  --filters "Name=launch-template-name,Values=MyLaunchTemplate" \
  --query "LaunchTemplates[0].LaunchTemplateId" --output text)

if [ "$LT_ID" = "None" ]; then
  # First time: create the template
  LT_ID=$(aws ec2 create-launch-template \
      --launch-template-name MyLaunchTemplate \
      --version-description "v1" \
      --launch-template-data "$LT_DATA" \
      --query 'LaunchTemplate.LaunchTemplateId' \
      --output text)
else
  # Template already exists: values like SubnetId, AMI, or SG may be
  # stale (e.g. subnet was deleted/recreated since). Push a fresh
  # version with current values rather than trusting the frozen v1
  # data, and make it the default so $Latest picks it up.
  aws ec2 create-launch-template-version \
      --launch-template-id "$LT_ID" \
      --version-description "sync-$(date +%s)" \
      --launch-template-data "$LT_DATA" \
      --query 'LaunchTemplateVersion.VersionNumber' \
      --output text | xargs -I{} aws ec2 modify-launch-template \
        --launch-template-id "$LT_ID" \
        --default-version {} \
        >/dev/null
fi

PRIVATE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=MyInstanceName" \
            "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" \
  --output text)

if [ "$PRIVATE_ID" = "None" ]; then
  PRIVATE_ID=$(aws ec2 run-instances \
      --launch-template LaunchTemplateId=$LT_ID,Version='$Latest' \
      --iam-instance-profile Name=app-instance-profile \
      --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":30}}]' \
      --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=MyInstanceName}]' \
      --query 'Instances[0].InstanceId' \
      --output text)
fi

aws ec2 wait instance-running --instance-ids $PRIVATE_ID

PRIVATE_IP=$(aws ec2 describe-instances \
    --instance-ids $PRIVATE_ID \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' \
    --output text)

############################################
# 10. SSH INSTRUCTIONS
############################################
echo "SSH Bastion (use agent forwarding — the .pem stays on your machine, not the bastion):"
echo "  eval \$(ssh-agent) && ssh-add MyKeyPair.pem"
echo "  ssh -A -i MyKeyPair.pem ec2-user@$BASTION_PUBLIC_IP"

echo "SSH Private EC2 (from inside the bastion, after connecting with -A above):"
echo "  ssh ec2-user@$PRIVATE_IP"