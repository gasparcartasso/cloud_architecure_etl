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
#create security 

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

# Ensure SSH rule exists
aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol tcp --port 22 --cidr 0.0.0.0/0 \
    2>/dev/null || echo "SSH rule already exists"

# Ensure HTTP rule exists
aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol tcp --port 80 --cidr 0.0.0.0/0 \
    2>/dev/null || echo "HTTP rule already exists"

#run instance and capture ID
USERDATA=$(base64 < userdata.sh | tr -d '\n')
aws ec2 delete-launch-template --launch-template-name MyLaunchTemplate
LT_ID=$(aws ec2 create-launch-template \
    --launch-template-name MyLaunchTemplate \
    --version-description "v1" \
    --launch-template-data "{
        \"ImageId\": \"$(< ami.txt)\",
        \"InstanceType\": \"t3.micro\",
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


