#!/bin/bash
aws configure set aws_access_key_id $(jq -r .AccessKey.AccessKeyId userkeys.json)
aws configure set aws_secret_access_key $(jq -r .AccessKey.SecretAccessKey userkeys.json)
aws configure set default.region ap-southeast-2
aws configure set output json

#create an ec2 instance
#choose AMI
aws ec2 describe-images \
    --owners amazon \
    --filters "Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2" \
    --query 'Images[0].ImageId' --output text > ami.txt

#create .pem to access the instance
rm -f MyKeyPair.pem
aws ec2 delete-key-pair --key-name MyKeyPair
aws ec2 create-key-pair --key-name MyKeyPair \
    --query 'KeyMaterial' --output text > MyKeyPair.pem
chmod 400 MyKeyPair.pem

#create app role
aws iam create-role \
  --role-name app-role \
  --assume-role-policy-document file://trust_policy.json

aws iam put-role-policy \
  --role-name app-role \
  --policy-name s3-read-only \
  --policy-document file://permissions.json

aws iam get-role --role-name app-role

# Check if bucket exists
BUCKET_NAME="articlewriterstorage-929453768620-ap-southeast-2-an" 

if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
    echo "Bucket $BUCKET_NAME already exists"
else
    echo "Creating bucket $BUCKET_NAME..."
    aws s3api create-bucket \
        --bucket "$BUCKET_NAME" \
        --region ap-southeast-2 \
        --create-bucket-configuration LocationConstraint=ap-southeast-2
fi
#VPC
VPC_NAME="MyVPC"
CIDR_VPC="10.0.0.0/16"
CIDR_PUB="10.0.1.0/24"
CIDR_PRIV="10.0.2.0/24"
AZ_PUB="ap-southeast-2a"
AZ_PRIV="ap-southeast-2b"
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=$VPC_NAME" \
  --query "Vpcs[0].VpcId" --output text)

if [ -n "$VPC_ID" ]; then
    echo "Terminating old instance(s): $VPC_NAME"
    aws ec2 terminate-vpc --vpc-id $VPC_ID
    aws ec2 wait vpc-terminated --vpc-ids $VPC_ID
fi
VPC_ID=$(aws ec2 create-vpc \
    --cidr-block $CIDR_VPC \
    --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$VPC_NAME}]" \
    --query "Vpc.VpcId" --output text)
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support

#subnets
PUB_SUBNET=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidr-block,Values=$CIDR_PUB" \
  --query "Subnets[0].SubnetId" --output text)

if [ -n "$PUB_SUBNET" ]; then
    echo "Terminating old instance(s): $$PUB_SUBNET"
    aws ec2 terminate-subnet --subnet-id $$PUB_SUBNET
    aws ec2 wait subnet-terminated --subnet-ids $$PUB_SUBNET
fi
PUB_SUBNET=$(aws ec2 create-subnet \
    --vpc-id $VPC_ID \
    --cidr-block $CIDR_PUB \
    --availability-zone $AZ_PUB \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=PublicSubnet}]" \
    --query "Subnet.SubnetId" --output text)

PRIV_SUBNET=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidr-block,Values=$CIDR_PRIV" \
  --query "Subnets[0].SubnetId" --output text)

if [ -n "$PRIV_SUBNET" ]; then
    echo "Terminating old instance(s): $$PRIV_SUBNET"
    aws ec2 terminate-subnet --subnet-id $$PRIV_SUBNET
    aws ec2 wait subnet-terminated --subnet-ids $$PRIV_SUBNET
fi
  PRIV_SUBNET=$(aws ec2 create-subnet \
    --vpc-id $VPC_ID \
    --cidr-block $CIDR_PRIV \
    --availability-zone $AZ_PRIV \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=PrivateSubnet}]" \
    --query "Subnet.SubnetId" --output text)

#internet gateway
EXISTING_IGW=$(aws ec2 describe-internet-gateways \
  --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
  --query "InternetGateways[0].InternetGatewayId" \
  --output text)
if [ -n "$EXISTING_IGW" ]; then
    echo "Terminating old instance(s): $EXISTING_IGW"
    aws ec2 detach-internet-gateway --internet-gateway-id $EXISTING_IGW --vpc-id $VPC_ID
    aws ec2 delete-internet-gateway --internet-gateway-id $EXISTING_IGW
fi
IGW_ID=$(aws ec2 create-internet-gateway \
        --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${VPC_NAME}-IGW}]" \
        --query "InternetGateway.InternetGatewayId" --output text)
aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID

#route table SEGUIR CON ESTOOO #########################################################################################################

#create security group
SG_ID=$(aws ec2 describe-security-groups \
    --group-names MySecGroup \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null || true)

# If SG does not exist, create it
if [[ -z "$SG_ID" || "$SG_ID" == "None" ]]; then
    echo "Creating security group MySecGroup..."
    SG_ID=$(aws ec2 create-security-group \
        --group-name MySecGroup \
        --description "Allow SSH and HTTP" \
        --query 'GroupId' \
        --output text)
else
    echo "Security group already exists: $SG_ID"
fi

MY_IP="$(curl -s https://checkip.amazonaws.com)"
# Ensure SSH rule exists
aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol tcp --port 22 --cidr "$MY_IP/32"\
    2>/dev/null || echo "SSH rule already exists"

#airflow port    
aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol tcp --port 8080 --cidr "${MY_IP}/32" \
    2>/dev/null || echo "Airflow port already exists"

#instance profile
aws iam create-instance-profile --instance-profile-name app-instance-profile

aws iam add-role-to-instance-profile \
  --instance-profile-name app-instance-profile \
  --role-name app-role

aws iam get-instance-profile --instance-profile-name app-instance-profile

#run instance and capture ID
USERDATA=$(base64 < userdata.sh | tr -d '\n')
aws ec2 delete-launch-template --launch-template-name MyLaunchTemplate 2>/dev/null || true

aws ec2 delete-launch-template-versions \
    --launch-template-name MyLaunchTemplate \
    --versions "1" 2>/dev/null || true
    
LT_ID=$(aws ec2 create-launch-template \
    --launch-template-name MyLaunchTemplate \
    --version-description "v1" \
    --launch-template-data "{
        \"ImageId\": \"$(< ami.txt)\",
        \"InstanceType\": \"t3.small\",
        \"KeyName\": \"MyKeyPair\",
        \"SecurityGroupIds\": [\"$(aws ec2 describe-security-groups --group-names MySecGroup --query 'SecurityGroups[0].GroupId' --output text)\"],
        \"UserData\": \"${USERDATA}\"
    }" \
    --query 'LaunchTemplate.LaunchTemplateId' \
    --output text)

INSTANCE_IDS=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=MyInstanceName" "Name=instance-state-name,Values=running,stopped" \
    --query 'Reservations[*].Instances[*].InstanceId' \
    --output text)

if [ -n "$INSTANCE_IDS" ]; then
    echo "Terminating old instance(s): $INSTANCE_IDS"
    aws ec2 terminate-instances --instance-ids $INSTANCE_IDS
    aws ec2 wait instance-terminated --instance-ids $INSTANCE_IDS
fi
aws ec2 run-instances \
    --launch-template LaunchTemplateId=$LT_ID,Version=1 \
    --iam-instance-profile Name=app-instance-profile \
    --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":30}}]' \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=MyInstanceName}]' \
    --query 'Instances[0].InstanceId' \
    --output text > instance.txt

#wait until instance is running
aws ec2 wait instance-running --instance-ids $(< instance.txt)
#get public ip of the instance
aws ec2 describe-instances --instance-ids $(< instance.txt) \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text > public_ip.txt

#wait until SSH port is available
echo "Waiting for SSH to become available..."
while ! nc -zv $(< public_ip.txt) 22 2>/dev/null; do
    sleep 5
done
#connect to the ec2 instance
ssh -i MyKeyPair.pem ec2-user@$(< public_ip.txt)


