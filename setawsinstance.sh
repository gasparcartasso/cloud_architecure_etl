#connect to your aws account
aws configure
#create role to access EC2 and s3
aws iam create-user --user-name MyEC2S3User
aws iam attach-user-policy \
    --user-name MyEC2S3User \
    --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess
aws iam attach-user-policy \
    --user-name MyEC2S3User \
    --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess
#generate access key for the user
aws iam create-access-key --user-name MyEC2S3User > userkeys.json
#access the keys from the json file 
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
rm MyKeyPair.pem
aws ec2 delete-key-pair --key-name MyKeyPair
aws ec2 create-key-pair --key-name MyKeyPair \
    --query 'KeyMaterial' --output text > MyKeyPair.pem
chmod 400 MyKeyPair.pem
#create security 
aws ec2 delete-security-group --group-name MySecGroup
aws ec2 create-security-group --group-name MySecGroup \
    --description "Allow SSH and HTTP"
#add rules
aws ec2 authorize-security-group-ingress \
    --group-name MySecGroup --protocol tcp --port 22 --cidr 0.0.0.0/0

aws ec2 authorize-security-group-ingress \
    --group-name MySecGroup --protocol tcp --port 80 --cidr 0.0.0.0/0
#run instance and capture ID
aws ec2 terminate-instances \
    --instance-ids $(aws ec2 describe-instances --filters "Name=tag:Name,Values=MyInstanceName" --query 'Reservations[*].Instances[*].InstanceId' --output text)
aws ec2 run-instances \
    --image-id $(< ami.txt) \
    --count 1 \
    --instance-type t3.micro \
    --key-name MyKeyPair \
    --security-groups MySecGroup \
    --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":30}}]' \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=MyInstanceName}]' \
    --query 'Instances[0].InstanceId' \
    --output text > instance.txt
#wait until instance is running
aws ec2 wait instance-running --instance-ids $(< instance.txt)
#get public ip of the instance
aws ec2 describe-instances --instance-ids $(< instance.txt) \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text > public_ip.txt
# create ASG and launch template
aws ec2 delete-launch-template --launch-template-name MyLaunchTemplate
aws ec2 create-launch-template \
    --launch-template-name MyLaunchTemplate \
    --version-description "v1" \
    --launch-template-data "{
        \"ImageId\": \"$(< ami.txt)\",
        \"InstanceType\": \"t3.micro\",
        \"KeyName\": \"MyKeyPair\",
        \"SecurityGroupIds\": [\"$(aws ec2 describe-security-groups --group-names MySecGroup --query 'SecurityGroups[0].GroupId' --output text)\"]
    }"
aws ec2 describe-subnets \
    --query 'Subnets[*].SubnetId' \
    --output text > subnets.txt
aws autoscaling create-auto-scaling-group \
    --auto-scaling-group-name MyASG \
    --launch-template LaunchTemplateName=MyLaunchTemplate,Version=1 \
    --min-size 1 \
    --max-size 3 \
    --desired-capacity 1 \
    --vpc-zone-identifier "$(aws ec2 describe-subnets --query 'Subnets[*].SubnetId' --output text | tr '\t' ',')"

aws autoscaling attach-instances \
    --instance-ids $(< instance.txt) \
    --auto-scaling-group-name MyASG

#wait until SSH port is available
echo "Waiting for SSH to become available..."
while ! nc -zv $(< public_ip.txt) 22 2>/dev/null; do
    sleep 5
done
#connect to the ec2 instance
ssh -i MyKeyPair.pem ec2-user@$(< public_ip.txt)


