#!/usr/bin/env bash
# Expect every command below to print nothing / empty list, except the "OK to remain" items.
R=eu-north-1; P=arik-rainish; C=$P-eks; B=$P-tfstate-092988563851; T=$P-tflock
q(){ echo "== $1"; shift; "$@" --region $R --output text; }

echo "== terraform state (expect empty)"
terraform -chdir=apps  state list; terraform -chdir=infra state list

# 1. Everything Terraform tagged (provider default_tags Project=trades-pipeline)
q tagged        aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=trades-pipeline --query 'ResourceTagMappingList[].ResourceARN'
# 2. Things AWS services created for the cluster (they do not carry our default tag)
q eks-tagged    aws resourcegroupstaggingapi get-resources --tag-filters Key=eks:cluster-name,Values=$C --query 'ResourceTagMappingList[].ResourceARN'
q k8s-owned     aws resourcegroupstaggingapi get-resources --tag-filters Key=kubernetes.io/cluster/$C --query 'ResourceTagMappingList[].ResourceARN'
# 3. Big-ticket services by name
q eks           aws eks list-clusters --query "clusters[?starts_with(@,'$P')]"
q msk           aws kafka list-clusters-v2 --cluster-name-filter $P --query 'ClusterInfoList[].[ClusterName,State]'
q msk-config    aws kafka list-configurations --query "Configurations[?starts_with(Name,'$P')].[Name,State]"
q rds           aws rds describe-db-instances --query "DBInstances[?starts_with(DBInstanceIdentifier,'$P')].[DBInstanceIdentifier,DBInstanceStatus]"
q rds-backups   aws rds describe-db-instance-automated-backups --query "DBInstanceAutomatedBackups[?starts_with(DBInstanceIdentifier,'$P')].DBInstanceIdentifier"
q rds-snapshots aws rds describe-db-snapshots --snapshot-type manual --query "DBSnapshots[?starts_with(DBInstanceIdentifier,'$P')].DBSnapshotIdentifier"
q ec2           aws ec2 describe-instances --filters Name=tag:eks:cluster-name,Values=$C Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[].Instances[].InstanceId'
q asg           aws autoscaling describe-auto-scaling-groups --filters Name=tag:eks:cluster-name,Values=$C --query 'AutoScalingGroups[].AutoScalingGroupName'
q ecr           aws ecr describe-repositories --query "repositories[?starts_with(repositoryName,'$P')].repositoryName"
# 4. Network leftovers (untagged or service-owned)
q vpc           aws ec2 describe-vpcs --filters Name=tag:Name,Values=$P-vpc --query 'Vpcs[].VpcId'
q nat           aws ec2 describe-nat-gateways --filter Name=tag:Project,Values=trades-pipeline Name=state,Values=pending,available,deleting --query 'NatGateways[].[NatGatewayId,State]'
q eip-free      aws ec2 describe-addresses --query 'Addresses[?AssociationId==null].[AllocationId,PublicIp]'
q eni-free      aws ec2 describe-network-interfaces --filters Name=status,Values=available --query 'NetworkInterfaces[].[NetworkInterfaceId,VpcId,Description]'
q gd-endpoints  aws ec2 describe-vpc-endpoints --filters Name=tag:GuardDutyManaged,Values=true --query 'VpcEndpoints[].[VpcEndpointId,VpcId,State]'
q gd-sgs        aws ec2 describe-security-groups --filters Name=tag:GuardDutyManaged,Values=true --query 'SecurityGroups[].[GroupId,VpcId,GroupName]'
q ebs-free      aws ec2 describe-volumes --filters Name=status,Values=available --query 'Volumes[].[VolumeId,Size]'
q elbv2         aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerArn'
q elb-classic   aws elb describe-load-balancers --query 'LoadBalancerDescriptions[].LoadBalancerName'
# 5. Misc
q log-groups    aws logs describe-log-groups --log-group-name-prefix /aws/eks/$C --query 'logGroups[].logGroupName'
q secrets       aws secretsmanager list-secrets --include-planned-deletion --filters Key=name,Values=rds --query 'SecretList[].[Name,DeletedDate]'
q sns           aws sns list-topics --query "Topics[?contains(TopicArn,'$P')].TopicArn"
q alarms        aws cloudwatch describe-alarms --alarm-name-prefix $P --alarm-types MetricAlarm CompositeAlarm --query '[MetricAlarms[].AlarmName, CompositeAlarms[].AlarmName]'
echo "== iam-roles"; aws iam list-roles --query "Roles[?starts_with(RoleName,'$P')].RoleName" --output text
# 6. Backend: state objects stay (fine), lock rows must NOT
echo "== locks (expect none)"
aws dynamodb scan --region $R --table-name $T --query 'Items[].LockID.S' --output text | xargs -n1 | grep -v -- '-md5'
